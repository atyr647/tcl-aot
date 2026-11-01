# translate.tcl -- ahead-of-time translation of Tcl 8.6 procs from bytecode to C.
#
#   tcl-aot-sh src/translate.tcl <procs.tcl> <out.c> <InitName> [-hints file] [-untyped] [-split N]
#
# <procs.tcl> is loaded (it may define procs in any namespace, or load packages); every proc it adds is a candidate.  For each candidate that can be
# translated the output holds compiled code, registered under (namespace, arguments, body).  A program that defines the same proc later gets the
# compiled body attached to its proc (include/tbc_hook.h); the interpreter, the proc and everything that calls it stay as they are.
#
# Code generation.  Each proc is translated twice:
#   typed code    one function per argument-type signature (I = int64_t, D = double, B = Tcl_Obj *); the translator infers which locals and stack
#                 slots are integers or doubles and keeps those in C variables.  Calls between translated procs by literal name are direct C
#                 calls, guarded by a flag that Tcl clears when the callee is deleted, renamed or redefined.
#   boxed code    one function per proc, entered at any instruction; locals live in the interpreter's own call frame and the operand stack holds
#                 Tcl_Obj references, exactly as the bytecode executor does it.
# Typed code falls into the boxed code, at the instruction it was executing, whenever an assumption of the inference fails (integer overflow, a
# non-numeric operand, a NaN result, a callee that was redefined...).  Nothing observable has happened before such a fall, so results, error codes
# and error info are the interpreter's.  See docs/design.md.
#
# Options
#   -hints file   lines "<proc> <sig> [<sig>...]" request extra entry signatures (default: all-I plus the all-B generic one)
#   -untyped      generate the boxed code only
#   -split N      write the module as several files instead of one: <out>.h (shared declarations), <out>_v1.c .. <out>_vN.c (typed code),
#                 <out>_g1.c .. <out>_gN.c (boxed code) and <out>.c (tables and Init); build them with tools/build-module.sh
#
# Environment: TBC_FORCE_DEOPT=1 adds a forced hand-over point at every typed instruction (see tests/run.sh); TBC_CENSUS=1 lists which procs can be translated and exits; TBC_REPORT=1 prints, to stderr, how much of every variant is typed code and which instructions it has no code for; TBC_DEADOPS=1 logs, to stderr, every instruction at which typed code gives
# up; TBC_TIMING=1 logs procs that take long to analyse.

if {$argc < 3} { puts stderr "usage: translate.tcl procs.tcl out.c InitName \[-hints file\] \[-untyped\] \[-split N\]"; exit 2 }
lassign $argv srcFile outFile initName
set hintFile ""; set typedMode 1; set splitN 0
set rest [lrange $argv 3 end]
while {[llength $rest]} {
    switch -- [lindex $rest 0] {
        -hints { set hintFile [lindex $rest 1]; set rest [lrange $rest 2 end] }
        -untyped { set typedMode 0; set rest [lrange $rest 1 end] }
        -split { set splitN [lindex $rest 1]; set rest [lrange $rest 2 end] }
        default { puts stderr "unknown option [lindex $rest 0]"; exit 2 }
    }
}

# (in a namespace of its own: it is called right after the program's file is read, which may define a proc of any name in the global namespace)
namespace eval ::tbcx {}
# What the translator needs to know about one proc as the program defined it: its bytecode, body, arguments (name or name\003default) and the defaults ({} for none, {d}).
proc ::tbcx::snap {P} {
    set args [info args $P]
    set defs {}; set canon {}
    foreach a $args { if {[info default $P $a d]} { lappend defs [list $d]; lappend canon "$a\003$d" } else { lappend defs [list]; lappend canon $a } }
    # (no [expr {... ? ... : ...}] for the strings: a fingerprint like 53240e9073862955 is a number to expr, and a very large one Inf)
    set q $P; if {![string match ::* $P]} { set q ::$P }
    set fp ""; if {[info commands ::tbc::fingerprint] ne ""} { set fp [::tbc::fingerprint $P] }
    return [dict create bc [::tcl::unsupported::getbytecode proc $q] body [info body $P] args $args defs $defs canon $canon fp $fp]
}
proc ::tbcx::allprocs {ns} {
    set r {}
    foreach p [namespace eval $ns {::info procs}] {
        set q [expr {$ns eq "::" ? "::$p" : "${ns}::$p"}]
        # an imported command is the other namespace's proc, not one of this one's
        if {[catch {namespace origin $q} o] || $o ne $q} continue
        lappend r $q
    }
    foreach c [namespace children $ns] { lappend r {*}[::tbcx::allprocs $c] }
    return $r
}
set before [::tbcx::allprocs ::]
source $srcFile
set procNames [lsort [lmap p [::tbcx::allprocs ::] {expr {$p in $before ? [continue] : $p}}]]
# a proc of the program with the name of one of the translator's own (lt, emit, analyze, operand...) is replaced in this interpreter when this file defines that proc below:
# what the module is built from is read now for those (and by `prepare` for all others, which come before any such replacement)
set ::EARLY [dict create]
set tbcOwnNames {}
set tbcSelf [open [info script]]; set tbcText [read $tbcSelf]; close $tbcSelf
foreach tbcLine [split $tbcText \n] { if {[regexp {^proc ([^ ]+) } $tbcLine -> tbcN]} { lappend tbcOwnNames ::[string trimleft $tbcN :] } }
foreach tbcP $procNames { if {$tbcP in $tbcOwnNames} { dict set ::EARLY $tbcP [::tbcx::snap $tbcP] } }
unset tbcSelf tbcText tbcLine tbcOwnNames
set census [info exists ::env(TBC_CENSUS)]
if {$census} { set procNames [lsort [::tbcx::allprocs ::]] }

# ================================================================== helpers

# built-in commands that neither reach the variables of the calling frame nor call back into scripts: a proc that uses nothing else
# (and calls only such procs) is "pure": nothing can observe its frame, so it needs none of its own while it runs
set tbcPureBuiltins {string list lindex llength lrange lsearch join split concat format lrepeat lreverse lreplace linsert encoding abs max min tcl::binary::format}
# built-ins that work on the variables of the frame they run in, and nothing else
# the formats of `binary scan` typed code does itself: one of c s S i I, an optional u, and *
set tbcScanFmt {^([cisSI])(u?)\*$}
# the instructions with which the executor does `string` subcommands itself, and the commands they stand for
set tbcStrOps {strindex ::tcl::string::index strfind ::tcl::string::first strrfind ::tcl::string::last strrange ::tcl::string::range strrangeImm ::tcl::string::range
    strreplace ::tcl::string::replace strcaseUpper ::tcl::string::toupper strcaseLower ::tcl::string::tolower strcaseTitle ::tcl::string::totitle
    strtrim ::tcl::string::trim strtrimLeft ::tcl::string::trimleft strtrimRight ::tcl::string::trimright strmatch ::tcl::string::match strmap ::tcl::string::map}
set tbcOwnFrameBuiltins {set unset incr append lappend array puts global variable tcl::binary::scan}
# one of Tcl's own math functions that is a command written in C (max and min are procs of the Tcl library): it never uses the caller's variables
proc isMathBuiltin {b} { expr {[regexp {^(?:::)?tcl::mathfunc::(\w+)$} $b -> f] && $f ni {max min}} }

# where a command word may resolve to, for a proc in namespace ns
proc candidates {ns nm} {
    if {[string match ::* $nm]} { return [list $nm] }
    if {$ns eq "::"} { return [list ::$nm] }
    return [list ${ns}::$nm ::$nm]
}
# the proc a command word resolves to (the first candidate that exists), or "" when it is not a proc / unknown
proc resolveProc {ns nm} {
    foreach c [candidates $ns $nm] {
        if {[llength [info commands [globEsc $c]]]} { return [expr {[llength [info procs [globEsc $c]]] ? [string map {::::: ::} $c] : ""}] }
    }
    return ""
}
proc keysplit {key} { set i [string last / $key]; list [string range $key 0 [expr {$i-1}]] [string range $key [expr {$i+1}] end] }
proc refuse {why} { return -code error -errorcode TBC_REFUSED $why }
proc fm {tmpl args} { string map $args $tmpl }

# a name as a glob pattern that matches only itself (info commands and info procs take patterns)
proc globEsc {s} { string map [list \\ \\\\ * \\* ? \\? \[ \\\[ \] \\\]] $s }
proc cident {s} {
    set r ""
    foreach c [split $s ""] {
        if {[string is alnum -strict $c] && [scan $c %c] < 128} { append r $c } else { append r _[format %02x [scan $c %c]] }
    }
    return $r
}
# a string as the bytes of Tcl's internal representation: modified UTF-8, in which the NUL character is the two bytes C0 80
proc istr {s} { string map [list \x00 \xC0\x80] [encoding convertto utf-8 $s] }
proc cstring {s} {
    set r ""
    foreach b [split [istr $s] ""] {
        set n [scan $b %c]
        if {$n >= 32 && $n < 127 && $b ni {\" \\ ?}} { append r $b } else { append r [format {\%03o} $n] }
    }
    return \"$r\"
}
proc cbytes {s} { string length [istr $s] }
proc c_int {s} {
    if {$s eq "-9223372036854775808"} { return "(-INT64_C(9223372036854775807) - 1)" }
    return "INT64_C($s)"
}
proc c_dbl {s} {
    set v [expr {double($s)}]
    if {$v != $v} { return "__builtin_nan(\"\")" }
    if {$v == Inf} { return "__builtin_inf()" }
    if {$v == -Inf} { return "(-__builtin_inf())" }
    set t [format %.17g $v]
    if {![regexp {[.eEn]} $t]} { append t .0 }
    return $t
}

# the C constant of a double literal: the value of the object when the compiler made it (litd), else the value of its text
proc litdbl {P n} {
    global PI
    set e [lindex $PI($P,litd) $n]
    if {$e ne ""} { return $e }
    return [c_dbl [lindex $PI($P,lits) $n]]
}

proc operand {a} {
    switch -regexp -- $a {
        {^%(\d+)$} - {^@(\d+)$} { return [string range $a 1 end] }
        {^pc (\d+)$} { return [lindex $a 1] }
        default { return $a }
    }
}

# {pops pushes kind target}; kind: fall | jump | cond | term
source [file join [file dirname [info script]] opcodes.tcl]
source [file join [file dirname [info script]] cmdmap.tcl]
# instructions that have a handler in the boxed code (G) -- the others keep a proc interpreted
set tbcGops {nop startCommand beginCatch4 endCatch tryCvtToNumeric push1 push4 pop dup loadScalar1 loadScalar4 storeScalar1 storeScalar4
    incrScalar1Imm incrScalar1 add sub mult div mod lt le gt ge eq neq jump1 jump4 jumpTrue1 jumpTrue4 jumpFalse1 jumpFalse4 done
    invokeStk1 invokeStk4 strcat strlen reverse appendScalar1 appendScalar4 lappendScalar1 lappendScalar4 listIndex listIndexImm
    listLength list lsetList dictExists dictGet dictIncrImm verifyDict dictFirst dictNext unsetScalar
    pushResult pushReturnCode pushReturnOpts returnCodeBranch returnImm syntax returnStk break continue variable upvar nsupvar
    foreach_start foreach_step foreach_end lmap_collect
    over streq strneq strcmp strindex strmatch strfind strrfind strrange strrangeImm strreplace strmap strcaseUpper strcaseLower strcaseTitle strtrim strtrimLeft
    strtrimRight strclass regexp uminus uplus not bitnot bitand bitor bitxor lshift rshift expon listIn listNotIn listConcat lindexMulti lsetFlat listRangeImm
    concatStk jumpTable infoLevelNumber infoLevelArgs currentNamespace expandStart expandStkTop invokeExpanded expandDrop syntax
    yield yieldToInvoke tailcall evalStk coroName dictExpand dictRecombineImm dictRecombineStk dictUpdateStart dictUpdateEnd invokeReplace dictSet dictUnset dictAppend dictLappend arrayMakeImm arrayMakeStk exprStk tryCvtToBoolean numericType clockRead resolveCmd originCmd
    loadArray1 loadArray4 loadArrayStk loadStk loadScalarStk storeArray1 storeArray4 storeArrayStk storeStk storeScalarStk
    appendArray1 appendArray4 appendArrayStk appendStk lappendArray1 lappendArray4 lappendArrayStk lappendStk
    incrArray1 incrArrayStk incrStk incrScalarStk incrArray1Imm incrArrayStkImm incrStkImm incrScalarStkImm lappendList lappendListArray lappendListStk lappendListArrayStk
    existScalar existArray existArrayStk existStk unsetArray unsetArrayStk unsetStk arrayExistsImm arrayExistsStk}
# the stack effect of an instruction as {pops pushes kind ?target?}; the G handler of an instruction with a table-derived effect
# must keep exactly the net effect the table says
proc effect {op a {d {}} {d0 {}}} {
    switch -- $op {
        expandStart { return {0 0 fall} }
        expandStkTop - expandDrop { return [list [expr {$op eq "expandDrop" ? $d - $d0 : $d - $d0}] 0 fall] }
        invokeExpanded { return [list [expr {$d - $d0}] 1 fall] }
        push1 - push4 - dup - loadScalar1 - loadScalar4 - incrScalar1Imm - pushResult - pushReturnCode - pushReturnOpts { return {0 1 fall} }
        pop - verifyDict - variable { return {1 0 fall} }
        upvar - nsupvar { return {1 0 fall} }
        storeScalar1 - storeScalar4 - nop - startCommand - beginCatch4 - endCatch - unsetScalar - tryCvtToNumeric { return {0 0 fall} }
        incrScalar1 - strlen - dictIncrImm - appendScalar1 - appendScalar4 - lappendScalar1 - lappendScalar4 { return {1 1 fall} }
        dictGet { return [list [expr {[lindex $a 0] + 1}] 1 fall] }
        add - sub - mult - div - mod - lt - le - gt - ge - eq - neq - listIndex { return {2 1 fall} }
        lsetList { return {3 1 fall} }
        listIndexImm - listLength {
            if {$op eq "listIndexImm" && ![regexp {^\.(-?\d+|end(-\d+)?)$} [lindex $a 0]]} { refuse "listIndexImm [lindex $a 0]" }
            return {1 1 fall}
        }
        list { return [list [lindex $a 0] 1 fall] }
        jump1 - jump4 { return [list 0 0 jump [operand [lindex $a 0]]] }
        jumpTrue1 - jumpTrue4 - jumpFalse1 - jumpFalse4 { return [list 1 0 cond [operand [lindex $a 0]]] }
        done { return {1 0 term} }
        break - continue { return {0 0 special} }
        returnCodeBranch { return {1 0 special} }
        tailcall { return [list [lindex $a 0] 0 term] }
        returnImm - syntax {
            # a return with an error code (or any level) never continues with the next instruction
            lassign $a rcode rlevel
            if {$rcode + 0 == 0 && $rlevel + 0 == 0} { return {1 0 fall} }
            return {2 0 term}
        }
        returnStk { return {2 1 fall} }
        invokeStk1 - invokeStk4 - strcat { set n [lindex $a 0]; return [list $n 1 fall] }
        reverse { set n [lindex $a 0]; return [list $n $n fall] }
        dictExists { return [list [expr {[lindex $a 0] + 1}] 1 fall] }
        dictFirst { return {1 3 fall} }
        concatStk - lindexMulti { return [list [lindex $a 0] 1 fall] }
        invokeReplace { return [list [expr {[lindex $a 0] + 1}] 1 fall] }
        dictSet { return [list [expr {[lindex $a 0] + 1}] 1 fall] }
        dictUnset { return [list [lindex $a 0] 1 fall] }
        dictAppend - dictLappend { return {2 1 fall} }
        lsetFlat { return [list [lindex $a 0] 1 fall] }
        jumpTable { lassign $a n tgts; return [list 1 0 multi $tgts] }
        foreach_start { lassign $a n nl jo vl stepPc; return [list $nl [expr {$nl + 2}] jump $stepPc] }
        foreach_step { lassign $a n nl jo vl stepPc; return [list 0 0 cond [expr {$stepPc + $jo}]] }
        foreach_end { lassign $a n nl; return [list [expr {$nl + 2}] 0 fall] }
        dictNext { return {0 3 fall} }
        default {
            if {$op ni $::tbcGops || ![dict exists $::OPNET $op]} { refuse "opcode $op" }
            set n [dict get $::OPNET $op]
            if {$n eq "V"} { refuse "opcode $op (variable stack effect)" }
            return [list [expr {max(-$n, 0)}] [expr {max($n, 0)}] fall]
        }
    }
}

# can this instruction end with a break or continue result (which then goes to the enclosing loop's targets)?  A command can; a return with a
# code known when it is compiled cannot unless that code is break or continue at level 0
proc tbcCanBC {op a} {
    if {$op in {returnImm syntax}} {
        lassign $a rcode rlevel
        return [expr {$rlevel + 0 == 0 && $rcode + 0 in {3 4}}]
    }
    return [expr {$op in {invokeStk1 invokeStk4 evalStk tailcall invokeReplace invokeExpanded returnStk break continue}}]
}

# the instructions that work on an element of an array that is a compiled local, and that typed code can do on a native table (kind R)
set tbcRops {loadArray1 loadArray4 storeArray1 storeArray4 incrArray1 incrArray1Imm existArray}

# variables read and written by an instruction
proc usedef {op a} {
    switch -- $op {
        loadScalar1 - loadScalar4 { return [list [operand [lindex $a 0]] {}] }
        storeScalar1 - storeScalar4 { return [list {} [operand [lindex $a 0]]] }
        incrScalar1Imm - incrScalar1 - appendScalar1 - appendScalar4 - lappendScalar1 - lappendScalar4 { set v [operand [lindex $a 0]]; return [list $v $v] }
        dictIncrImm { set v [operand [lindex $a 1]]; return [list $v $v] }
        variable - upvar - nsupvar { return [list {} [operand [lindex $a 0]]] }
        foreach_step {
            # (assigns only while there are elements left: when the loop ends the variables keep their values, which a later instruction may read, so
            # this is not a definition that kills them)
            set vs [lsort -integer -unique [concat {*}[lindex $a 3]]]
            return [list $vs $vs]
        }
        existScalar { return [list [operand [lindex $a 0]] {}] }
        dictUpdateStart - dictUpdateEnd { set vs [concat [list [operand [lindex $a 0]]] [lindex $a 2]]; return [list $vs $vs] }
        dictRecombineImm { set v [operand [lindex $a 0]]; return [list $v $v] }
        dictAppend - dictLappend { set v [operand [lindex $a 0]]; return [list $v $v] }
        dictSet - dictUnset { set v [operand [lindex $a 1]]; return [list $v $v] }
        arrayMakeImm { set v [operand [lindex $a 0]]; return [list $v $v] }
        loadArray1 - loadArray4 - storeArray1 - storeArray4 - appendArray1 - appendArray4 - lappendArray1 - lappendArray4 - incrArray1 - incrArray1Imm - existArray -
        unsetArray - unsetScalar - lappendList - lappendListArray - arrayExistsImm {
            # array element operations: they work on the variable in the frame, so what typed code holds for it must be there
            set v [operand [lindex $a [expr {$op in {unsetArray unsetScalar} ? 1 : 0}]]]
            return [list $v $v]
        }
        default { return [list {} {}] }
    }
}

# ================================================================== per-proc preparation (variant independent)

array set PI {}
set translatable {}

# the innermost exception range around pc for a result code (mode 1 = error: catch ranges only; 3 = break: any range; 4 = continue: a
# range that has a continue target, or a catch range) -- the interpreter's GetExceptRangeForPc; "" if none
proc findRange {ranges pc mode} {
    for {set i [expr {[llength $ranges] - 1}]} {$i >= 0} {incr i -1} {
        set r [lindex $ranges $i]
        if {[dict get $r from] <= $pc && $pc <= [dict get $r to]} {
            if {[dict get $r type] eq "catch"} { return $r }
            if {$mode == 3} { return $r }
            if {$mode == 4 && [dict get $r continue] != -1} { return $r }
        }
    }
    return ""
}

proc prepare {P} {
    global PI
    if {[regexp {[[:cntrl:]]} $P] || [string match *:::* $P]} { refuse "unusual proc name" }
    # (the definition as the program gave it: from the snapshot taken after its file was read when a proc of this translator replaced it since)
    if {[dict exists $::EARLY $P]} { set snap [dict get $::EARLY $P] } else { set snap [::tbcx::snap $P] }
    set bc [dict get $snap bc]
    set args [dict get $snap args]
    set PI($P,infoBody) [dict get $snap body]
    set PI($P,infoArgs) [dict get $snap canon]
    set PI($P,fp) [dict get $snap fp]
    set PI($P,argsIdx) [expr {[lindex $args end] eq "args" ? [llength $args] - 1 : -1}]
    # the default value of each argument ({} when it has none); a call that leaves trailing arguments out passes the defaults of a canonical number
    set PI($P,defaults) [dict get $snap defs]
    set vnames {}; set nargs 0; set vflags {}
    foreach v [dict get $bc variables] {
        set flags [lindex $v 0]
        foreach f $flags { if {$f ni {scalar array arg temp}} { refuse "variable flag $f" } }
        if {"scalar" ni $flags && "array" ni $flags} { refuse "non-scalar variable" }
        if {"arg" in $flags} { incr nargs }
        lappend vnames [lindex $v 1]; lappend vflags $flags
    }
    if {$nargs != [llength $args]} { refuse "argument count mismatch" }

    array set ins {}; set pcs {}
    foreach {pc i} [dict get $bc instructions] { set ins($pc) [list [lindex $i 0] [lrange $i 1 end]]; lappend pcs $pc }
    # foreach: the loop's data is in the auxiliary table; the start jumps to the step (5 bytes on, minus the step's backward offset), which
    # jumps back to the start of the body (offset from the step) and falls through to the end.  Step and end carry the same data.
    set aux [dict get $bc auxiliary]
    foreach pc $pcs {
        if {[lindex $ins($pc) 0] ne "foreach_start"} continue
        set n [string trimleft [lindex $ins($pc) 1 0] ?]
        set ax [lindex $aux $n]
        set jo [dict get $ax jumpOffset]; set vl [dict get $ax assign]; set nl [llength $vl]
        set stepPc [expr {$pc + 5 - $jo}]
        set data [list $n $nl $jo $vl $stepPc]
        set ins($pc) [list foreach_start $data]
        if {![info exists ins($stepPc)] || [lindex $ins($stepPc) 0] ne "foreach_step"} { refuse "foreach without its step" }
        set ins($stepPc) [list foreach_step $data]
        set endPc [lindex $pcs [expr {[lsearch -exact $pcs $stepPc] + 1}]]
        if {[lindex $ins($endPc) 0] ne "foreach_end"} { refuse "foreach without its end" }
        set ins($endPc) [list foreach_end $data]
    }
    foreach pc $pcs {
        if {[lindex $ins($pc) 0] ni {dictUpdateStart dictUpdateEnd}} continue
        lassign [lindex $ins($pc) 1] var ax
        set n [string trimleft $ax ?]
        set ins($pc) [list [lindex $ins($pc) 0] [list $var $n [dict get [lindex $aux $n] variables]]]
    }
    foreach pc $pcs {
        if {[lindex $ins($pc) 0] ne "jumpTable"} continue
        set n [string trimleft [lindex $ins($pc) 1 0] ?]
        set map [dict get [lindex $aux $n] mapping]
        set tg {}
        foreach {k off} $map { lappend tg [expr {$pc + $off}] }
        set ins($pc) [list jumpTable [list $n [lsort -integer -unique $tg] $map]]
    }
    # exception ranges (loops: break and continue targets; catch: handler), innermost last, as the interpreter's table lists them
    set ranges [dict get $bc exception]
    set PI($P,ranges) $ranges
    # the command each instruction belongs to (the innermost one: the last whose code starts at or before the pc and still covers it)
    # (see cmdmap.tcl)
    array set cmdOf [cmdMap $pcs [dict get $bc commands]]
    foreach pc $pcs { set PI($P,src,$pc) $cmdOf($pc) }

    array set nxtOf {}; array set prevOp {}
    for {set i 0} {$i < [llength $pcs]} {incr i} { set nxtOf([lindex $pcs $i]) [lindex $pcs [expr {$i+1}]]; if {$i} { set prevOp([lindex $pcs $i]) [lindex $ins([lindex $pcs [expr {$i-1}]]) 0] } }
    # stack depth at every reachable pc, successors
    array set depth {}; array set depthAtBegin {}; array set mkAt {}; array set mkAtBegin {}; set maxd 0; set targets {}; set iters {}
    array set succ {}
    # mk: the stack depths at which the argument expansions that are open at an instruction started (the interpreter's auxiliary stack)
    set work [list [list 0 0 {}]]
    # A command can end with break or continue; the interpreter then pops the command's operands and goes on at the loop's target, whatever else is on
    # the stack.  Where the depth there is not the one the loop's own flow gives, that result cannot happen (the compiler would be wrong otherwise: a
    # `dict for` cleanup handler's `return -options`, for instance, sits above the iteration state).  Such edges are examined once the flow is known:
    # kept when the depths agree (or when the target is reached no other way), dropped otherwise (the result then leaves the proc, as with no loop).
    set soft {}; array set softDrop {}
    while 1 {
    while {[llength $work]} {
        lassign [lindex $work end] pc d mk
        set work [lrange $work 0 end-1]
        if {[info exists depth($pc)]} {
            if {$depth($pc) != $d} { refuse "inconsistent stack depth at pc $pc" }
            if {$mkAt($pc) ne $mk} { refuse "inconsistent expansion state at pc $pc" }
            continue
        }
        if {![info exists ins($pc)]} { refuse "jump to pc $pc" }
        set depth($pc) $d; set mkAt($pc) $mk
        lassign $ins($pc) op a
        lassign [effect $op $a $d [lindex $mk end]] pops pushes kind tgt
        # the `return -options` behind returnCodeBranch re-raises a caught exception whose code is none of the five it dispatches on: it never completes normally
        if {$op eq "returnStk" && [info exists prevOp($pc)] && $prevOp($pc) eq "returnCodeBranch"} { set kind term }
        if {$d < $pops} { refuse "stack underflow at pc $pc" }
        set nd [expr {$d - $pops + $pushes}]
        switch $op {
            expandStart { set nmk [list {*}$mk $d] }
            invokeExpanded - expandDrop { set nmk [lrange $mk 0 end-1] }
            default { set nmk $mk }
        }
        if {$nd > $maxd} { set maxd $nd }
        if {$op in {dictFirst dictNext}} { lappend iters [operand [lindex $a 0]] }
        set nextpc $nxtOf($pc)
        set PI($P,next,$pc) $nextpc
        if {[tbcCanBC $op $a]} {
            set cl [switch $op { invokeStk1 - invokeStk4 - tailcall { lindex $a 0 } evalStk { expr 1 } invokeReplace { expr {[lindex $a 0] + 1} } invokeExpanded { expr {$d - [lindex $mk end]} } default { expr 2 } }]
            foreach m {3 4} {
                set r [findRange $ranges $pc $m]
                if {$r ne "" && [dict get $r type] ne "catch"} {
                    set tg [dict get $r [expr {$m == 3 ? "break" : "continue"}]]
                    set tmk [expr {[info exists mkAt([dict get $r from])] ? $mkAt([dict get $r from]) : $mk}]
                    if {$tg >= 0} { lappend soft [list $pc $m $tg [expr {$d - $cl}] $tmk] }
                }
            }
        }
        if {$op eq "beginCatch4"} {
            # the handler is entered from anywhere inside the range, with the stack as it is here
            set r [lindex $ranges [lindex $a 0]]
            lappend work [list [dict get $r catch] $d $mk]; lappend targets [dict get $r catch]
            set depthAtBegin([dict get $r catch]) $d; set mkAtBegin([dict get $r catch]) $mk
        }
        switch $kind {
            fall { lappend work [list $nextpc $nd $nmk]; set succ($pc) [list $nextpc] }
            jump { lappend work [list $tgt $nd $nmk]; lappend targets $tgt; set succ($pc) [list $tgt] }
            cond { lappend work [list $tgt $nd $nmk] [list $nextpc $nd $nmk]; lappend targets $tgt; set succ($pc) [list $nextpc $tgt] }
            term { set succ($pc) {} }
            multi {
                foreach t $tgt { lappend work [list $t $nd $nmk]; lappend targets $t }
                lappend work [list $nextpc $nd $nmk]
                set succ($pc) [concat $tgt [list $nextpc]]
            }
            special {
                # break/continue go to the target of the enclosing range; returnCodeBranch to one of the five jumps behind it
                set succ($pc) {}
                if {$op eq "returnCodeBranch"} {
                    foreach o {1 3 5 7 9} { lappend work [list [expr {$pc + $o}] $nd $nmk]; lappend succ($pc) [expr {$pc + $o}]; lappend targets [expr {$pc + $o}] }
                } else {
                    set r [findRange $ranges $pc [expr {$op eq "break" ? 3 : 4}]]
                    if {$r ne ""} {
                        if {[dict get $r type] eq "catch"} {
                            set tg [dict get $r catch]; set td [expr {$depthAtBegin($tg)}]; set tmk $mkAtBegin($tg)
                        } else {
                            set tg [dict get $r [expr {$op eq "break" ? "break" : "continue"}]]; set td $nd
                            set tmk [expr {[info exists mkAt([dict get $r from])] ? $mkAt([dict get $r from]) : $mk}]
                        }
                        lappend succ($pc) $tg; lappend targets $tg
                        if {[dict get $r type] ne "catch"} { lappend work [list $tg $td $tmk] }
                    }
                }
            }
        }
    }
    set progressed 0; array unset pend
    foreach e $soft {
        lassign $e spc m tg sd smk
        if {[info exists depth($tg)]} { set td $depth($tg); set tm $mkAt($tg) } elseif {[info exists pend($tg)]} { lassign $pend($tg) td tm } else { set td $sd; set tm $smk; set pend($tg) [list $sd $smk]; lappend work [list $tg $sd $smk]; set progressed 1 }
        if {$td == $sd && $tm eq $smk} { lappend targets $tg } else { set softDrop($spc,$m) 1 }
    }
    set soft {}
    if {!$progressed} break
    }
    foreach k [array names softDrop] { set PI($P,drop,$k) 1 }
    set iters [lsort -unique $iters]
    # Translated procs have no call frame: a command that reaches the frame's variables by name would not find them.  Every command
    # invoked by name must be known: a proc (it has a frame of its own), or a built-in that is known not to use the caller's variables.
    # (stack of producers: the literal that pushed each slot, or - when it is not one)
    array set pst {}
    set callees {}
    set pure 1
    # "caller-safe": nothing this proc does can reach the variables of the frame that called it (no upvar/uplevel/eval beyond its own frame, only
    # built-ins that stay in their own frame, only callees that are themselves caller-safe).  A typed caller can call such a proc through the
    # interpreter and keep its variables in C locals.
    set csafe 1
    # "yield-safe": nothing this proc runs can reach a `yield` (no script is evaluated, no command whose identity is unknown is called, every proc it calls is
    # itself yield-safe).  Such a proc can run compiled inside a coroutine: a yield below compiled code would have to cross a C frame.  A proc that yields
    # itself ("resumable", yres) can too, if everything else it runs is yield-safe: its boxed code suspends through the interpreter's callbacks.
    set yres 1
    set hasYield 0
    # the built-in commands whose identity the analysis relies on (that they run no script and leave the caller's variables alone)
    set bins {}
    array unset scanVar
    set pst(0) {}; set pwork {0}
    while {[llength $pwork]} {
        set pc [lindex $pwork end]; set pwork [lrange $pwork 0 end-1]
        set st $pst($pc)
        lassign $ins($pc) op a
        lassign [effect $op $a [llength $st] [lindex $mkAt($pc) end]] pops pushes
        switch -- $op {
            push1 - push4 { set out [list {*}$st [operand [lindex $a 0]]] }
            dup { set out [list {*}$st [lindex $st end]] }
            reverse { set n [lindex $a 0]; set out [list {*}[lrange $st 0 end-$n] {*}[lreverse [lrange $st end-[expr {$n-1}] end]]] }
            default { set out [list {*}[lrange $st 0 [expr {[llength $st] - $pops - 1}]] {*}[lrepeat $pushes -]] }
        }
        if {$op in {evalStk exprStk tailcall invokeReplace invokeExpanded}} { set csafe 0 }
        if {$op in {evalStk exprStk invokeReplace invokeExpanded}} { set yres 0 }
        if {$op in {yield yieldToInvoke}} { set csafe 0; set pure 0; set hasYield 1 }
        if {$op eq "upvar"} {
            set lv [lindex $st end-1]
            if {$lv eq "-" || [lindex [dict get $bc literals] $lv] ni {0 #0}} { set csafe 0 }
        }
        # instructions that reach variables by name or link them to other frames make the proc impure
        if {$op in {upvar nsupvar variable infoLevelNumber infoLevelArgs currentNamespace} || ([string match *Stk $op] && $op ne "returnStk") || [string match *StkImm $op]} { set pure 0 }
        # the string operations the executor does in place stand for commands of the `string` ensemble: the module's guard watches them (replacement, traces), like a call by name
        if {[dict exists $::tbcStrOps $op]} { lappend bins [dict get $::tbcStrOps $op] }
        if {$op in {invokeStk1 invokeStk4}} {
            set n [lindex $a 0]; set q [expr {[llength $st] - $n}]
            set c [lindex $st $q]
            if {$c eq "-"} {
                set pure 0; set csafe 0; set yres 0
            } else {
                set nm [lindex [dict get $bc literals] $c]
                set ns [namespace qualifiers $P]; if {$ns eq ""} { set ns :: }
                # `binary scan data fmt var` (typed code does it inline when var is a local): the instruction reads and writes that local by name
                if {[regexp {^(?:::)?tcl::binary::scan$} $nm] && $n == 4} {
                    set wf [lindex $st [expr {$q+2}]]; set wv [lindex $st [expr {$q+3}]]
                    if {$wf ne "-" && $wv ne "-"} {
                        set vi [lsearch -exact $vnames [lindex [dict get $bc literals] $wv]]
                        if {$vi >= 0 && [regexp $::tbcScanFmt [lindex [dict get $bc literals] $wf]]} { set scanVar($pc) $vi }
                    }
                }
                set callee [resolveProc $ns $nm]
                if {$callee ne ""} {
                    lappend callees $callee
                } else {
                    set bn [string trimleft $nm :]
                    if {[string match tcl::array::* $bn] || [string match tcl::string::* $bn] || [string match tcl::list::* $bn] || [isMathBuiltin $bn] || $bn in $::tbcOwnFrameBuiltins || $bn in $::tbcPureBuiltins} {
                        # (stays in its own frame, runs no script)
                        if {![isMathBuiltin $bn] && ![string match tcl::mathfunc::* $bn]} { lappend bins $nm }
                    } elseif {[regexp {^tcl::dict::(\w+)$} $bn -> dsub] && $dsub in {size keys values get exists create merge replace remove}} {
                        lappend bins $nm
                    } else {
                        set csafe 0; set yres 0
                    }
                    set w2 [expr {$n > 1 ? [lindex $st [expr {$q+1}]] : "-"}]
                    set sub [expr {$w2 eq "-" ? "-" : [lindex [dict get $bc literals] $w2]}]
                    set b $nm; regsub {^::} $b {} b
                    if {[regexp {^tcl::dict::(\w+)$} $b -> sub1]} { set b dict; set sub $sub1 }
                    if {[string match tcl::string::* $b] || [string match tcl::list::* $b] || [isMathBuiltin $b]} {
                        # the string ensemble's own implementations and the math functions never use the caller's variables
                    } elseif {$b eq "dict"} {
                        if {$sub ni {size keys values get exists create merge replace remove}} { set pure 0 }
                    } elseif {$b ni $::tbcPureBuiltins} {
                        set pure 0
                    }
                }
            }
        }
        set pdst $succ($pc)
        if {$op eq "beginCatch4"} { lappend pdst [dict get [lindex $ranges [lindex $a 0]] catch] }
        foreach s $pdst {
            if {![info exists pst($s)]} { set pst($s) $out; lappend pwork $s } else {
                set j [lmap x $pst($s) y $out {expr {$x eq $y ? $x : "-"}}]
                if {$j ne $pst($s)} { set pst($s) $j; lappend pwork $s }
            }
        }
    }
    foreach it $iters { if {"temp" ni [lindex $vflags $it]} { refuse "dict iterator in a named variable" } }
    set reach [lsort -integer [array names depth]]

    # successors for the data flow: besides the normal ones, a catch handler can be entered from anywhere inside its range, and a command
    # that returns break/continue/return codes can jump to the targets of the loops around it
    array set dsucc {}
    foreach pc $reach {
        set l $succ($pc)
        foreach r $ranges { if {[dict get $r type] eq "catch" && [dict get $r from] <= $pc && $pc <= [dict get $r to]} { lappend l [dict get $r catch] } }
        lassign $ins($pc) op a
        if {[tbcCanBC $op $a]} {
            foreach m {3 4} {
                if {[info exists PI($P,drop,$pc,$m)]} continue
                set r [findRange $ranges $pc $m]
                if {$r ne "" && [dict get $r type] ne "catch"} { lappend l [dict get $r [expr {$m == 3 ? "break" : "continue"}]] }
            }
        }
        set dsucc($pc) [lsort -integer -unique [lmap x $l {expr {[info exists depth($x)] ? $x : [continue]}}]]
    }
    # liveness of locals (backward) and definite assignment (forward)
    array set use {}; array set def {}
    foreach pc $reach { lassign $ins($pc) op a; lassign [usedef $op $a] use($pc) def($pc) }
    foreach pc [array names scanVar] { if {[info exists use($pc)]} { lappend use($pc) $scanVar($pc); lappend def($pc) $scanVar($pc) } }
    array set liveIn {}
    # (two rounds: a foreach step reads its variables, because they keep their values when the loop ends, and that makes them live from the start of the proc, so unset
    # there, so boxed; the second round keeps that read only for the variables that are live where the loop ends, the ones something after the loop reads)
    for {set round 0} {$round < 2} {incr round} {
        if {$round == 1} {
            set refined 0
            foreach pc $reach {
                if {[lindex $ins($pc) 0] ne "foreach_step"} continue
                set vs [lsort -integer -unique [concat {*}[lindex [lindex $ins($pc) 1] 3]]]
                set exitLive $liveIn($nxtOf($pc))
                set keep [lmap v $vs {expr {$v in $exitLive ? $v : [continue]}}]
                if {$keep ne $use($pc)} { set use($pc) $keep; set refined 1 }
            }
            if {!$refined} break
        }
        foreach pc $reach { set liveIn($pc) {} }
        set changed 1
        while {$changed} {
            set changed 0
            foreach pc [lreverse $reach] {
                set out {}
                foreach s $dsucc($pc) { set out [lsort -integer -unique [concat $out $liveIn($s)]] }
                set nl [lsort -integer -unique [concat $use($pc) [lmap v $out {expr {$v in $def($pc) ? [continue] : $v}}]]]
                if {$nl ne $liveIn($pc)} { set liveIn($pc) $nl; set changed 1 }
            }
        }
    }
    set allv {}; for {set v 0} {$v < [llength $vnames]} {incr v} { lappend allv $v }
    set params {}; for {set v 0} {$v < $nargs} {incr v} { lappend params $v }
    array set asgIn {}
    foreach pc $reach { set asgIn($pc) $allv }
    set asgIn(0) $params
    set changed 1
    while {$changed} {
        set changed 0
        foreach pc $reach {
            set out [lsort -integer -unique [concat $asgIn($pc) $def($pc)]]
            foreach s $dsucc($pc) {
                set ni [expr {$s == 0 ? $params : [lmap v $asgIn($s) {expr {$v in $out ? $v : [continue]}}]}]
                if {$ni ne $asgIn($s)} { set asgIn($s) $ni; set changed 1 }
            }
        }
    }
    # variables that may have been assigned on some path to a pc (their frame slots may have to be written if the code leaves typed mode there)
    array set mayIn {}
    foreach pc $reach { set mayIn($pc) {} }
    set mayIn(0) $params
    set changed 1
    while {$changed} {
        set changed 0
        foreach pc $reach {
            set out [lsort -integer -unique [concat $mayIn($pc) $def($pc)]]
            foreach s $dsucc($pc) {
                set ni [lsort -integer -unique [concat $mayIn($s) $out]]
                if {$ni ne $mayIn($s)} { set mayIn($s) $ni; set changed 1 }
            }
        }
    }
    # variables that are assigned on some paths only: a proc that can be asked about its variables by name must hold them boxed (unset = NULL)
    set mustBoxNamed {}
    foreach pc $reach { foreach v $mayIn($pc) { if {$v ni $asgIn($pc)} { lappend mustBoxNamed $v } } }
    # a variable that may be read before it is assigned cannot be held unboxed
    set mustBox {}
    foreach pc $reach { foreach v $liveIn($pc) { if {$v ni $asgIn($pc)} { lappend mustBox $v } } }

    # variables typed code keeps in the frame (kind F): the targets of upvar/variable and the arrays whose elements it works on.  Such a proc runs in
    # its own frame only (it is not pure: a direct call cannot reach it).
    set fv {}
    foreach pc $reach {
        lassign $ins($pc) op a
        switch -- $op {
            upvar - nsupvar - variable - loadArray1 - loadArray4 - storeArray1 - storeArray4 - appendArray1 - appendArray4 - lappendArray1 - lappendArray4 -
            incrArray1 - incrArray1Imm - existArray - arrayExistsImm - lappendListArray { lappend fv [operand [lindex $a 0]] }
            unsetArray { lappend fv [operand [lindex $a 1]] }
        }
    }
    # arrays that only element loads, stores, increments and tests touch (and that are not arguments) are kept by typed code in a table of its own and
    # written into the frame, element by element in the order they were made, when typed code gives up (kind R).  Nothing else can see such an array
    # while typed code runs, so they do not make a proc impure.
    set rv {}
    foreach pc $reach {
        lassign $ins($pc) op a
        if {$op in $::tbcRops} { lappend rv [operand [lindex $a 0]] }
    }
    set rv [lsort -integer -unique [lmap v $rv {expr {$v < $nargs ? [continue] : $v}}]]
    foreach pc $reach {
        lassign $ins($pc) op a
        if {$op in $::tbcRops} continue
        foreach v [concat {*}[usedef $op $a]] { set rv [lsearch -all -inline -not -exact $rv $v] }
        if {[info exists scanVar($pc)]} { set rv [lsearch -all -inline -not -exact $rv $scanVar($pc)] }
    }
    if {$hasYield} { set rv {} }
    set PI($P,rvars) $rv
    set fv [lmap v $fv {expr {$v in $rv ? [continue] : $v}}]
    set PI($P,fvars) [lsort -integer -unique $fv]
    if {[llength $fv]} { set pure 0 }
    set PI($P,csafe) $csafe; set PI($P,ysafe) [expr {$yres && !$hasYield}]; set PI($P,yres) [expr {$yres && $hasYield}]; set PI($P,hasYield) $hasYield; set PI($P,bins) [lsort -unique $bins]
    set PI($P,callees) [lsort -unique $callees]; set PI($P,pure) $pure; set PI($P,mustBoxNamed) [lsort -unique $mustBoxNamed]
    set PI($P,args) $args; set PI($P,nargs) $nargs; set PI($P,vnames) $vnames; set PI($P,lits) [dict get $bc literals]
    # a literal the compiler folded is a double object with no string yet (or one whose printed form is not exact: Tcl prints 2^64 as
    # 1.844674407370955e+19, which parses to the double below): take the value of the object itself, before anything turns it into text
    set litd {}
    # (not through expr: its ?: result is parsed as a number and printed again the short way, which gives 2^64 back as the double below)
    foreach l $PI($P,lits) {
        # a literal written in the source has its text, and the text must be kept when it reads back as the same number (1e3 is not 1000.0, even
        # after something has parsed it as a double); an object whose text does not read back as its value (Tcl's own text for 2^64) is taken by value
        if {![string match {value is a double *} [tcl::unsupported::representation $l]]} { lappend litd ""; continue }
        set dv [c_dbl $l]
        if {[string match {*, no string representation} [tcl::unsupported::representation $l]]} { lappend litd $dv; continue }
        set txt [string cat [string range $l 0 0] [string range $l 1 end]]
        if {[string is double -strict $txt] && [c_dbl $txt] eq $dv} { lappend litd "" } else { lappend litd $dv }
    }
    set PI($P,litd) $litd
    set PI($P,pcs) $pcs; set PI($P,reach) $reach; set PI($P,maxd) $maxd; set PI($P,targets) [lsort -unique $targets]
    set PI($P,iters) $iters; set PI($P,mustBox) [lsort -unique $mustBox]
    set lh {}
    foreach pc [array names succ] { foreach t $succ($pc) { if {$t <= $pc} { lappend lh $t } } }
    set PI($P,loopheads) [lsort -integer -unique $lh]
    set exl 0
    foreach pc $reach { set PI($P,mk,$pc) $mkAt($pc); set l [llength $mkAt($pc)]; if {[lindex $ins($pc) 0] eq "expandStart"} { incr l }; if {$l > $exl} { set exl $l } }
    set PI($P,exlevels) $exl
    # a yield suspends the boxed code, which keeps only the operand stack: no dictionary iteration may be in progress, and no expansion
    if {$hasYield} {
        if {[llength $iters]} { refuse "yield in a proc with a dictionary iteration" }
        foreach pc $reach { if {[lindex $ins($pc) 0] in {yield yieldToInvoke} && ([llength $mkAt($pc)] || [lindex $ins($pc) 0] eq "expandStart")} { refuse "yield inside an argument expansion" } }
    }
    foreach pc $pcs { set PI($P,ins,$pc) $ins($pc) }
    foreach pc $reach { set PI($P,depth,$pc) $depth($pc); set PI($P,succ,$pc) $succ($pc); set PI($P,live,$pc) $liveIn($pc); set PI($P,may,$pc) $mayIn($pc) }
    set PI($P,reach) $reach
    set PI($P,vecok) [vecEligible $P]
    set PI($P,mapok) [mapEligible $P]
    # literal classes: canonical integers and doubles can be used as numbers; everything else stays a string
    set cls {}
    foreach s $PI($P,lits) {
        set c [list L]
        if {[lindex $PI($P,litd) [llength $cls]] ne ""} {
            set dd [lindex $PI($P,litd) [llength $cls]]
            if {![string match *inf* $dd] && ![string match *nan* $dd]} { set c [list D] }
        } elseif {[regexp {^-?(0|[1-9][0-9]*)$} $s] && $s ne "-0" && $s >= -9223372036854775808 && $s <= 9223372036854775807} {
            set c [list I]
        } elseif {[string is double -strict $s] && ![regexp {[^0-9eE.+-]} $s]} {
            set dv [expr {double($s)}]
            if {[string equal $dv $s] && $dv == $dv && abs($dv) < 1.7e308} { set c [list D] }
        }
        lappend cls $c
    }
    set PI($P,lcls) $cls
    # evidence of floating-point numbers: a double literal, or a call of a function that gives a double (see wpol)
    set fl 0
    foreach c $cls { if {$c eq "D"} { set fl 1; break } }
    if {!$fl} { foreach s $PI($P,lits) { if {[regexp {^(?:::)?tcl::mathfunc::(?:double|sqrt|sin|cos|tan|asin|acos|atan|atan2|sinh|cosh|tanh|exp|log|log10|fmod|hypot|floor|ceil)$} $s]} { set fl 1; break } } }
    set PI($P,floaty) $fl
    # a proc without such a sign that does arithmetic can still meet doubles in the data: it gets a second version with tagged numbers (key <proc>/BB..w), used once an object
    # operand has turned out to be a double (see wadapt in tbc_runtime.h)
    # (not one that uses bit operations or %, which are errors for a double: checksums, ciphers and number theory work on integers, and the second version would be code that is
    # never used there)
    set ar 0; set intonly 0
    foreach pc $reach {
        set o [lindex $ins($pc) 0]
        if {$o in {add sub mult div}} { set ar 1 }
        if {$o in {mod bitand bitor bitxor lshift rshift bitnot}} { set intonly 1 }
    }
    # (and one whose arithmetic is on data: a variable that is assigned an expression of itself, `set sum [expr {$sum + $x}]`, or an operand that is a foreach variable)
    set data 0
    if {$ar && !$intonly} {
        set fvs {}
        foreach pc $reach { lassign $ins($pc) o a; if {$o eq "foreach_step"} { foreach v [concat {*}[lindex $a 3]] { lappend fvs $v } } }
        set loaded {}; set sawA 0; set dflag 0
        foreach pc $reach {
            lassign $ins($pc) o a
            switch -- $o {
                startCommand { set loaded {}; set sawA 0; set dflag 0 }
                loadScalar1 - loadScalar4 { set v [operand [lindex $a 0]]; lappend loaded $v; if {$v in $fvs} { set dflag 1 } }
                add - sub - mult - div { set sawA 1; if {$dflag} { set data 1 } }
                storeScalar1 - storeScalar4 { if {$sawA && [operand [lindex $a 0]] in $loaded} { set data 1 } }
            }
        }
    }
    set PI($P,wadapt) [expr {!$fl && $data && !$hasYield && [llength $PI($P,loopheads)] && ![info exists ::env(TBC_FORCE_WPOLICY)]}]
}

# Where the value that the instruction at pc pushed in slot q goes: every path from there must end at an instruction that takes the slot, and each such instruction is returned as
# {op position-from-the-top pc}.  "" when the paths are too many or an instruction uses the slot without taking it (dup, over, reverse, an argument expansion).
proc slotUsers {P pc q} {
    global PI
    set users {}
    set seen {}
    set todo [list $PI($P,next,$pc)]
    set steps 0
    while {[llength $todo]} {
        set cur [lindex $todo end]; set todo [lrange $todo 0 end-1]
        if {[dict exists $seen $cur]} continue
        dict set seen $cur 1
        if {[incr steps] > 600} { return "" }
        if {![info exists PI($P,depth,$cur)]} { return "" }
        lassign $PI($P,ins,$cur) op a
        set d $PI($P,depth,$cur)
        if {$d <= $q} continue
        switch -- $op {
            expandStart - expandStkTop - invokeExpanded - expandDrop { return "" }
            dup { if {$d - 1 == $q} { lappend users [list dup 0 $cur]; continue } }
            over { if {$d - 1 - [operand [lindex $a 0]] == $q} { lappend users [list over 0 $cur]; continue } }
            reverse { if {$d - [lindex $a 0] <= $q} { lappend users [list reverse 0 $cur]; continue } }
        }
        lassign [effect $op $a $d {}] pops pushes kind
        if {$d - $pops <= $q} { lappend users [list $op [expr {$d - 1 - $q}] $cur]; continue }
        if {$kind ni {fall jump cond}} { return "" }
        foreach sc $PI($P,succ,$cur) { lappend todo $sc }
    }
    return $users
}
# The local variables that may be held as native integer vectors when a list of integers is built in them (`set l {}`, `lappend l $i`): those that only list instructions that typed code
# does on a vector take (lindex, llength, lset, foreach over the list, the return), and that are assigned and appended to by nothing else.  A list that is passed to a command, joined,
# sorted... stays a Tcl list: making it a vector would only turn it back into one.
proc vecEligible {P} {
    global PI
    set bad {}
    foreach pc $PI($P,reach) {
        lassign $PI($P,ins,$pc) op a
        lassign [usedef $op $a] uses defs
        if {$op ni {loadScalar1 loadScalar4 storeScalar1 storeScalar4 lappendScalar1 lappendScalar4}} {
            foreach v [concat $uses $defs] { dict set bad $v 1 }
            continue
        }
        if {$op in {lappendScalar1 lappendScalar4}} {
            # (the result of lappend is the list: it may only be dropped or returned)
            set v [operand [lindex $a 0]]
            if {[dict exists $bad $v]} continue
            set users [slotUsers $P $pc [expr {$PI($P,depth,$pc) - 1}]]
            if {$users eq ""} { dict set bad $v 1; continue }
            foreach u $users { lassign $u uop pos upc; if {!($uop in {pop done} && $pos == 0)} { dict set bad $v 1; break } }
            continue
        }
        if {$op in {loadScalar1 loadScalar4}} {
            set v [operand [lindex $a 0]]
            if {[dict exists $bad $v]} continue
            set users [slotUsers $P $pc $PI($P,depth,$pc)]
            if {$users eq ""} { dict set bad $v 1; continue }
            foreach u $users {
                lassign $u uop pos upc
                set ok 0
                switch -- $uop {
                    listIndex { set ok [expr {$pos == 1}] }
                    listIndexImm - listLength - lsetList - done { set ok [expr {$pos == 0}] }
                    foreach_start {
                        # (one list, one variable: the loop goes through a copy of the vector)
                        lassign [lindex $PI($P,ins,$upc) 1] fn_ fnl_ fjo_ fvl_ fsp_
                        set ok [expr {$pos == 0 && $fnl_ == 1 && [llength [lindex $fvl_ 0]] == 1}]
                    }
                }
                if {!$ok} { dict set bad $v 1; break }
            }
        }
    }
    set r {}
    for {set v $PI($P,nargs)} {$v < [llength $PI($P,vnames)]} {incr v} {
        if {![dict exists $bad $v] && $v ni $PI($P,fvars) && $v ni $PI($P,rvars)} { lappend r $v }
    }
    return $r
}

# The pcs that lie on a cycle of the flow graph (loops): a pc is on one if it can reach itself.
proc cyclePcs {P} {
    global PI
    set on {}
    foreach h $PI($P,loopheads) {
        # forward from the head, backward from it, over the successors recorded: the loop is the pcs both reachable from the head and reaching it
        set fw {}; set todo [list $h]
        while {[llength $todo]} { set c [lindex $todo end]; set todo [lrange $todo 0 end-1]; if {[dict exists $fw $c]} continue; dict set fw $c 1; foreach s $PI($P,succ,$c) { lappend todo $s } }
        set bw {}; dict set bw $h 1; set changed 1
        while {$changed} {
            set changed 0
            foreach c [dict keys $fw] { if {[dict exists $bw $c]} continue; foreach s $PI($P,succ,$c) { if {[dict exists $bw $s]} { dict set bw $c 1; set changed 1; break } } }
        }
        foreach c [dict keys $bw] { if {[dict exists $fw $c]} { dict set on $c 1 } }
    }
    return $on
}
# The local variables that may be held as native maps (decision 39): a dict that is incremented (`dict incr d $k`) and that is begun empty (`set d {}`); what else is done to it is
# read by key (`dict get`, `dict exists`, one key) or is an escape - anything the typed code does not do on a map, which boxes a copy of it - and an escape may not be in a loop, so
# that the copy is made once: a loop that works on the map and a `dict for` after it is the common shape.
proc mapEligible {P} {
    global PI
    set cand {}
    foreach pc $PI($P,reach) {
        lassign $PI($P,ins,$pc) op a
        if {$op eq "dictIncrImm"} { dict set cand [operand [lindex $a 1]] 1 }
    }
    if {![dict size $cand]} { return {} }
    set cyc [cyclePcs $P]
    set bad {}
    foreach pc $PI($P,reach) {
        lassign $PI($P,ins,$pc) op a
        if {$op eq "dictIncrImm"} continue
        lassign [usedef $op $a] uses defs
        set vs {}
        foreach v [concat $uses $defs] { if {[dict exists $cand $v]} { lappend vs $v } }
        if {![llength $vs]} continue
        set inloop [dict exists $cyc $pc]
        if {$op in {storeScalar1 storeScalar4}} {
            # (the begin: an empty value; any other store is an escape from the map, which is a use that is wrong in a loop)
            if {$inloop && [mapStoreNotEmpty $P $pc]} { foreach v $vs { dict set bad $v 1 } }
            continue
        }
        if {$op in {loadScalar1 loadScalar4}} {
            set v [operand [lindex $a 0]]
            set users [slotUsers $P $pc $PI($P,depth,$pc)]
            set ok 1
            if {$users eq ""} { set ok 0 }
            foreach u $users {
                lassign $u uop pos upc
                if {!($uop in {dictGet dictExists} && $pos == 1 && [lindex [lindex $PI($P,ins,$upc) 1] 0] == 1)} { set ok 0 }
            }
            if {!$ok && $inloop} { dict set bad $v 1 }
            continue
        }
        if {$inloop} { foreach v $vs { dict set bad $v 1 } }
    }
    set r {}
    foreach v [dict keys $cand] { if {![dict exists $bad $v] && $v >= $PI($P,nargs) && $v ni $PI($P,fvars) && $v ni $PI($P,rvars)} { lappend r $v } }
    return [lsort -integer $r]
}
# does the store at pc store something other than the empty string? (the instruction before it pushed a literal)
proc mapStoreNotEmpty {P pc} {
    global PI
    set i [lsearch -exact $PI($P,pcs) $pc]
    if {$i < 1} { return 1 }
    set pp [lindex $PI($P,pcs) [expr {$i - 1}]]
    lassign $PI($P,ins,$pp) op a
    if {$op in {push1 push4}} { return [expr {[lindex $PI($P,lits) [operand [lindex $a 0]]] ne ""}] }
    return 1
}

set refusedProcs {}
foreach p $procNames {
    set t0 [clock milliseconds]
    set rc0 [catch {prepare $p} res opts]
    if {[info exists ::env(TBC_TIMING)] && [clock milliseconds] - $t0 > 500} { puts stderr "TIME [expr {[clock milliseconds] - $t0}] ms: $p" }
    if {$rc0} {
        if {[dict get $opts -errorcode] eq "TBC_REFUSED"} { lappend refusedProcs [list $p $res]; if {$census} { puts "REFUSED $p :: $res" } else { puts stderr "translate: $p stays interpreted: $res" }; continue }
        if {$census} { puts "ERROR $p :: [string map [list \n { }] $res]"; continue }
        return -options $opts $res
    }
    lappend translatable $p
}
# a proc is pure if it only uses pure built-ins and calls only pure compiled procs: nothing can then observe its frame, so while it runs
# in typed code it needs none (and a direct call to it from compiled code skips the interpreter's call entirely)
set pureProcs [lmap P $translatable {expr {$PI($P,pure) ? $P : [continue]}}]
set pruned 1
while {$pruned} {
    set pruned 0
    foreach P $pureProcs {
        foreach c $PI($P,callees) {
            if {$c ni $pureProcs} { set pureProcs [lsearch -all -inline -not -exact $pureProcs $P]; set pruned 1; break }
        }
    }
}
foreach P $translatable { set PI($P,pure) [expr {$P in $pureProcs}] }
# caller-safe procs: caller-safe themselves, and every proc they call is translated and caller-safe
set csafeProcs [lmap P $translatable {expr {$PI($P,csafe) ? $P : [continue]}}]
set pruned 1
while {$pruned} {
    set pruned 0
    foreach P $csafeProcs {
        foreach c $PI($P,callees) {
            if {$c ni $csafeProcs} { set csafeProcs [lsearch -all -inline -not -exact $csafeProcs $P]; set pruned 1; break }
        }
    }
}
# yield-safe procs: yield-safe themselves, and every proc they call is translated and yield-safe
set ysafeProcs [lmap P $translatable {expr {$PI($P,ysafe) ? $P : [continue]}}]
set pruned 1
while {$pruned} {
    set pruned 0
    foreach P $ysafeProcs {
        foreach c $PI($P,callees) {
            if {$c ni $ysafeProcs} { set ysafeProcs [lsearch -all -inline -not -exact $ysafeProcs $P]; set pruned 1; break }
        }
    }
}
# resumable procs (they yield themselves; everything else they run is yield-safe)
set yresProcs [lmap P $translatable {expr {$PI($P,yres) ? $P : [continue]}}]
set yresProcs [lmap P $yresProcs {expr {[llength [lmap c $PI($P,callees) {expr {$c in $ysafeProcs ? [continue] : $c}}]] ? [continue] : $P}}]
# every proc a yield-safe or resumable proc calls, directly or through others
proc ydeps {P} {
    global PI ysafeProcs yresProcs
    if {$P ni $ysafeProcs && $P ni $yresProcs} { return {} }
    set seen {}; set todo $PI($P,callees)
    while {[llength $todo]} {
        set c [lindex $todo end]; set todo [lrange $todo 0 end-1]
        if {$c in $seen} continue
        lappend seen $c
        set todo [concat $todo $PI($c,callees)]
    }
    return [lsort $seen]
}
# the built-in commands a proc depends on, with those of every proc it calls, as {name namespace} pairs (a name is looked up from the namespace of the proc that
# uses it)
proc gdeps {P} {
    global PI
    set seen {}; set todo [list $P]; set r {}
    while {[llength $todo]} {
        set c [lindex $todo end]; set todo [lrange $todo 0 end-1]
        if {$c in $seen || ![info exists PI($c,bins)]} continue
        lappend seen $c
        set ns [namespace qualifiers $c]; if {$ns eq ""} { set ns :: }
        foreach b $PI($c,bins) { lappend r [list $b $ns] }
        set todo [concat $todo $PI($c,callees)]
    }
    return [lsort -unique $r]
}
# The ensembles of Tcl (`string`, `binary`, ...) the built-ins a proc uses (and the procs it calls) are subcommands of, as a bit mask over tbcEnsembles: an execution
# trace on the ensemble is run by the interpreter's dispatch of `binary format`, which compiled code skips, so an entry whose body uses a subcommand of one looks at its trace
# flag when it is entered (tbc_guard_ok) - as one test of a command the runtime pinned, not as a dependency of the guard, which costs a lookup per name at every entry
set tbcEnsembles {string binary list dict array}
proc ensIndex {b} {
    if {[regexp {^(?:::)?tcl::(\w+)::\w+$} $b -> ens]} { return [lsearch -exact $::tbcEnsembles $ens] }
    return -1
}
proc ensMask {P} {
    global PI
    set seen {}; set todo [list $P]; set m 0
    while {[llength $todo]} {
        set c [lindex $todo end]; set todo [lrange $todo 0 end-1]
        if {$c in $seen || ![info exists PI($c,bins)]} continue
        lappend seen $c
        foreach b $PI($c,bins) { set i [ensIndex $b]; if {$i >= 0} { set m [expr {$m | (1 << $i)}] } }
        set todo [concat $todo $PI($c,callees)]
    }
    return $m
}
proc flushSet {P pc} { global PI; expr {$PI($P,pure) ? $PI($P,live,$pc) : $PI($P,may,$pc)} }
# A proc that can be asked about its variables by name (not pure) must write every variable that was assigned on some path into the frame when it leaves
# typed mode, and only those: a variable that is assigned on some paths only and is never read before it is assigned is held unboxed with a flag
# `g<v>` that says whether it has been assigned on the way taken ("flagged"); one that may be read before it is assigned has to be boxed (unset = NULL).
proc mustBoxOf {P} { global PI; return $PI($P,mustBox) }
proc flaggedOf {P} {
    global PI
    if {$PI($P,pure)} { return {} }
    set r {}
    foreach v $PI($P,mustBoxNamed) { if {$v ni $PI($P,mustBox) && $v ni $PI($P,fvars)} { lappend r $v } }
    return [lsort -integer -unique $r]
}
if {$census} { foreach P $translatable { puts "OK $P" }; exit 0 }

# ================================================================== abstract values
# a stack slot is described by a kind letter, optionally ":<literal index>":  I int64, D double, B Tcl_Obj*, L a string literal
# (no variable, materialised on demand), U not known yet (while return types are still being worked out).

proc kd {e} { string index $e 0 }
proc lt {e} { set i [string first : $e]; expr {$i < 0 ? "" : [string range $e [expr {$i+1}] end]} }
# W: a number that carries its own tag (integer or double): in the stack slots and the variables of a proc that uses floating-point numbers (the "W policy",
# wpol), where an integer-or-double result must not be a guess.  Slot p of kind W holds the tag in sw<p>, the integer in si<p>, the double in sd<p>; a variable v
# the tag in wt<v>, i<v> and d<v>.
set curWpol 0
proc wpol {P} {
    global PI
    if {$PI($P,hasYield)} { return 0 }
    return [expr {[info exists ::env(TBC_FORCE_WPOLICY)] || $PI($P,floaty)}]
}
# the policy of one variant: the static one of the proc, or the tagged-number version of a proc that adapts (its key ends in w)
proc wpolK {key} {
    lassign [keysplit $key] P sig
    return [expr {[wpol $P] || [string match *w $sig]}]
}
proc jd {a b} {
    if {$a eq $b} { return $a }
    set ka [kd $a]; set kb [kd $b]
    if {$ka eq "U"} { return $b }
    if {$kb eq "U"} { return $a }
    if {$ka eq $kb && $ka in {I D}} { return $ka }
    if {$::curWpol && $ka in {I D W} && $kb in {I D W}} { return W }
    return B
}
proc jk {a b} {
    if {$a eq $b} { return $a }
    if {$a eq "F" || $b eq "F"} { return F }
    if {$a in {- U}} { return $b }
    if {$b in {- U}} { return $a }
    if {$::curWpol && $a in {I D W} && $b in {I D W}} { return W }
    if {$::curWpol && (($a eq "S" && $b in {I D W}) || ($b eq "S" && $a in {I D W}))} { return W }
    # S: a boxed value that is loaded from an array or a list into a variable that is used as a number (see specStore): an integer variable if it is stored integers
    # as well, else boxed
    if {$a eq "S" && $b in {S I}} { return [expr {$b eq "I" ? "I" : "S"}] }
    if {$b eq "S" && $a eq "I"} { return I }
    return B
}
proc jstate {a b} { lmap x $a y $b { jd $x $y } }

proc ctype {k} { switch $k { I {return int64_t} D {return double} default {return "Tcl_Obj *"} } }
proc svar {k p} { switch $k { I {return si$p} D {return sd$p} default {return s$p} } }

# C expression giving an owned boxed object for slot p (described by e)
proc boxe {P p e} {
    switch [kd $e] {
        L { return "tbc_ref(L_[cident $P]_[lt $e])" }
        I { if {[lt $e] ne ""} { return "tbc_ref(L_[cident $P]_[lt $e])" } else { return "tbc_newint(si$p)" } }
        D { if {[lt $e] ne ""} { return "tbc_ref(L_[cident $P]_[lt $e])" } else { return "tbc_newdbl(sd$p)" } }
        A {
            # alias: in a fall-back stub the local has just been turned into a list, and the slot shares it (as the interpreter's stack does)
            # copy: typed code needs a value of its own
            switch $::boxMode {
                alias { return "tbc_ref(l[lt $e])" }
                copy { return "tbc_ivec_list(&av[lt $e], 0)" }
                default { return "tbc_ivec_list(&av[lt $e], 0)" }
            }
        }
        T {
            # the iteration state of a foreach (the stack slot of the interpreter's foreach holds an object with the iteration number and the count)
            return "({ Tcl_Obj *c_ = Tcl_NewObj(); c_->internalRep.twoPtrValue.ptr1 = INT2PTR(fit_[lt $e]); c_->internalRep.twoPtrValue.ptr2 = INT2PTR(fmax_[lt $e]); Tcl_IncrRefCount(c_); c_; })"
        }
        K { if {[lt $e] eq "2"} { return "tbc_newpair(ka$p, kj$p)" }; return "tbc_newkey(kb$p, kl$p)" }
        W { return "(sw$p ? tbc_newdbl(sd$p) : tbc_newint(si$p))" }
        N { return "tbc_ivec_list(&sv$p, 1)" }
        M {
            switch $::boxMode {
                alias { return "tbc_ref(l[lt $e])" }
                copy { return "tbc_imap_dict(&mv[lt $e], 0)" }
                default { return "tbc_imap_dict(&mv[lt $e], 0)" }
            }
        }
        Q { return "tbc_imap_dict(&qv$p, 1)" }
        default { return "NULL /* unknown slot $p */" }
    }
}
# code making slot p (described by e) a boxed object in s$p that holds one reference
proc boxc {P p e} {
    if {[kd $e] eq "B"} { return "" }
    return "s$p = [boxe $P $p $e];"
}
# conversion on an edge from state `from` to state `to`
proc edgec {P from to} {
    set ::boxMode edge
    set c [edgec1 $P $from $to]
    set ::boxMode copy
    return $c
}
set boxMode copy
set DCNAMES {}
# code boxing the typed locals that a fall-back needs: the live ones, and the vectors that slots of `slots` are views of
proc boxLocals {key live slots} {
    global VK
    set P [lindex [keysplit $key] 0]
    set vs $live
    foreach e $slots { if {[kd $e] in {A M}} { lappend vs [lt $e] } }
    set c ""
    foreach v [lsort -integer -unique $vs] {
        switch [kap $key $v] {
            W { append c " l$v = (wt$v ? tbc_newdbl(d$v) : tbc_newint(i$v));" }
            I { append c " [expr {$v in [flaggedOf $P] ? "if (g$v) " : ""}]l$v = tbc_newint(i$v);" } D { append c " [expr {$v in [flaggedOf $P] ? "if (g$v) " : ""}]l$v = tbc_newdbl(d$v);" } A { append c " l$v = tbc_ivec_list(&av$v, 1);" } M { append c " l$v = tbc_imap_dict(&mv$v, 1);" }
        }
    }
    return $c
}
proc edgec1 {P from to} {
    set c ""
    for {set p 0} {$p < [llength $from]} {incr p} {
        set f [lindex $from $p]; set t [lindex $to $p]
        if {[kd $t] eq "B" && [kd $f] ne "B"} { append c [boxc $P $p $f] " " }
        if {[kd $t] eq "W" && [kd $f] in {I D}} { append c "sw$p = [expr {[kd $f] eq "D"}]; " }
    }
    return $c
}
# bit mask (hex) of the slots that hold a boxed reference
proc maskOf {st} {
    set m 0
    for {set p 0} {$p < [llength $st]} {incr p} { if {[kd [lindex $st $p]] eq "B"} { set m [expr {$m | (1 << $p)}] } }
    return [format %x $m]
}

# ================================================================== variants
# key = "<proc>/<sig>".  VK(key,kap): kinds of the locals (flow-insensitive: one representation per variable for the whole
# function); VK(key,ret): kind of the result; VK(key,in,<pc>): stack state on entry to each pc reached by typed code.

array set VK {}
set variants {}

proc newVariant {P sig} {
    global VK variants PI
    set key $P/$sig
    if {[info exists VK($key,kap)]} { return $key }
    lappend variants $key
    set kap {}
    for {set v 0} {$v < [llength $PI($P,vnames)]} {incr v} {
        dict set kap $v [expr {$v in $PI($P,fvars) ? "F" : $v in $PI($P,rvars) ? "R" : $v < $PI($P,nargs) ? [string index $sig $v] : "-"}]
    }
    set VK($key,kap) $kap; set VK($key,ret) "-"; set VK($key,calls) {}
    # kinds of the elements of the native arrays (kind R): I while everything stored in the array is an integer in its canonical form, so that a load gives an unboxed integer
    set ekap {}
    foreach v $PI($P,rvars) { dict set ekap $v - }
    set VK($key,ekap) $ekap
    return $key
}

proc kap {key v} { global VK; dict get $VK($key,kap) $v }
proc ekap {key v} { global VK; dict get $VK($key,ekap) $v }

# result of one typed step
proc R {flow out code args} { dict create flow $flow out $out code $code stores {} estores {} ret "" calls {} stub "" {*}$args }

# (beginCatch4 and endCatch change nothing in typed code: a catch is the business of the exception range table.  Typed code that fails inside a catch body
# hands over to the boxed code at that instruction, which dispatches to the handler; the handler itself is reached from boxed code only.)
# One instruction in typed code.  `in` is the stack state before it.  Returns a dict: flow (fall jump cond term dead),
# out (stack state afterwards), code, tgt, stores ({var kind}...), ret (kind of a returned value), calls ({proc sig}...),
# stub (code for the post-call stub of a direct call).  Typed code never changes any state before it knows it will not fall
# back: the instructions that can fall back test first, then act.
proc stepT {key pc in} {
    global PI VK procNames translatable typedMode
    set ::stepPC $pc
    lassign [keysplit $key] P sig
    lassign $PI($P,ins,$pc) op a
    set d [llength $in]
    set dead [R dead {} "goto D$pc;"]
    if {!$typedMode} { return $dead }
    set top [expr {$d - 1}]
    # int-vector slots (A:<var> a view of a local's vector, N a fresh vector) are understood by a few instructions only
    if {$op in {expandStart expandStkTop invokeExpanded expandDrop}} { return $dead }
    if {$op ni {pop listIndex listIndexImm listLength lsetList storeScalar1 storeScalar4 lappendScalar1 lappendScalar4 foreach_start foreach_step foreach_end invokeStk1 invokeStk4 verifyDict dictFirst dictExists dictIncrImm dictGet done}} {
        set np [lindex [effect $op $a] 0]
        for {set k [expr {$d - $np}]} {$k < $d} {incr k} { if {[kd [lindex $in $k]] in {A N M Q}} { return $dead } }
    }
    switch -- $op {
        nop - startCommand { return [R fall $in ""] }
        beginCatch4 { return [R fall $in ""] }
        endCatch { return [R fall $in "Tcl_ResetResult(interp);"] }
        tryCvtToNumeric {
            set e [lindex $in $top]
            switch [kd $e] {
                I - D - U { return [R fall $in ""] }
                B { return [R fall $in "if (TBC_UNLIKELY(tbc_trycvt(interp, &s$top))) goto [fl $key $in];"] }
                default {
                    # a string literal: only a literal that could be a number needs the conversion
                    set lit [lindex $PI($P,lits) [lt $e]]
                    if {![string is double -strict $lit] && ![string is wideinteger -strict $lit]} { return [R fall $in ""] }
                    set st [lreplace $in $top $top B]
                    return [R fall $st "[boxc $P $top $e] if (TBC_UNLIKELY(tbc_trycvt(interp, &s$top))) goto [fl $key $st];"]
                }
            }
        }

        push1 - push4 {
            set n [operand [lindex $a 0]]
            switch [lindex $PI($P,lcls) $n] {
                I { return [R fall [list {*}$in I:$n] "si$d = [c_int [lindex $PI($P,lits) $n]];"] }
                D { return [R fall [list {*}$in D:$n] "sd$d = [litdbl $P $n];"] }
                default { return [R fall [list {*}$in L:$n] ""] }
            }
        }
        pop {
            set e [lindex $in $top]
            return [R fall [lrange $in 0 end-1] [expr {[kd $e] eq "B" ? "Tcl_DecrRefCount(s$top);" : [kd $e] eq "N" ? "free(sv$top.p);" : [kd $e] eq "Q" ? "tbc_imap_free(&qv$top);" : ""}]]
        }
        dup {
            set e [lindex $in $top]
            switch [kd $e] {
                I { set c "si$d = si$top;" } D { set c "sd$d = sd$top;" } B { set c "s$d = s$top; Tcl_IncrRefCount(s$d);" }
                W { set c "sw$d = sw$top; si$d = si$top; sd$d = sd$top;" }
                default { set c "" }
            }
            return [R fall [list {*}$in $e] $c]
        }
        loadScalar1 - loadScalar4 {
            set v [operand [lindex $a 0]]
            switch [kap $key $v] {
                F { return [R fall [list {*}$in B] "\{ Tcl_Obj *o_ = tbc_tld(loc_, $v); if (TBC_UNLIKELY(!o_)) goto D$pc; s$d = o_; Tcl_IncrRefCount(s$d); \}"] }
                I { return [R fall [list {*}$in I] "si$d = i$v;"] }
                D { return [R fall [list {*}$in D] "sd$d = d$v;"] }
                W { return [R fall [list {*}$in W] "sw$d = wt$v; si$d = i$v; sd$d = d$v;"] }
                - { return [R fall [list {*}$in U] ""] }
                A { return [R fall [list {*}$in A:$v] ""] }
                M { return [R fall [list {*}$in M:$v] ""] }
                default {
                    return [R fall [list {*}$in B] "if (TBC_UNLIKELY(!l$v)) goto D$pc; s$d = l$v; Tcl_IncrRefCount(s$d);"]
                }
            }
        }
        storeScalar1 - storeScalar4 {
            set v [operand [lindex $a 0]]
            set e [lindex $in $top]; set k [kd $e]
            if {$k eq "U"} { return [R fall $in "" stores {}] }
            if {[kap $key $v] eq "F"} {
                # a variable in the frame: stored there when nothing (link target aside) stands in the way, else the boxed code does it
                set ok [fvalue $P $top $e "tbc_tset(loc_, $v, @V@)" "tbc_tseti(loc_, $v, @I@)"]
                if {$ok eq ""} { return $dead }
                lassign $ok pre call rel
                return [R fall $in "\{ $pre if (TBC_UNLIKELY(!($call))) \{$rel goto D$pc; \}$rel \}"]
            }
            if {$k eq "L" && [lindex $PI($P,lits) [lt $e]] eq "" && $v in $PI($P,vecok) && [kap $key $v] in {A -} && "A:$v" ni [lrange $in 0 [expr {$top-1}]]} {
                # `set l {}` of a list that is only built and read as a vector: an empty native vector (decision 36)
                return [R fall [lreplace $in $top $top A:$v] "free(av$v.p); av$v.p = NULL; av$v.n = av$v.cap = 0;" stores [list [list $v A]]]
            }
            if {$k eq "L" && [lindex $PI($P,lits) [lt $e]] eq "" && $v in $PI($P,mapok) && [kap $key $v] in {M -} && "M:$v" ni [lrange $in 0 [expr {$top-1}]]} {
                # `set d {}` of a dict that is counted in as a native map (decision 39): an empty map
                return [R fall [lreplace $in $top $top M:$v] "tbc_imap_free(&mv$v); if (TBC_UNLIKELY(!tbc_imap_init(&mv$v))) goto D$pc;" stores [list [list $v M]]]
            }
            if {$k in {A N M Q}} {
                set kv [kap $key $v]
                set fam [expr {$k in {A N} ? "A" : "M"}]
                if {$kv in [list $fam -]} {
                    if {$k in {N Q}} {
                        if {"$fam:$v" in [lrange $in 0 [expr {$top-1}]]} { return [R dead {} "goto D$pc;" stores [list [list $v B]]] }
                        set c [expr {$fam eq "A" ? "free(av$v.p); av$v = sv$top;" : "tbc_imap_free(&mv$v); mv$v = qv$top;"}]
                        return [R fall [lreplace $in $top $top $fam:$v] $c stores [list [list $v $fam]]]
                    } elseif {[lt $e] == $v} {
                        return [R fall $in "" stores [list [list $v $fam]]]
                    }
                }
                if {$kv ne "B"} { return [R dead {} "goto D$pc;" stores [list [list $v B]]] }
            }
            set sk [expr {$k eq "L" || $k in {A N M Q} ? "B" : $k}]
            if {$k eq "B" && [specStore $P $pc $v]} {
                if {[kap $key $v] eq "W"} {
                    return [R fall $in "if (TBC_UNLIKELY(!tbc_wload_canon(s$top, &wt$v, &i$v, &d$v))) goto D$pc;" stores [list [list $v S]]]
                }
                if {[kap $key $v] eq "I"} {
                    # (the value is checked: anything but an integer is stored by the boxed code, which is what the hand-over does)
                    return [R fall $in "if (TBC_UNLIKELY(!tbc_arg_int(s$top, &i$v))) goto D$pc;[expr {$v in [flaggedOf $P] ? " g$v = 1;" : ""}]" stores [list [list $v S]]]
                }
                set sk S
            }
            switch [kap $key $v] {
                W {
                    switch $k {
                        I { set c "wt$v = 0; i$v = si$top;" }
                        D { set c "wt$v = 1; d$v = sd$top;" }
                        W { set c "wt$v = sw$top; i$v = si$top; d$v = sd$top;" }
                        default { return [R dead {} "goto D$pc;" stores [list [list $v $sk]]] }
                    }
                }
                I { set c "i$v = si$top;[expr {$v in [flaggedOf $P] ? " g$v = 1;" : ""}]" }
                D { set c "d$v = sd$top;[expr {$v in [flaggedOf $P] ? " g$v = 1;" : ""}]" }
                default {
                    if {$k eq "B"} {
                        set c "Tcl_IncrRefCount(s$top); if (l$v) Tcl_DecrRefCount(l$v); l$v = s$top;"
                    } else {
                        set c "\{ Tcl_Obj *n_ = [boxe $P $top $e]; if (l$v) Tcl_DecrRefCount(l$v); l$v = n_; \}"
                    }
                }
            }
            return [R fall $in $c stores [list [list $v $sk]]]
        }
        incrScalar1Imm {
            set v [operand [lindex $a 0]]; set imm [lindex $a 1]
            if {[kap $key $v] eq "F"} {
                return [R fall [list {*}$in I] "\{ int64_t w_; if (TBC_UNLIKELY(!tbc_tincr(loc_, $v, INT64_C($imm), &w_))) goto D$pc; si$d = w_; \}"]
            }
            if {[kap $key $v] eq "B"} {
                return [R fall [list {*}$in I] "\{ int64_t w_; if (TBC_UNLIKELY(!l$v || !tbc_incr_local(&l$v, INT64_C($imm), &w_))) goto D$pc; si$d = w_; \}" stores [list [list $v B]]]
            }
            if {[kap $key $v] eq "W"} {
                return [R fall [list {*}$in I] "\{ int64_t t_; if (TBC_UNLIKELY(wt$v || __builtin_add_overflow(i$v, INT64_C($imm), &t_))) goto D$pc; i$v = t_; si$d = t_; \}" stores [list [list $v W]]]
            }
            if {[kap $key $v] ni {I -}} { return [R dead {} "goto D$pc;" stores [list [list $v I]]] }
            return [R fall [list {*}$in I] "\{ int64_t t_; if (TBC_UNLIKELY(__builtin_add_overflow(i$v, INT64_C($imm), &t_))) goto D$pc; i$v = t_; si$d = t_; \}" stores [list [list $v I]]]
        }
        incrScalar1 {
            set v [operand [lindex $a 0]]
            set e [lindex $in $top]
            if {[kap $key $v] eq "F"} {
                if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
                lassign [operandOf $P $pc $top $e] ce ge xe
                if {$ce ne "I"} { return $dead }
                set rel ""; if {[kd $e] eq "B"} { set rel " Tcl_DecrRefCount(s$top);" }
                return [R fall [lreplace $in $top $top I] "\{ int64_t w_; $ge if (TBC_UNLIKELY(!tbc_tincr(loc_, $v, $xe, &w_))) goto D$pc;$rel si$top = w_; \}"]
            }
            if {[kap $key $v] eq "B" && [kd $e] in {I B}} {
                lassign [operandOf $P $pc $top $e] ce ge xe
                set rel ""; if {[kd $e] eq "B"} { set rel " Tcl_DecrRefCount(s$top);" }
                return [R fall [lreplace $in $top $top I] "\{ int64_t w_; $ge if (TBC_UNLIKELY(!l$v || !tbc_incr_local(&l$v, $xe, &w_))) goto D$pc;$rel si$top = w_; \}" stores [list [list $v B]]]
            }
            if {[kap $key $v] eq "W"} {
                if {[kd $e] ne "I"} { return [R dead {} "goto D$pc;" stores [list [list $v W]]] }
                return [R fall [lreplace $in $top $top I] "\{ int64_t t_; if (TBC_UNLIKELY(wt$v || __builtin_add_overflow(i$v, si$top, &t_))) goto D$pc; i$v = t_; si$top = t_; \}" stores [list [list $v W]]]
            }
            if {[kap $key $v] ni {I -} || [kd $e] ni {I U B}} { return [R dead {} "goto D$pc;" stores [list [list $v I]]] }
            if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] "" stores [list [list $v I]]] }
            # (an increment held as an object is used as a machine integer if it is one; anything else is left to the boxed code)
            lassign [operandOf $P $pc $top $e] ce ge xe
            set rel ""; if {[kd $e] eq "B"} { set rel " Tcl_DecrRefCount(s$top);" }
            return [R fall [lreplace $in $top $top I] "\{ int64_t t_; $ge if (TBC_UNLIKELY(__builtin_add_overflow(i$v, $xe, &t_))) goto D$pc; i$v = t_;$rel si$top = t_; \}" stores [list [list $v I]]]
        }

        add - sub - mult - div - mod - lt - le - gt - ge - eq - neq { return [stepArith $P $pc $op $in $d] }
        bitand - bitor - bitxor - lshift - rshift { return [stepBit $P $pc $op $in $d] }
        uminus - bitnot - not - uplus { return [stepUnary $P $pc $op $in $d] }

        jump1 - jump4 { return [R jump $in "" tgt [operand [lindex $a 0]]] }
        jumpTrue1 - jumpTrue4 - jumpFalse1 - jumpFalse4 {
            set tgt [operand [lindex $a 0]]
            set e [lindex $in $top]; set neg [expr {[string match jumpFalse* $op] ? "!" : ""}]
            set out [lrange $in 0 end-1]
            switch [kd $e] {
                I { set c "if (${neg}(si$top != 0)) \{ @TAKEN@ goto T$tgt; \}" }
                D { set c "if (${neg}(sd$top != 0.0)) \{ @TAKEN@ goto T$tgt; \}" }
                W { set c "\{ int t_; if (sw$top) \{ if (TBC_UNLIKELY(sd$top != sd$top)) goto D$pc; t_ = (sd$top != 0.0); \} else t_ = (si$top != 0); if (${neg}t_) \{ @TAKEN@ goto T$tgt; \} \}" }
                U { set c "" }
                B {
                    set c "\{ int t_; if (TBC_UNLIKELY(tbc_truth(interp, s$top, &t_) != TCL_OK)) goto [fl $key $in]; Tcl_DecrRefCount(s$top); if (${neg}t_) \{ @TAKEN@ goto T$tgt; \} \}"
                }
                default { return $dead }
            }
            return [R cond $out $c tgt $tgt]
        }
        done {
            set e [lindex $in $top]
            set rel ""
            for {set k 0} {$k < $top} {incr k} { if {[kd [lindex $in $k]] eq "B"} { append rel " Tcl_DecrRefCount(s$k);" } }
            if {[kd $e] in {A M N Q}} {
                # returning a vector or map: it becomes a list or dict (a copy: the local is released on the way out)
                return [R term {} "rv = [boxe $P $top $e];$rel rc = TCL_OK; goto ret;" ret B]
            }
            set k [kd $e]; set rk $VK($key,ret)
            if {$rk eq "W"} { set rk B }
            if {$k eq "U"} { return [R term {} "" ret U] }
            set sk [expr {$k eq "L" || $k eq "W" ? "B" : $k}]
            if {$rk in {- U}} { set rk $sk }
            if {$rk eq "B"} {
                if {$k eq "B"} { set c "rv = s$top;" } else { set c "[boxc $P $top $e] rv = s$top;" }
            } else {
                set c "rv = [svar $sk $top];"
                if {$sk ne $rk} { set c "[boxc $P $top $e] rv = s$top;" }
            }
            return [R term {} "$c$rel rc = TCL_OK; goto ret;" ret $sk]
        }

        invokeStk1 - invokeStk4 { return [stepInvoke $key $pc $in $d [lindex $a 0]] }

        strcat {
            set n [lindex $a 0]; set q [expr {$d - $n}]
            set parts ""; set rel ""
            # a key that a native array operation (kind R) is about to use is built in a buffer of the slot, as text, without an object (kind K)
            set kc [keyConsumer $P $pc $q]
            # `$i,$j` of two integers: the key is held as the two integers (kind K:2); the text is only made if something needs it (see keyArgs, boxe)
            if {$kc ne "" && [allR $key [lindex $kc 1]] && $n == 3} {
                set e1 [lindex $in $q]; set e2 [lindex $in [expr {$q+1}]]; set e3 [lindex $in [expr {$q+2}]]
                if {[kd $e2] eq "L" && [lindex $PI($P,lits) [lt $e2]] eq "," && [keyInt $P $q $e1] ne "" && [keyInt $P [expr {$q+2}] $e3] ne ""} {
                    return [R fall [list {*}[lrange $in 0 [expr {$q-1}]] K:2] "ka$q = [keyInt $P $q $e1]; kj$q = [keyInt $P [expr {$q+2}] $e3];"]
                }
            }
            if {$kc ne "" && [allR $key [lindex $kc 1]]} {
                set kcode ""; set ok 1; set maxl 0
                for {set k $q} {$k < $d && $ok} {incr k} {
                    set e [lindex $in $k]
                    switch [kd $e] {
                        I { if {[lt $e] ne ""} { set lit [lindex $PI($P,lits) [lt $e]]; append kcode " memcpy(kb$q + o_, [cstring $lit], [cbytes $lit]); o_ += [cbytes $lit];"; incr maxl [cbytes $lit] } else { append kcode " o_ += tbc_fmt_i64(kb$q + o_, si$k);"; incr maxl 20 } }
                        L { set lit [lindex $PI($P,lits) [lt $e]]; append kcode " memcpy(kb$q + o_, [cstring $lit], [cbytes $lit]); o_ += [cbytes $lit];"; incr maxl [cbytes $lit] }
                        default { set ok 0 }
                    }
                }
                if {$ok && $maxl <= 100} {
                    return [R fall [list {*}[lrange $in 0 [expr {$q-1}]] K] "\{ int o_ = 0;$kcode kl$q = o_; \}"]
                }
            }
            for {set k $q} {$k < $d} {incr k} {
                set e [lindex $in $k]
                switch [kd $e] {
                    I { if {[lt $e] ne ""} { append parts " tbc_cat_bytes(&c_, [cstring [lindex $PI($P,lits) [lt $e]]], [cbytes [lindex $PI($P,lits) [lt $e]]]);" } else { append parts " tbc_cat_i(&c_, si$k);" } }
                    L { append parts " tbc_cat_bytes(&c_, [cstring [lindex $PI($P,lits) [lt $e]]], [cbytes [lindex $PI($P,lits) [lt $e]]]);" }
                    B { append parts " tbc_cat_o(&c_, s$k);"; append rel " Tcl_DecrRefCount(s$k);" }
                    D { append parts " \{ Tcl_Obj *t_ = tbc_newdbl(sd$k); tbc_cat_o(&c_, t_); Tcl_DecrRefCount(t_); \}" }
                    default { return [R fall [list {*}[lrange $in 0 $q-1] U] ""] }
                }
            }
            return [R fall [list {*}[lrange $in 0 [expr {$q-1}]] B] "\{ tbc_cat_t c_; tbc_cat_init(&c_);$parts$rel s$q = tbc_cat_done(&c_); \}"]
        }
        strlen {
            set e [lindex $in $top]
            set pre [boxc $P $top $e]
            if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
            return [R fall [lreplace $in $top $top I] "$pre si$top = Tcl_GetCharLength(s$top); Tcl_DecrRefCount(s$top);"]
        }
        reverse { return [stepReverse $P $in $d [lindex $a 0]] }

        appendScalar1 - appendScalar4 {
            set v [operand [lindex $a 0]]
            set e [lindex $in $top]; set k [kd $e]
            if {[kap $key $v] ni {B -}} { return [R dead {} "goto D$pc;" stores [list [list $v B]]] }
            switch $k {
                I { if {[lt $e] ne ""} { set c "tbc_append_bytes(&l$v, [cstring [lindex $PI($P,lits) [lt $e]]], [cbytes [lindex $PI($P,lits) [lt $e]]]);" } else { set c "tbc_append_i(&l$v, si$top);" } }
                L { set c "tbc_append_bytes(&l$v, [cstring [lindex $PI($P,lits) [lt $e]]], [cbytes [lindex $PI($P,lits) [lt $e]]]);" }
                B { set c "(void) tbc_append(&l$v, s$top); Tcl_DecrRefCount(s$top);" }
                D { set c "\{ Tcl_Obj *t_ = tbc_newdbl(sd$top); (void) tbc_append(&l$v, t_); Tcl_DecrRefCount(t_); \}" }
                default { return [R fall [lreplace $in $top $top U] "" stores [list [list $v B]]] }
            }
            return [R fall [lreplace $in $top $top B] "$c s$top = l$v; Tcl_IncrRefCount(s$top);" stores [list [list $v B]]]
        }
        listIndex {
            set pl [expr {$d-2}]; set pi [expr {$d-1}]
            set el [lindex $in $pl]; set ei [lindex $in $pi]
            if {[kd $el] eq "U" || [kd $ei] eq "U"} { return [R fall [list {*}[lrange $in 0 $pl-1] U] ""] }
            if {[kd $el] eq "A" && [kd $ei] eq "I"} {
                set av [lt $el]
                return [R fall [list {*}[lrange $in 0 [expr {$pl-1}]] I] "\{ int64_t i_ = si$pi; if (TBC_UNLIKELY((uint64_t) i_ >= (uint64_t) av$av.n)) goto D$pc; si$pl = av$av.p\[i_\]; \}"]
            }
            if {[kd $el] ne "B"} { return $dead }
            set fl [fl $key $in]
            if {[kd $ei] eq "I"} {
                set c "\{ Tcl_Obj *r_ = tbc_lindex_i(interp, s$pl, si$pi); if (!r_) goto $fl; Tcl_DecrRefCount(s$pl); s$pl = r_; \}"
                return [R fall [list {*}[lrange $in 0 [expr {$pl-1}]] B] $c]
            }
            set st [lreplace $in $pi $pi B]
            set c "[boxc $P $pi $ei] \{ Tcl_Obj *r_ = tbc_lindex(interp, s$pl, s$pi); if (!r_) goto [fl $key $st]; Tcl_DecrRefCount(s$pi); Tcl_DecrRefCount(s$pl); s$pl = r_; \}"
            return [R fall [list {*}[lrange $in 0 [expr {$pl-1}]] B] $c]
        }
        listIndexImm {
            set pl $top; set el [lindex $in $pl]
            regexp {^\.(-?\d+|end)(?:-(\d+))?$} [lindex $a 0] -> ix kk
            if {[string match -* $ix]} { return $dead }
            if {$ix eq "end"} { set idx "(int64_t) av_n_ - 1 - [expr {$kk eq "" ? 0 : $kk}]" } else { set idx $ix }
            if {[kd $el] eq "U"} { return [R fall [lreplace $in $pl $pl U] ""] }
            if {[kd $el] eq "A"} {
                set av [lt $el]
                set idx [string map [list av_n_ av$av.n] $idx]
                return [R fall [lreplace $in $pl $pl I] "\{ int64_t i_ = $idx; if (TBC_UNLIKELY((uint64_t) i_ >= (uint64_t) av$av.n)) goto D$pc; si$pl = av$av.p\[i_\]; \}"]
            }
            if {[kd $el] ne "B"} { return $dead }
            set call [expr {$ix eq "end" ? "tbc_lindex_end(interp, s$pl, [expr {$kk eq "" ? 0 : $kk}])" : "tbc_lindex_i(interp, s$pl, $ix)"}]
            return [R fall [lreplace $in $pl $pl B] "\{ Tcl_Obj *r_ = $call; if (!r_) goto [fl $key $in]; Tcl_DecrRefCount(s$pl); s$pl = r_; \}"]
        }
        listLength {
            set el [lindex $in $top]
            if {[kd $el] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
            if {[kd $el] eq "A"} { return [R fall [lreplace $in $top $top I] "si$top = av[lt $el].n;"] }
            # (a number is one list element; a literal string is boxed first)
            if {[kd $el] in {I D}} { return [R fall [lreplace $in $top $top I] "si$top = 1;"] }
            if {[kd $el] ni {B L}} { return $dead }
            set st [lreplace $in $top $top B]
            return [R fall [lreplace $in $top $top I] "[boxc $P $top $el] \{ int n_; if (Tcl_ListObjLength(interp, s$top, &n_) != TCL_OK) goto [fl $key $st]; Tcl_DecrRefCount(s$top); si$top = n_; \}"]
        }
        list {
            set n [lindex $a 0]; set q [expr {$d - $n}]
            if {"U" in [lrange $in $q end]} { return [R fall [list {*}[lrange $in 0 [expr {$q-1}]] U] ""] }
            set pre ""; set slots {}; set rel ""
            for {set k $q} {$k < $d} {incr k} { append pre [boxc $P $k [lindex $in $k]] " "; lappend slots s$k; append rel " Tcl_DecrRefCount(s$k);" }
            return [R fall [list {*}[lrange $in 0 [expr {$q-1}]] B] "$pre\{ Tcl_Obj *ov_\[\] = { [join $slots {, }] }; Tcl_Obj *r_ = Tcl_NewListObj($n, ov_); Tcl_IncrRefCount(r_);$rel s$q = r_; \}"]
        }
        lsetList {
            # stack: index, value, list
            set pi [expr {$d-3}]; set pv [expr {$d-2}]; set pl [expr {$d-1}]
            set ei [lindex $in $pi]; set ev [lindex $in $pv]; set el [lindex $in $pl]
            if {"U" in [list [kd $ei] [kd $ev] [kd $el]]} { return [R fall [list {*}[lrange $in 0 $pi-1] U] ""] }
            if {[kd $el] eq "A" && [kd $ei] eq "I" && [kd $ev] eq "I"} {
                set av [lt $el]
                # the vector is changed in place: no other view of it may be on the stack
                if {"A:$av" in [lrange $in 0 [expr {$pi-1}]]} { return $dead }
                return [R fall [list {*}[lrange $in 0 [expr {$pi-1}]] $el] "\{ int64_t i_ = si$pi; if (TBC_UNLIKELY((uint64_t) i_ >= (uint64_t) av$av.n)) goto D$pc; av$av.p\[i_\] = si$pv; \}"]
            }
            if {[kd $el] ne "B"} { return $dead }
            set st [list {*}[lrange $in 0 [expr {$pi-1}]] [expr {[kd $ei] eq "I" ? $ei : "B"}] B B]
            set pre "[boxc $P $pv $ev]"
            if {[kd $ei] ne "I"} { append pre " [boxc $P $pi $ei]" }
            set fl [fl $key [list {*}[lrange $in 0 [expr {$pi-1}]] [expr {[kd $ei] eq "I" ? $ei : "B"}] B B]]
            if {[kd $ei] eq "I"} {
                set call "tbc_lset_i(interp, lst_, si$pi, s$pv)"; set reli ""
            } else {
                set call "TclLsetList(interp, lst_, s$pi, s$pv)"; set reli " Tcl_DecrRefCount(s$pi);"
            }
            set c "$pre \{ Tcl_Obj *lst_ = s$pl, *r_; Tcl_DecrRefCount(lst_); r_ = $call; if (!r_) \{ Tcl_IncrRefCount(lst_); goto $fl; \} Tcl_DecrRefCount(s$pv);$reli s$pi = r_; \}"
            return [R fall [list {*}[lrange $in 0 [expr {$pi-1}]] B] $c]
        }
        dictGet {
            if {[lindex $a 0] != 1} { return $dead }
            set pd [expr {$d-2}]; set pk [expr {$d-1}]
            set ed [lindex $in $pd]; set ek [lindex $in $pk]
            if {"U" in [list [kd $ed] [kd $ek]]} { return [R fall [list {*}[lrange $in 0 $pd-1] U] ""] }
            if {[kd $ed] eq "M"} {
                if {[mapKeyI $pk $ek] ne ""} { return [R fall [list {*}[lrange $in 0 [expr {$pd-1}]] I] "\{ int64_t r_; if (TBC_UNLIKELY(!tbc_imap_get_i(&mv[lt $ed], [mapKeyI $pk $ek], &r_))) goto D$pc; si$pd = r_; \}"] }
                set kb [keyArgs $P $pk $ek]
                if {$kb eq ""} { return $dead }
                lassign $kb kpre kptr klen krel kobj
                return [R fall [list {*}[lrange $in 0 [expr {$pd-1}]] I] "\{ int64_t r_; $kpre if (TBC_UNLIKELY(!tbc_imap_get(&mv[lt $ed], $kptr, $klen, &r_))) goto D$pc;$krel si$pd = r_; \}"]
            }
            if {[kd $ed] ne "B" || [kd $ek] in {A N M Q}} { return $dead }
            set st [list {*}[lrange $in 0 [expr {$pd-1}]] B B]
            set pre [boxc $P $pk $ek]
            return [R fall [list {*}[lrange $in 0 [expr {$pd-1}]] B] "$pre \{ Tcl_Obj *v_ = NULL; if (Tcl_DictObjGet(interp, s$pd, s$pk, &v_) != TCL_OK) goto [fl $key $st]; if (!v_) \{ tbc_dict_nokey(interp, s$pk); goto [fl $key $st]; \} Tcl_IncrRefCount(v_); Tcl_DecrRefCount(s$pk); Tcl_DecrRefCount(s$pd); s$pd = v_; \}"]
        }
        lappendScalar1 - lappendScalar4 {
            set v [operand [lindex $a 0]]
            set e [lindex $in $top]
            if {[kd $e] in {A N M Q}} { return $dead }
            if {$v in $PI($P,vecok) && [kap $key $v] in {A -}} {
                if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] "" stores [list [list $v A]]] }
                if {[kd $e] eq "I" && [evKind $P $e] eq "I" && "A:$v" ni [lrange $in 0 [expr {$top-1}]]} {
                    # an integer appended to a native vector (the result of lappend is the list: a view of the vector)
                    set val [expr {[lt $e] eq "" ? "si$top" : [c_int [lindex $PI($P,lits) [lt $e]]]}]
                    return [R fall [lreplace $in $top $top A:$v] "if (TBC_UNLIKELY(!tbc_ivec_push(&av$v, $val))) goto D$pc;" stores [list [list $v A]]]
                }
                return [R dead {} "goto D$pc;" stores [list [list $v B]]]
            }
            if {[kap $key $v] ni {B -}} { return [R dead {} "goto D$pc;" stores [list [list $v B]]] }
            if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] "" stores [list [list $v B]]] }
            set st [lreplace $in $top $top B]
            return [R fall $st "[boxc $P $top $e] if (tbc_lappend(interp, &l$v, s$top)) goto [fl $key $st]; Tcl_DecrRefCount(s$top); s$top = l$v; Tcl_IncrRefCount(s$top);" stores [list [list $v B]]]
        }
        dictExists {
            if {[lindex $a 0] != 1} { return $dead }
            set pd [expr {$d-2}]; set pk [expr {$d-1}]
            set ed [lindex $in $pd]; set ek [lindex $in $pk]
            if {"U" in [list [kd $ed] [kd $ek]]} { return [R fall [list {*}[lrange $in 0 $pd-1] U] ""] }
            if {[kd $ed] eq "M"} {
                if {[mapKeyI $pk $ek] ne ""} { return [R fall [list {*}[lrange $in 0 [expr {$pd-1}]] I] "si$pd = tbc_imap_has_i(&mv[lt $ed], [mapKeyI $pk $ek]);"] }
                set kb [keyArgs $P $pk $ek]
                if {$kb eq ""} { return $dead }
                lassign $kb kpre kptr klen krel kobj
                return [R fall [list {*}[lrange $in 0 [expr {$pd-1}]] I] "\{ $kpre si$pd = tbc_imap_has(&mv[lt $ed], $kptr, $klen);$krel \}"]
            }
            if {[kd $ed] ne "B" || [kd $ek] in {A N M Q}} { return $dead }
            set pre [boxc $P $pk $ek]
            return [R fall [list {*}[lrange $in 0 [expr {$pd-1}]] I] "$pre si$pd = tbc_dict_exists(s$pd, s$pk); Tcl_DecrRefCount(s$pk); Tcl_DecrRefCount(s$pd);"]
        }
        dictIncrImm {
            set imm [lindex $a 0]; set v [operand [lindex $a 1]]
            set e [lindex $in $top]
            if {[kd $e] in {A N M Q}} { return $dead }
            if {[kap $key $v] eq "M"} {
                if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
                if {[mapKeyI $top $e] ne ""} { return [R fall [lreplace $in $top $top M:$v] "if (TBC_UNLIKELY(tbc_imap_incr_i(&mv$v, [mapKeyI $top $e], INT64_C($imm)))) goto D$pc;"] }
                set kb [keyArgs $P $top $e]
                if {$kb eq ""} { return $dead }
                lassign $kb kpre kptr klen krel kobj
                return [R fall [lreplace $in $top $top M:$v] "\{ $kpre if (TBC_UNLIKELY(tbc_imap_incr(&mv$v, $kptr, $klen, $kobj, INT64_C($imm)))) goto D$pc;$krel \}"]
            }
            if {[kap $key $v] eq "-"} { return [R fall [lreplace $in $top $top U] ""] }
            if {[kap $key $v] ne "B"} { return [R dead {} "goto D$pc;" stores [list [list $v B]]] }
            if {[kd $e] eq "U"} { return [R fall $in "" stores [list [list $v B]]] }
            set st [lreplace $in $top $top B]
            set c "[boxc $P $top $e] if (tbc_dict_incr2(interp, &l$v, s$top, INT64_C($imm))) goto [fl $key $st]; Tcl_DecrRefCount(s$top); s$top = l$v; Tcl_IncrRefCount(s$top);"
            return [R fall $st $c stores [list [list $v B]]]
        }
        verifyDict {
            set e [lindex $in $top]
            if {[kd $e] eq "U"} { return [R fall [lrange $in 0 end-1] ""] }
            # `dict create` with no arguments is the literal empty dict, duplicated and checked: the copy that is kept becomes a fresh map
            if {[kd $e] eq "L" && $top >= 1 && [lindex $in [expr {$top-1}]] eq $e && [lindex $PI($P,lits) [lt $e]] eq ""} {
                set lo [expr {$top-1}]
                return [R fall [list {*}[lrange $in 0 [expr {$lo-1}]] Q] "if (TBC_UNLIKELY(!tbc_imap_init(&qv$lo))) goto D$pc;"]
            }
            set st [lreplace $in $top $top B]
            set c "[boxc $P $top $e] \{ int n_; if (Tcl_DictObjSize(interp, s$top, &n_) != TCL_OK) goto [fl $key $st]; Tcl_DecrRefCount(s$top); \}"
            return [R fall [lrange $in 0 end-1] $c]
        }
        yield - yieldToInvoke {
            # (boxed code does it; the state after it is where the resumed coroutine goes on in typed code)
            set below [lrange $in 0 end-1]
            set seed {}
            foreach e $below {
                switch [kd $e] {
                    I - D - B { lappend seed [kd $e] }
                    L { lappend seed B }
                    T { lappend seed $e }
                    default { set seed {}; break }
                }
            }
            if {[llength $seed] != [llength $below]} { return $dead }
            return [R dead {} "goto D$pc;" seed [list $PI($P,next,$pc) [concat $seed B]]]
        }
        dictFirst - dictNext - unsetScalar { return $dead }
        listIn - listNotIn - strindex - strfind - strrfind - strrange - strreplace - strcaseUpper - strcaseLower - strcaseTitle - strtrim - strtrimLeft -
        strtrimRight - strmatch - regexp - strrangeImm - listRangeImm - lindexMulti {
            if {$op in {strfind strrfind strindex strrange strrangeImm strmatch regexp}} {
                set r [stepStrFast $key $pc $in $d $op $a]
                if {$r ne ""} { return $r }
            }
            return [stepCmdOp $key $pc $in $d $op $a]
        }
        jumpTable {
            lassign $a n tgts map
            set e [lindex $in $top]
            set below [lrange $in 0 end-1]
            set kind [kd $e]
            if {$kind eq "U"} { return [R fall $below ""] }
            if {$kind in {A N M Q T}} { return $dead }
            if {$kind eq "I"} {
                # (the key's text is the integer's canonical form: only keys written like that can match it)
                set cases ""
                foreach {k off} $map {
                    if {[regexp {^-?(0|[1-9][0-9]*)$} $k] && $k ne "-0" && $k >= -9223372036854775808 && $k <= 9223372036854775807} {
                        set u [expr {$pc + $off}]
                        append cases " case INT64_C($k): @E${u}@ goto T$u;"
                    }
                }
                return [R multi $below "switch (si$top) \{$cases default: break; \}" tgts $tgts]
            }
            set c "[boxc $P $top $e] \{ int kl_; const char *k_ = Tcl_GetStringFromObj(s$top, &kl_);"
            foreach {k off} $map {
                set u [expr {$pc + $off}]
                append c " if (kl_ == [cbytes $k] && !memcmp(k_, [cstring $k], kl_)) \{ Tcl_DecrRefCount(s$top); @E${u}@ goto T$u; \}"
            }
            append c " Tcl_DecrRefCount(s$top); \}"
            return [R multi $below $c tgts $tgts]
        }
        foreach_start { return [stepForeachStart $key $pc $in $d $a] }
        foreach_step { return [stepForeachStep $key $pc $in $d $a] }
        foreach_end {
            lassign $a n nl
            set rel ""
            for {set k [expr {$d - 1}]} {$k >= $d - $nl - 2} {incr k -1} { if {[kd [lindex $in $k]] eq "B"} { append rel "Tcl_DecrRefCount(s$k); " } elseif {[kd [lindex $in $k]] eq "N"} { append rel "free(sv$k.p); sv$k.p = NULL; " } }
            return [R fall [lrange $in 0 [expr {$d - $nl - 3}]] $rel]
        }
        streq - strneq - strcmp { return [stepStrCmp $key $pc $in $d $op] }
        strmap { return [stepStrMap $key $pc $in $d] }
        listConcat { return [stepListConcat $key $pc $in $d] }
        expon { return [stepBoxedBin $key $pc $in $d POW] }
        concatStk { return [stepConcat $key $pc $in $d [lindex $a 0]] }
        over {
            set src [expr {$d - 1 - [operand [lindex $a 0]]}]
            set e [lindex $in $src]
            switch [kd $e] {
                I { return [R fall [list {*}$in $e] "si$d = si$src;"] }
                D { return [R fall [list {*}$in $e] "sd$d = sd$src;"] }
                B { return [R fall [list {*}$in B] "s$d = s$src; Tcl_IncrRefCount(s$d);"] }
                L { return [R fall [list {*}$in $e] ""] }
                U { return [R fall [list {*}$in U] ""] }
            }
            return $dead
        }
        loadArray1 - loadArray4 {
            set v [operand [lindex $a 0]]
            if {[kap $key $v] eq "R"} {
                set e [lindex $in $top]
                if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
                set ek [ekap $key $v]
                if {$ek eq "-"} { return [R fall [lreplace $in $top $top U] ""] }
                set rk [rkey $P $top $e]
                if {$rk eq ""} { return $dead }
                lassign $rk suf kargs kpre krel
                switch $ek {
                    I { return [R fall [lreplace $in $top $top I] "\{ $kpre int64_t w_; if (TBC_UNLIKELY(!tbc_rgetw${suf}(&rv$v, $kargs, &w_))) goto D$pc;$krel si$top = w_; \}"] }
                    D { return [R fall [lreplace $in $top $top D] "\{ $kpre double x_; if (TBC_UNLIKELY(!tbc_rgetd${suf}(&rv$v, $kargs, &x_))) goto D$pc;$krel sd$top = x_; \}"] }
                    W { return [R fall [lreplace $in $top $top W] "\{ $kpre int tg_; int64_t iv_; double dv_; if (TBC_UNLIKELY(!tbc_rgetn${suf}(&rv$v, $kargs, &tg_, &iv_, &dv_))) goto D$pc;$krel sw$top = tg_; si$top = iv_; sd$top = dv_; \}"] }
                }
                return [R fall [lreplace $in $top $top B] "\{ $kpre Tcl_Obj *o_ = tbc_rget${suf}(&rv$v, $kargs); if (TBC_UNLIKELY(!o_)) goto D$pc; Tcl_IncrRefCount(o_);$krel s$top = o_; \}"]
            }
            if {[kap $key $v] ne "F"} { return $dead }
            set e [lindex $in $top]
            if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
            set k [akey $P $top $e]
            if {$k eq ""} { return $dead }
            lassign $k pre kx fake rel
            return [R fall [lreplace $in $top $top B] "\{ $pre Tcl_Obj *o_ = tbc_tald(loc_, $v, $kx); if (TBC_UNLIKELY(!o_)) goto D$pc; Tcl_IncrRefCount(o_);$rel s$top = o_; \}"]
        }
        storeArray1 - storeArray4 {
            set v [operand [lindex $a 0]]
            if {[kap $key $v] eq "R"} {
                set pk [expr {$d-2}]; set pv [expr {$d-1}]
                set ek [lindex $in $pk]; set ev [lindex $in $pv]
                set base [lrange $in 0 [expr {$pk-1}]]
                if {"U" in [list [kd $ek] [kd $ev]]} { return [R fall [list {*}$base U] ""] }
                set rk [rkey $P $pk $ek]
                if {$rk eq ""} { return $dead }
                lassign $rk suf kargs kpre krel
                set ok [rvalue $P $pv $ev $v $suf $kargs]
                if {$ok eq ""} { return $dead }
                lassign $ok vpre call vrel
                switch [kd $ev] {
                    I { set mv "si$pk = si$pv;" } D { set mv "sd$pk = sd$pv;" } B { set mv "s$pk = s$pv;" } W { set mv "sw$pk = sw$pv; si$pk = si$pv; sd$pk = sd$pv;" } default { set mv "" }
                }
                return [R fall [list {*}$base $ev] "\{ $kpre $vpre if (TBC_UNLIKELY(!($call))) \{$vrel goto D$pc; \}$vrel$krel $mv \}" estores [list [list $v [evKind $P $ev]]]]
            }
            if {[kap $key $v] ne "F"} { return $dead }
            set pk [expr {$d-2}]; set pv [expr {$d-1}]
            set ek [lindex $in $pk]; set ev [lindex $in $pv]
            set base [lrange $in 0 [expr {$pk-1}]]
            if {"U" in [list [kd $ek] [kd $ev]]} { return [R fall [list {*}$base U] ""] }
            set k [akey $P $pk $ek]
            if {$k eq ""} { return $dead }
            lassign $k pre kx fake rel
            set ok [fvalue $P $pv $ev "tbc_tast(interp, loc_, $v, $kx, $fake, @V@)" "tbc_tasti(interp, loc_, $v, $kx, $fake, @I@)"]
            if {$ok eq ""} { return $dead }
            lassign $ok vpre call vrel
            switch [kd $ev] {
                I { set mv "si$pk = si$pv;" } D { set mv "sd$pk = sd$pv;" } B { set mv "s$pk = s$pv;" } default { set mv "" }
            }
            return [R fall [list {*}$base $ev] "\{ $pre $vpre if (TBC_UNLIKELY(!($call))) \{$vrel goto D$pc; \}$vrel$rel $mv \}"]
        }
        incrArray1Imm {
            set v [operand [lindex $a 0]]; set imm [lindex $a 1]
            if {[kap $key $v] eq "R"} {
                set e [lindex $in $top]
                if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
                set k2 [keyInt2 $P $top $e]
                if {$k2 ne ""} { lassign $k2 ka kj; return [R fall [lreplace $in $top $top I] "\{ int64_t w_; if (TBC_UNLIKELY(!tbc_rinc_k2(&rv$v, $ka, $kj, INT64_C($imm), &w_))) goto D$pc; si$top = w_; \}" estores [list [list $v I]]] }
                set kb [keyArgs $P $top $e]
                if {$kb eq ""} { return $dead }
                lassign $kb kpre kptr klen krel
                set ki [keyInt $P $top $e]
                if {$ki ne ""} { return [R fall [lreplace $in $top $top I] "\{ int64_t w_; if (TBC_UNLIKELY(!tbc_rinc_k(&rv$v, $ki, INT64_C($imm), &w_))) goto D$pc; si$top = w_; \}" estores [list [list $v I]]] }
                return [R fall [lreplace $in $top $top I] "\{ $kpre int64_t w_; if (TBC_UNLIKELY(!tbc_rinc(&rv$v, $kptr, $klen, INT64_C($imm), &w_))) goto D$pc;$krel si$top = w_; \}" estores [list [list $v I]]]
            }
            if {[kap $key $v] ne "F"} { return $dead }
            set e [lindex $in $top]
            if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
            set k [akey $P $top $e]
            if {$k eq ""} { return $dead }
            lassign $k pre kx fake rel
            return [R fall [lreplace $in $top $top I] "\{ $pre int64_t w_; if (TBC_UNLIKELY(!tbc_tainc(interp, loc_, $v, $kx, $fake, INT64_C($imm), &w_))) goto D$pc;$rel si$top = w_; \}"]
        }
        incrArray1 {
            set v [operand [lindex $a 0]]
            if {[kap $key $v] eq "R"} {
                set pk [expr {$d-2}]; set pi [expr {$d-1}]
                set ek [lindex $in $pk]; set ei [lindex $in $pi]
                set base [lrange $in 0 [expr {$pk-1}]]
                if {"U" in [list [kd $ek] [kd $ei]]} { return [R fall [list {*}$base U] ""] }
                set kb [keyArgs $P $pk $ek]
                lassign [operandOf $P $pc $pi $ei] ci gi xi
                if {$kb eq "" || $ci ne "I"} { return $dead }
                lassign $kb kpre kptr klen krel
                set irel ""; if {[kd $ei] eq "B"} { set irel " Tcl_DecrRefCount(s$pi);" }
                set k2 [keyInt2 $P $pk $ek]
                if {$k2 ne ""} { lassign $k2 ka kj; return [R fall [list {*}$base I] "\{ int64_t w_; $gi if (TBC_UNLIKELY(!tbc_rinc_k2(&rv$v, $ka, $kj, $xi, &w_))) goto D$pc;$irel si$pk = w_; \}" estores [list [list $v I]]] }
                set ki [keyInt $P $pk $ek]
                if {$ki ne ""} { return [R fall [list {*}$base I] "\{ int64_t w_; $gi if (TBC_UNLIKELY(!tbc_rinc_k(&rv$v, $ki, $xi, &w_))) goto D$pc;$irel si$pk = w_; \}" estores [list [list $v I]]] }
                return [R fall [list {*}$base I] "\{ $kpre int64_t w_; $gi if (TBC_UNLIKELY(!tbc_rinc(&rv$v, $kptr, $klen, $xi, &w_))) goto D$pc;$irel$krel si$pk = w_; \}" estores [list [list $v I]]]
            }
            if {[kap $key $v] ne "F"} { return $dead }
            set pk [expr {$d-2}]; set pi [expr {$d-1}]
            set ek [lindex $in $pk]; set ei [lindex $in $pi]
            set base [lrange $in 0 [expr {$pk-1}]]
            if {"U" in [list [kd $ek] [kd $ei]]} { return [R fall [list {*}$base U] ""] }
            set k [akey $P $pk $ek]
            lassign [operandOf $P $pc $pi $ei] ci gi xi
            if {$k eq "" || $ci ne "I"} { return $dead }
            lassign $k pre kx fake rel
            set irel ""; if {[kd $ei] eq "B"} { set irel " Tcl_DecrRefCount(s$pi);" }
            return [R fall [list {*}$base I] "\{ $pre int64_t w_; $gi if (TBC_UNLIKELY(!tbc_tainc(interp, loc_, $v, $kx, $fake, $xi, &w_))) goto D$pc;$irel$rel si$pk = w_; \}"]
        }
        existArray {
            set v [operand [lindex $a 0]]
            if {[kap $key $v] eq "R"} {
                set e [lindex $in $top]
                if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
                set kb [keyArgs $P $top $e]
                if {$kb eq ""} { return $dead }
                lassign $kb kpre kptr klen krel
                set k2 [keyInt2 $P $top $e]
                if {$k2 ne ""} { lassign $k2 ka kj; return [R fall [lreplace $in $top $top I] "\{ int r_ = tbc_rhas_k2(&rv$v, $ka, $kj); si$top = r_; \}"] }
                set ki [keyInt $P $top $e]
                if {$ki ne ""} { return [R fall [lreplace $in $top $top I] "\{ int r_ = tbc_rhas_k(&rv$v, $ki); si$top = r_; \}"] }
                return [R fall [lreplace $in $top $top I] "\{ $kpre int r_ = tbc_rhas(&rv$v, $kptr, $klen);$krel si$top = r_; \}"]
            }
            if {[kap $key $v] ne "F"} { return $dead }
            set e [lindex $in $top]
            if {[kd $e] eq "U"} { return [R fall [lreplace $in $top $top U] ""] }
            set k [akey $P $top $e]
            if {$k eq ""} { return $dead }
            lassign $k pre kx fake rel
            return [R fall [lreplace $in $top $top I] "\{ $pre int r_ = tbc_texist(loc_, $v, $kx); if (TBC_UNLIKELY(r_ < 0)) goto D$pc;$rel si$top = r_; \}"]
        }
        upvar - nsupvar - variable {
            set v [operand [lindex $a 0]]
            if {[kap $key $v] ne "F"} { return $dead }
            set pn [expr {$d-1}]; set en [lindex $in $pn]
            if {[kd $en] eq "U"} { return [R fall [lrange $in 0 end-1] ""] }
            if {[kd $en] ni {B L I}} { return $dead }
            set st $in
            set pre ""
            # the name, and for upvar and namespace upvar the level (or namespace) beneath it, as objects; the level stays on the stack as the result
            set args {}
            if {$op eq "variable"} {
                append pre [boxc $P $pn $en]; lset st $pn B
                set call "tbc_t_variable(interp, loc_, $v, s$pn)"
                set rel " Tcl_DecrRefCount(s$pn);"
            } else {
                set pl [expr {$d-2}]; set el [lindex $in $pl]
                if {[kd $el] eq "U"} { return [R fall [lrange $in 0 end-1] ""] }
                if {[kd $el] ni {B L I}} { return $dead }
                append pre [boxc $P $pn $en]; lset st $pn B
                # the level: a literal is used as it is; a number held unboxed is boxed for the call and released after it
                if {[kd $el] eq "B" || [lt $el] ne ""} {
                    set lx [expr {[kd $el] eq "B" ? "s$pl" : "L_[cident $P]_[lt $el]"}]
                    set lpre ""; set lrel ""
                } else {
                    set lx "lv_"; set lpre "Tcl_Obj *lv_ = tbc_newint(si$pl);"; set lrel " Tcl_DecrRefCount(lv_);"
                }
                set fn [expr {$op eq "upvar" ? "tbc_t_upvar" : "tbc_t_nsupvar"}]
                set call "${fn}(interp, loc_, $v, $lx, s$pn)"
                set rel " Tcl_DecrRefCount(s$pn);"
            }
            set code "\{ $pre"
            if {$op eq "variable"} {
                append code " if (TBC_UNLIKELY($call)) goto [fl $key $st];$rel \}"
                return [R fall [lrange $in 0 end-1] $code]
            }
            append code " $lpre int r_ = $call;$lrel if (TBC_UNLIKELY(r_)) goto [fl $key $st];$rel \}"
            return [R fall [lrange $in 0 end-1] $code]
        }
        default { return $dead }
    }
}

# string first / last / index / range on one-byte characters, in place of the command (tbc_s_first and the others in tbc_runtime.h; they decline for any operand that
# is not a plain ASCII string, and then the command is called as before).  "" when the operands are of a kind this does not handle.
proc stepStrFast {key pc in d op a} {
    global PI
    lassign [keysplit $key] P sig
    lassign [cmdOpSpec $op $a] n name pre post
    set q [expr {$d - $n}]
    set below [lrange $in 0 [expr {$q-1}]]
    set operands [lrange $in $q end]
    foreach e $operands { if {[kd $e] in {A N M Q K U}} { return "" } }
    if {$op eq "regexp"} {
        # (pattern, string; the result is 0 or 1; an error leaves the operands for the failure chain)
        set cflags [expr {[lindex $a 0]}]
        set pre ""; set rel ""
        for {set k $q} {$k < $d} {incr k} { append pre [boxc $P $k [lindex $in $k]] " "; append rel " Tcl_DecrRefCount(s$k);" }
        set st [list {*}$below {*}[lrepeat $n B]]
        return [R fall [list {*}$below I] "$pre\{ int m_ = 0; if (tbc_s_regexp(interp, s[expr {$q+1}], s$q, $cflags, &m_)) goto [fl $key $st];$rel si$q = m_; \}"]
    }
    if {$op eq "strmatch"} {
        # (pattern, string; the result is 0 or 1)
        set nocase [expr {[lindex $a 0] ne "+0" && [lindex $a 0] ne "0"}]
        set pre ""; set rel ""
        for {set k $q} {$k < $d} {incr k} { append pre [boxc $P $k [lindex $in $k]] " "; append rel " Tcl_DecrRefCount(s$k);" }
        return [R fall [list {*}$below I] "$pre\{ int m_ = tbc_s_match(s[expr {$q+1}], s$q, $nocase);$rel si$q = m_; \}"]
    }
    # integer operands (indices): {ok value} for a number held unboxed or an object that is an integer; "" for anything else
    set ints {}
    switch $op {
        strfind - strrfind { set nint 0 }
        strindex { set nint 1 }
        strrange { set nint 2 }
        strrangeImm {
            set nint 0
            foreach w [list [lindex $a 0] [lindex $a 1]] {
                if {![regexp {^\.(-?\d+)$} $w -> v] || $v > 2147483647 || $v < -2147483648} { return "" }
                lappend ints [list 1 "INT64_C($v)"]
            }
        }
    }
    set sk [expr {$op eq "strrangeImm" ? $q : $q + 1}]
    if {$op in {strindex strrange}} {
        for {set k [expr {$q + 1}]} {$k < $d} {incr k} {
            set e [lindex $in $k]
            switch [kd $e] {
                I { lappend ints [list "si$k == (int32_t) si$k" si$k] }
                B { lappend ints [list "tbc_isint(s$k) && tbc_wide(s$k) == (int32_t) tbc_wide(s$k)" "tbc_wide(s$k)"] }
                default { return "" }
            }
        }
    }
    # boxing: the string operands always; an integer operand only where the command has to be called
    set pre ""; set slots {}; set rel ""
    set strops [expr {$op in {strfind strrfind} ? 2 : 1}]
    for {set k $q} {$k < $q + $strops} {incr k} { append pre [boxc $P $k [lindex $in $k]] " "; lappend slots s$k; append rel " Tcl_DecrRefCount(s$k);" }
    set boxint ""; set relint ""
    for {set k [expr {$q + $strops}]} {$k < $d} {incr k} {
        set e [lindex $in $k]
        append boxint [boxc $P $k $e] " "; lappend slots s$k
        if {[kd $e] eq "B"} { append relint " Tcl_DecrRefCount(s$k);" } else { append relint " Tcl_DecrRefCount(s$k);" }
    }
    # (a B integer operand is released in both branches; an I operand has no object in the fast branch)
    set relfastint ""
    for {set k [expr {$q + $strops}]} {$k < $d} {incr k} { if {[kd [lindex $in $k]] eq "B"} { append relfastint " Tcl_DecrRefCount(s$k);" } }
    set st [list {*}$below {*}[lrepeat $n B]]
    set okc [join [lmap i $ints {lindex $i 0}] " && "]
    set vals [lmap i $ints {lindex $i 1}]
    set av "{ [join $slots {, }], NULL }"
    set callopts "Tcl_Obj *av_\[[expr {[llength $slots] + 1}]\] = $av, *r_;"
    set fail "goto [fl $key $st]"
    set s0 s$q
    switch $op {
        strfind - strrfind {
            set fn [expr {$op eq "strfind" ? "tbc_s_first" : "tbc_s_last"}]
            set c "$pre\{ int64_t m_; if (${fn}(s$q, s[expr {$q+1}], &m_)) \{$rel si$q = m_; \} else \{ $callopts if (tbc_cmdcall(interp, TBC_NM([cstring $name]), 2, av_, 0, &r_)) $fail;$rel \{ Tcl_WideInt w_ = 0; (void) Tcl_GetWideIntFromObj(NULL, r_, &w_); Tcl_DecrRefCount(r_); si$q = w_; \} \} \}"
            return [R fall [list {*}$below I] $c]
        }
        strindex - strrange - strrangeImm {
            set call [expr {$op eq "strindex" ? "tbc_s_index(s$q, [lindex $vals 0], &r_)" : "tbc_s_range(s$q, [lindex $vals 0], [lindex $vals 1], &r_)"}]
            set cond [expr {$okc eq "" ? $call : "$okc && $call"}]
            set callslots [expr {$op eq "strrangeImm" ? "tbc_cmdcall(interp, TBC_NM([cstring $name]), 1, av_, 0, &r_)" : "tbc_cmdcall(interp, TBC_NM([cstring $name]), [llength $slots], av_, 0, &r_)"}]
            if {$op eq "strrangeImm"} {
                # (the indices are words of the command: they are not stack slots)
                set av "{ s$q, TBC_NM([cstring [lindex $post 0]]), TBC_NM([cstring [lindex $post 1]]), NULL }"
                set callopts "Tcl_Obj *av_\[4\] = $av, *r_;"
                set callslots "tbc_cmdcall(interp, TBC_NM([cstring $name]), 3, av_, 0, &r_)"
            }
            set c "$pre\{ Tcl_Obj *r_ = NULL; if ($cond) \{$rel$relfastint s$q = r_; \} else \{ $boxint$callopts if ($callslots) $fail;$rel$relint s$q = r_; \} \}"
            return [R fall [list {*}$below B] $c]
        }
    }
    return ""
}

# An instruction the executor implements as a call of a command that uses no variable (cmdOpSpec): the operands are boxed and the command is called,
# as in boxed code.  The result is an object.  An error starts the step again in the boxed code, which raises it with its error info.
proc stepCmdOp {key pc in d op a} {
    global PI
    lassign [keysplit $key] P sig
    lassign [cmdOpSpec $op $a] n name pre post
    set q [expr {$d - $n}]
    set below [lrange $in 0 [expr {$q-1}]]
    set operands [lrange $in $q end]
    foreach e $operands { if {[kd $e] in {A N M Q}} { return [R dead {} "goto D$pc;"] } }
    if {"U" in [lmap e $operands {kd $e}]} { return [R fall [list {*}$below U] ""] }
    set code ""; set slots {}; set rel ""
    foreach w $pre { lappend slots "TBC_NM([cstring $w])" }
    for {set k $q} {$k < $d} {incr k} { append code [boxc $P $k [lindex $in $k]] " "; lappend slots s$k; append rel " Tcl_DecrRefCount(s$k);" }
    foreach w $post { lappend slots "TBC_NM([cstring $w])" }
    set st [list {*}$below {*}[lrepeat $n B]]
    set c "$code\{ Tcl_Obj *av_\[[expr {[llength $slots] + 1}]\] = { [join $slots {, }], NULL }, *r_; if (tbc_cmdcall(interp, TBC_NM([cstring $name]), [llength $slots], av_, 0, &r_)) goto [fl $key $st];$rel s$q = r_; \}"
    return [R fall [list {*}$below B] $c]
}

# foreach.  The stack holds the lists, then the iteration state (kind T: its two numbers are the C variables fit_<step> and fmax_<step>, which the
# function declares), then the empty result.  Entering a loop copies a shared list, as the executor does, and fails like it on a value that is not a list.
proc stepForeachStart {key pc in d a} {
    global PI
    lassign [keysplit $key] P sig
    lassign $a n nl jo vl stepPc
    set d0 [expr {$d - $nl}]
    set below [lrange $in 0 [expr {$d0 - 1}]]
    set lists [lrange $in $d0 end]
    if {$nl == 1 && [kd [lindex $lists 0]] eq "A" && [llength [lindex $vl 0]] == 1} {
        # a loop over a native vector goes through a copy of it, as the interpreter's goes through the list the loop began with (decision 36)
        set av [lt [lindex $lists 0]]
        set c "\{ tbc_ivec c_ = tbc_ivec_copy(&av$av); if (TBC_UNLIKELY(!c_.p)) goto D$pc; sv$d0 = c_; fit_$stepPc = 0; fmax_$stepPc = c_.n; s[expr {$d + 1}] = tbcEmpty; Tcl_IncrRefCount(tbcEmpty); \}"
        return [R jump [list {*}$below N T:$stepPc B] $c tgt $stepPc]
    }
    foreach e $lists { if {[kd $e] in {A N M Q T}} { return [R dead {} "goto D$pc;"] } }
    if {"U" in [lmap e $lists {kd $e}]} { return [R fall [list {*}$below {*}[lrepeat $nl U] U U] ""] }
    set st [list {*}$below {*}[lrepeat $nl B]]
    set c ""
    for {set k $d0} {$k < $d} {incr k} { append c [boxc $P $k [lindex $in $k]] " " }
    append c "\{ long im_ = 0, nt_; int ll_;"
    for {set i 0} {$i < $nl} {incr i} {
        set nv [llength [lindex $vl $i]]; set k [expr {$d0 + $i}]
        append c " \{ Tcl_Obj *l_ = s$k; if (TBC_UNLIKELY(TclListObjLength(interp, l_, &ll_) != TCL_OK)) goto [fl $key $st]; if (Tcl_IsShared(l_)) \{ Tcl_Obj *c_ = TclListObjCopy(NULL, l_); Tcl_IncrRefCount(c_); Tcl_DecrRefCount(l_); s$k = c_; \} nt_ = (ll_ + [expr {$nv - 1}]) / $nv; if (nt_ > im_) im_ = nt_; \}"
    }
    append c " fit_$stepPc = 0; fmax_$stepPc = im_; s[expr {$d + 1}] = tbcEmpty; Tcl_IncrRefCount(tbcEmpty); \}"
    return [R jump [list {*}$below {*}[lrepeat $nl B] T:$stepPc B] $c tgt $stepPc]
}
proc stepForeachStep {key pc in d a} {
    global PI
    lassign [keysplit $key] P sig
    lassign $a n nl jo vl stepPc
    set d0 [expr {$d - $nl - 2}]
    if {$nl == 1 && [kd [lindex $in $d0]] eq "N" && [llength [lindex $vl 0]] == 1} {
        # one step of a loop over the copy of a native vector: the variable gets the next integer
        set var [lindex [lindex $vl 0] 0]
        set kv [kap $key $var]
        set x "sv$d0.p\[it_\]"
        switch $kv {
            F { set asg "\{ Tcl_Obj *v_ = tbc_newint($x); int ok_ = tbc_tset(loc_, $var, v_); Tcl_DecrRefCount(v_); if (TBC_UNLIKELY(!ok_)) goto D$pc; \}"; set st {} }
            W { set asg "wt$var = 0; i$var = $x;"; set st [list [list $var I]] }
            I - - { set asg "i$var = $x;[expr {$var in [flaggedOf $P] ? " g$var = 1;" : ""}]"; set st [list [list $var I]] }
            default { set asg "\{ Tcl_Obj *v_ = tbc_newint($x); if (l$var) Tcl_DecrRefCount(l$var); l$var = v_; \}"; set st [list [list $var B]] }
        }
        set c "\{ if (fit_$stepPc < fmax_$stepPc) \{ long it_ = fit_$stepPc; $asg fit_$stepPc = it_ + 1; @TAKEN@ goto T[expr {$stepPc + $jo}]; \} \}"
        return [R cond $in $c tgt [expr {$stepPc + $jo}] stores $st]
    }
    foreach e [lrange $in $d0 [expr {$d0 + $nl - 1}]] { if {[kd $e] ne "B"} { return [R dead {} "goto D$pc;"] } }
    set stores {}
    set c "\{ if (fit_$stepPc < fmax_$stepPc) \{ long it_ = fit_$stepPc;"
    for {set i 0} {$i < $nl} {incr i} {
        set vars [lindex $vl $i]; set nv [llength $vars]
        append c " \{ Tcl_Obj **el_; int ll_; (void) TclListObjGetElements(interp, s[expr {$d0 + $i}], &ll_, &el_);"
        set j 0
        foreach var $vars {
            if {[kap $key $var] eq "F"} {
                set store "if (TBC_UNLIKELY(!tbc_tset(loc_, $var, v_))) goto D$pc;"
            } else {
                set store "Tcl_IncrRefCount(v_); if (l$var) Tcl_DecrRefCount(l$var); l$var = v_;"
                lappend stores [list $var B]
            }
            append c " \{ long ix_ = it_ * $nv + $j; Tcl_Obj *v_ = ix_ >= ll_ ? NULL : el_\[ix_\]; if (!v_) \{ v_ = Tcl_NewObj(); Tcl_IncrRefCount(v_); $store Tcl_DecrRefCount(v_); \} else \{ $store \} \}"
            incr j
        }
        append c " \}"
    }
    append c " fit_$stepPc = it_ + 1; @TAKEN@ goto T[expr {$stepPc + $jo}]; \} \}"
    return [R cond $in $c tgt [expr {$stepPc + $jo}] stores $stores]
}

# string equality and comparison of two values as strings (eq, ne, string compare)
proc stepStrCmp {key pc in d op} {
    global PI
    lassign [keysplit $key] P sig
    set pa [expr {$d-2}]; set pb [expr {$d-1}]
    set ea [lindex $in $pa]; set eb [lindex $in $pb]
    set below [lrange $in 0 [expr {$pa-1}]]
    if {[kd $ea] in {A N M Q} || [kd $eb] in {A N M Q}} { return [R dead {} "goto D$pc;"] }
    if {"U" in [list [kd $ea] [kd $eb]]} { return [R fall [list {*}$below U] ""] }
    if {$op ne "strcmp" && [kd $ea] eq "I" && [kd $eb] eq "I"} {
        # (integers print in one way only)
        return [R fall [list {*}$below I] "si$pa = (si$pa [expr {$op eq "streq" ? "==" : "!="}] si$pb);"]
    }
    set st [list {*}$below B B]
    set code "[boxc $P $pa $ea] [boxc $P $pb $eb]"
    if {$op eq "strcmp"} {
        return [R fall [list {*}$below I] "\{ int m_; $code m_ = TclStringCmp(s$pa, s$pb, 0, 0, -1); Tcl_DecrRefCount(s$pa); Tcl_DecrRefCount(s$pb); si$pa = m_ < 0 ? -1 : m_ > 0 ? 1 : 0; \}"]
    }
    set inv [expr {$op eq "strneq" ? "!" : ""}]
    return [R fall [list {*}$below I] "\{ int m_; $code m_ = ${inv}(TclStringCmp(s$pa, s$pb, 1, 0, -1) == 0); Tcl_DecrRefCount(s$pa); Tcl_DecrRefCount(s$pb); si$pa = m_; \}"]
}

# string map from to string, and the concatenation of two lists (the executor's INST_LIST_CONCAT)
proc stepStrMap {key pc in d} {
    global PI
    lassign [keysplit $key] P sig
    set q [expr {$d - 3}]
    set below [lrange $in 0 [expr {$q-1}]]
    set operands [lrange $in $q end]
    foreach e $operands { if {[kd $e] in {A N M Q T}} { return [R dead {} "goto D$pc;"] } }
    if {"U" in [lmap e $operands {kd $e}]} { return [R fall [list {*}$below U] ""] }
    set st [list {*}$below B B B]
    set code ""
    for {set k $q} {$k < $d} {incr k} { append code [boxc $P $k [lindex $in $k]] " " }
    set s1 s[expr {$d-1}]; set s2 s[expr {$d-2}]; set s3 s[expr {$d-3}]
    return [R fall [list {*}$below B] "$code\{ Tcl_Obj *mv_\[2\] = { $s3, $s2 }, *r_, *m_, *av_\[2\]; int e_; m_ = Tcl_NewListObj(2, mv_); Tcl_IncrRefCount(m_); av_\[0\] = m_; av_\[1\] = $s1; e_ = tbc_cmdcall(interp, TBC_NM(\"::tcl::string::map\"), 2, av_, 0, &r_); Tcl_DecrRefCount(m_); if (e_) goto [fl $key $st]; Tcl_DecrRefCount($s1); Tcl_DecrRefCount($s2); Tcl_DecrRefCount($s3); $s3 = r_; \}"]
}
proc stepListConcat {key pc in d} {
    global PI
    lassign [keysplit $key] P sig
    set pa [expr {$d-2}]; set pb [expr {$d-1}]
    set ea [lindex $in $pa]; set eb [lindex $in $pb]
    set below [lrange $in 0 [expr {$pa-1}]]
    if {[kd $ea] in {A N M Q T} || [kd $eb] in {A N M Q T}} { return [R dead {} "goto D$pc;"] }
    if {"U" in [list [kd $ea] [kd $eb]]} { return [R fall [list {*}$below U] ""] }
    set st [list {*}$below B B]
    set fl [fl $key $st]
    return [R fall [list {*}$below B] "[boxc $P $pa $ea] [boxc $P $pb $eb] \{ Tcl_Obj *r_; if (Tcl_IsShared(s$pa)) \{ r_ = Tcl_DuplicateObj(s$pa); Tcl_IncrRefCount(r_); if (Tcl_ListObjAppendList(interp, r_, s$pb) != TCL_OK) \{ Tcl_DecrRefCount(r_); goto $fl; \} Tcl_DecrRefCount(s$pa); s$pa = r_; \} else \{ if (Tcl_ListObjAppendList(interp, s$pa, s$pb) != TCL_OK) goto $fl; \} Tcl_DecrRefCount(s$pb); \}"]
}

# a binary operator done by the runtime's boxed function (tbc_bin_<name>): both operands boxed, an object as the result
proc stepBoxedBin {key pc in d name} {
    global PI
    lassign [keysplit $key] P sig
    set pa [expr {$d-2}]; set pb [expr {$d-1}]
    set ea [lindex $in $pa]; set eb [lindex $in $pb]
    set below [lrange $in 0 [expr {$pa-1}]]
    if {[kd $ea] in {A N M Q} || [kd $eb] in {A N M Q}} { return [R dead {} "goto D$pc;"] }
    if {"U" in [list [kd $ea] [kd $eb]]} { return [R fall [list {*}$below U] ""] }
    set st [list {*}$below B B]
    return [R fall [list {*}$below B] "[boxc $P $pa $ea] [boxc $P $pb $eb] if (tbc_bin_${name}(interp, &s$pa, s$pb)) goto [fl $key $st];"]
}

# concat of n values (the executor's INST_CONCAT_STK)
proc stepConcat {key pc in d n} {
    global PI
    lassign [keysplit $key] P sig
    set q [expr {$d - $n}]
    set below [lrange $in 0 [expr {$q-1}]]
    set operands [lrange $in $q end]
    foreach e $operands { if {[kd $e] in {A N M Q}} { return [R dead {} "goto D$pc;"] } }
    if {"U" in [lmap e $operands {kd $e}]} { return [R fall [list {*}$below U] ""] }
    set code ""; set slots {}; set rel ""
    for {set k $q} {$k < $d} {incr k} { append code [boxc $P $k [lindex $in $k]] " "; lappend slots s$k; append rel " Tcl_DecrRefCount(s$k);" }
    return [R fall [list {*}$below B] "$code\{ Tcl_Obj *ov_\[\] = { [join $slots {, }] }; Tcl_Obj *r_ = Tcl_ConcatObj($n, ov_); Tcl_IncrRefCount(r_);$rel s$q = r_; \}"]
}

# the element name in slot p (kind e) for the array fast paths: {declarations expression fake release}, or "" when typed code does not take the kind
proc akey {P p e} {
    switch [kd $e] {
        I {
            if {[lt $e] ne ""} { return [list "" L_[cident $P]_[lt $e] 0 ""] }
            return [list "tbc_ikey_t k_;" "tbc_ikey(&k_, si$p)" 1 ""]
        }
        L { return [list "" L_[cident $P]_[lt $e] 0 ""] }
        B { return [list "" s$p 0 " Tcl_DecrRefCount(s$p);"] }
    }
    return ""
}
# the value of slot p (kind e) as an argument of a fast path that stores it: {setup call release} or "".  The call templates (tmplObj with @V@ for an
# object, tmplInt with @I@ for a machine integer); `call` is a C expression that is true when the store was done.
proc fvalue {P p e tmplObj tmplInt} {
    switch [kd $e] {
        I {
            if {[lt $e] ne ""} { return [list "" [string map [list @V@ L_[cident $P]_[lt $e]] $tmplObj] ""] }
            return [list "" [string map [list @I@ si$p] $tmplInt] ""]
        }
        D {
            if {[lt $e] ne ""} { return [list "" [string map [list @V@ L_[cident $P]_[lt $e]] $tmplObj] ""] }
            return [list "Tcl_Obj *dv_ = tbc_newdbl(sd$p); int dok_ = [string map [list @V@ dv_] $tmplObj];" dok_ " Tcl_DecrRefCount(dv_);"]
        }
        L { return [list "" [string map [list @V@ L_[cident $P]_[lt $e]] $tmplObj] ""] }
        B { return [list "" [string map [list @V@ s$p] $tmplObj] ""] }
    }
    return ""
}

# The instruction that uses the key that the strcat at pc leaves in slot q: {pc variable} when it is an array element operation of typed code (load, store,
# increment, exists) that comes after only simple instructions that leave slot q alone, else "".
# Where the key built by the strcat at pc (left in slot q) goes: every path from there must end at an array operation that takes it as its key, and nothing on the way may
# touch the slot (the value of a store can be computed with branches and calls: a conditional expression between the key and the store).  The result is {pc variables}: the first
# such operation and the arrays of all of them; "" when some path does anything else with the slot, or the paths are too many.
proc keyConsumer {P pc q} {
    global PI
    set found {}; set first ""
    set seen {}
    set todo [list $PI($P,next,$pc)]
    set steps 0
    while {[llength $todo]} {
        set cur [lindex $todo end]; set todo [lrange $todo 0 end-1]
        if {[dict exists $seen $cur]} continue
        dict set seen $cur 1
        if {[incr steps] > 600} { return "" }
        if {![info exists PI($P,depth,$cur)]} { return "" }
        lassign $PI($P,ins,$cur) op a
        set d $PI($P,depth,$cur)
        # (below the slot: an exception has unwound it)
        if {$d <= $q} continue
        if {$op in {loadArray1 loadArray4 existArray incrArray1Imm} && $d - 1 == $q} { lappend found [operand [lindex $a 0]]; if {$first eq ""} { set first $cur }; continue }
        if {$op in {storeArray1 storeArray4 incrArray1} && $d - 2 == $q} { lappend found [operand [lindex $a 0]]; if {$first eq ""} { set first $cur }; continue }
        # (instructions that read or move slots by their position, or that open an argument expansion, are only passed when they stay above the slot)
        switch -- $op {
            expandStart - expandStkTop - invokeExpanded - expandDrop - invokeReplace - evalStk - exprStk - tailcall - yield - yieldToInvoke { return "" }
            over { if {$d - 1 - [operand [lindex $a 0]] <= $q} { return "" } }
            reverse { if {$d - [lindex $a 0] <= $q} { return "" } }
        }
        lassign [effect $op $a $d {}] pops pushes kind
        if {$kind ni {fall jump cond} || $d - $pops < $q + 1} { return "" }
        foreach sc $PI($P,succ,$cur) { lappend todo $sc }
    }
    if {$found eq ""} { return "" }
    return [list $first [lsort -unique $found]]
}
proc allR {key vars} { foreach v $vars { if {[kap $key $v] ne "R"} { return 0 } }; return 1 }

# a dict key held in slot p (described by e) as bytes: {setup pointer length release key-object}, or "" if the kind is not handled
# The key of a native array element as an integer, when it is one whose text is its canonical decimal form (a computed integer, or an integer literal written so): the elements
# of an array in dense mode are reached by it without the text (tbc_r*_k).  "" for any other key.
proc keyInt {P p e} {
    global PI
    if {[kd $e] ne "I"} { return "" }
    if {[lt $e] eq ""} { return si$p }
    set lit [lindex $PI($P,lits) [lt $e]]
    if {[regexp {^-?(0|[1-9][0-9]*)$} $lit] && $lit ne "-0" && $lit >= -9223372036854775808 && $lit <= 9223372036854775807} { return [c_int $lit] }
    return ""
}
# The key of a native array element held as two integers (a key `$i,$j` of integers, kind K:2): their C expressions, else "".
proc keyInt2 {P p e} {
    if {[kd $e] eq "K" && [lt $e] eq "2"} { return [list ka$p kj$p] }
    return ""
}
# the kind an element value gives its array: I for an integer in canonical form (a computed one, or a literal written so), D for a double, W for a tagged number, else B
proc evKind {P e} {
    global PI
    switch [kd $e] {
        D { return D }
        W { return W }
        I {
            if {[lt $e] eq ""} { return I }
            set lit [lindex $PI($P,lits) [lt $e]]
            if {[regexp {^-?(0|[1-9][0-9]*)$} $lit] && $lit ne "-0" && $lit >= -9223372036854775808 && $lit <= 9223372036854775807} { return I }
        }
    }
    return B
}
# the join of the kinds of the elements stored in an array: the same kind, else tagged numbers when the proc uses them and both are numbers, else objects
proc jek {a b} {
    if {$a eq $b} { return $a }
    if {$a in {- U}} { return $b }
    if {$b in {- U}} { return $a }
    if {$::curWpol && $a in {I D W} && $b in {I D W}} { return W }
    return B
}
# the key of an element of a native array in the forms the runtime takes: {suffix key-arguments setup release}; the functions tbc_r<op><suffix> take them after the map
proc rkey {P p e} {
    set k2 [keyInt2 $P $p $e]
    if {$k2 ne ""} { return [list _k2 [join $k2 ", "] "" ""] }
    set ki [keyInt $P $p $e]
    if {$ki ne ""} { return [list _k $ki "" ""] }
    set kb [keyArgs $P $p $e]
    if {$kb eq ""} { return "" }
    lassign $kb pre ptr len rel
    return [list "" "$ptr, $len" $pre $rel]
}
# the call that stores the value in slot p (described by e) into the native array v: {setup call release}, or "" if the kind is not handled
proc rvalue {P p e v suf kargs} {
    global PI
    switch [kd $e] {
        I {
            if {[lt $e] eq ""} { return [list "" "tbc_rseti${suf}(&rv$v, $kargs, si$p)" ""] }
            # (an integer literal in canonical form is stored as the integer, not as the literal's object, which would be parsed again at every store)
            if {[evKind $P $e] eq "I"} { return [list "" "tbc_rseti${suf}(&rv$v, $kargs, [c_int [lindex $PI($P,lits) [lt $e]]])" ""] }
            return [list "" "tbc_rset${suf}(&rv$v, $kargs, L_[cident $P]_[lt $e])" ""]
        }
        D {
            if {[lt $e] eq ""} { return [list "" "tbc_rsetd${suf}(&rv$v, $kargs, sd$p)" ""] }
            return [list "" "tbc_rsetd${suf}(&rv$v, $kargs, [litdbl $P [lt $e]])" ""]
        }
        W { return [list "" "tbc_rsetn${suf}(&rv$v, $kargs, sw$p, si$p, sd$p)" ""] }
        L { return [list "" "tbc_rset${suf}(&rv$v, $kargs, L_[cident $P]_[lt $e])" ""] }
        B { return [list "" "tbc_rset${suf}(&rv$v, $kargs, s$p)" ""] }
    }
    return ""
}
# the C integer of a map key held unboxed (an integer value that is not a literal), "" for any other key
proc mapKeyI {p e} { expr {[kd $e] eq "I" && [lt $e] eq "" ? "si$p" : ""} }
proc keyArgs {P p e} {
    global PI
    switch [kd $e] {
        K {
            if {[lt $e] eq "2"} { return [list "char kb_\[48\]; int kl_ = tbc_fmt_pair(kb_, ka$p, kj$p); const char *kp_ = kb_;" kp_ kl_ "" NULL] }
            return [list "" kb$p kl$p "" NULL]
        }
        B { return [list "int kl_; const char *kp_ = Tcl_GetStringFromObj(s$p, &kl_);" kp_ kl_ " Tcl_DecrRefCount(s$p);" s$p] }
        L - I {
            if {[lt $e] ne ""} {
                set lit [lindex $PI($P,lits) [lt $e]]
                return [list "" [cstring $lit] [cbytes $lit] "" NULL]
            }
            return [list "char kb_\[24\]; int kl_ = tbc_fmt_i64(kb_, si$p); const char *kp_ = kb_;" kp_ kl_ "" NULL]
        }
    }
    return ""
}

# a default value that typed code can pass as a constant: {I c-text} or {D c-text}, or "" for anything else (the classification of literals in `prepare`)
proc defaultConst {d} {
    if {[regexp {^-?(0|[1-9][0-9]*)$} $d] && $d ne "-0" && $d >= -9223372036854775808 && $d <= 9223372036854775807} { return [list I "INT64_C($d)"] }
    if {[string is double -strict $d] && ![regexp {[^0-9eE.+-]} $d]} {
        set dv [expr {double($d)}]
        if {[string equal $dv $d] && $dv == $dv && abs($dv) < 1.7e308} { return [list D [c_dbl $d]] }
    }
    return ""
}

# can typed code of P have changed state that a restart of the call in the boxed code would repeat?  Its own frame variables, or the effects of a
# callee that is not pure.
proc resumable {P {key ""}} {
    global PI
    # (the typed variant the boxed code enters at a loop head can never start the call over: the boxed code has run)
    if {[llength $PI($P,fvars)] || $PI($P,hasYield) || ($key ne "" && [info exists ::OSRKEY] && (([dict exists $::OSRKEY $P] && [dict get $::OSRKEY $P] eq $key) || ([dict exists $::OSRKEYW $P] && [dict get $::OSRKEYW $P] eq $key)))} { return 1 }
    foreach c $PI($P,callees) { if {![info exists PI($c,pure)] || !$PI($c,pure)} { return 1 } }
    return 0
}

# failure label (releasing the boxed slots of state `st`)
proc fl {key st} {
    global FM FRM PI
    lassign [keysplit $key] P sig
    set m [maskOf $st]
    if {[resumable $P $key] && [info exists ::stepPC]} {
        # a proc with variables in the frame, or one that calls a proc with effects, can have changed state before this point, so it cannot start the
        # whole call over in the boxed code: it goes on there at this instruction (the boxed code then repeats the failing step, which raises the
        # error with its error info)
        set pc $::stepPC
        set FRM($key,$pc,$m) $st
        return FR${pc}_$m
    }
    set FM($key,$m) 1
    return F$m
}
# the failure chain that starts the whole call over (used where nothing can have changed yet)
proc flAll {key st} {
    global FM
    set m [maskOf $st]
    set FM($key,$m) 1
    return F$m
}

# arithmetic and comparison
proc operandOf {P pc p e} {
    switch [kd $e] {
        I { return [list I "" si$p] }
        D { return [list D "" sd$p] }
        B {
            if {$::PI($P,wadapt) && !$::curWpol} {
                # (an object that is a double, where an integer was assumed: the proc will use its tagged-number version from now on)
                return [list I "if (TBC_UNLIKELY(!tbc_isint(s$p))) { tbc_wnote(&tbc_wp_[cident $P], s$p); goto D$pc; }" "tbc_wide(s$p)"]
            }
            return [list I "if (TBC_UNLIKELY(!tbc_isint(s$p))) goto D$pc;" "tbc_wide(s$p)"]
        }
        U { return [list U "" ""] }
        W { return [list I "if (TBC_UNLIKELY(sw$p)) goto D$pc;" si$p] }
        L {
            # an integer written non-canonically (0xFF, 010, 1_000 is not one): the operation reads its value, the string is not kept
            set lit [lindex $::PI($P,lits) [lt $e]]
            # (`string is wideinteger` also accepts integers beyond 64 bits: the range is checked)
            if {[string is wideinteger -strict $lit] && ![string match *_* $lit]} {
                set iv [expr {$lit + 0}]
                if {$iv >= -9223372036854775808 && $iv <= 9223372036854775807} { return [list I "" [c_int $iv]] }
            }
            return [list X "" ""]
        }
        default { return [list X "" ""] }
    }
}
# An arithmetic or comparison instruction of the W policy: the operands are integers, doubles, tagged numbers (W) or objects that are numbers (loaded as W: anything
# else, and bignums, NaN, hand over to the boxed code).  The result of + - * / is W, that of % and of the comparisons an integer.  The integer operation is the one
# of the integer path (overflow and zero divisors hand over), the double operation that of the double path.
proc stepArithW {P pc op in d} {
    set pa [expr {$d-2}]; set pb [expr {$d-1}]
    set ea [lindex $in $pa]; set eb [lindex $in $pb]
    set base [lrange $in 0 [expr {$pa-1}]]
    set guards ""; set rel ""
    foreach {tag p e} [list a $pa $ea b $pb $eb] {
        switch [kd $e] {
            I { set T($tag) 0; set IV($tag) si$p; set DV($tag) "((double) si$p)" }
            D { set T($tag) 1; set IV($tag) 0; set DV($tag) sd$p }
            W { set T($tag) sw$p; set IV($tag) si$p; set DV($tag) "(sw$p ? sd$p : (double) si$p)" }
            B {
                append guards " if (TBC_UNLIKELY(!tbc_wload(s$p, &sw$p, &si$p, &sd$p))) goto D$pc;"
                append rel " Tcl_DecrRefCount(s$p);"
                set T($tag) sw$p; set IV($tag) si$p; set DV($tag) "(sw$p ? sd$p : (double) si$p)"
            }
            L {
                lassign [operandOf $P $pc $p $e] cl gl xl
                if {$cl ne "I"} { return [R dead {} "goto D$pc;"] }
                set T($tag) 0; set IV($tag) $xl; set DV($tag) "((double) ($xl))"
            }
            U { return [R fall [list {*}$base U] ""] }
            default { return [R dead {} "goto D$pc;"] }
        }
    }
    set decl "int ta_ = $T(a), tb_ = $T(b); int64_t ia_ = (ta_ ? 0 : $IV(a)), ib_ = (tb_ ? 0 : $IV(b)), ir_; double da_ = $DV(a), db_ = $DV(b), dr_; (void) ir_; (void) dr_;"
    set cmp {lt < le <= gt > ge >= eq == neq !=}
    switch $op {
        add - sub - mult {
            set bi [dict get {add __builtin_add_overflow sub __builtin_sub_overflow mult tbc_mul_ovf} $op]
            set sym [dict get {add + sub - mult *} $op]
            set c "\{$guards $decl if (!ta_ && !tb_) \{ if (TBC_UNLIKELY(${bi}(ia_, ib_, &ir_))) goto D$pc; sw$pa = 0; si$pa = ir_; \} else \{ dr_ = da_ $sym db_; if (TBC_UNLIKELY(dr_ != dr_)) goto D$pc; sw$pa = 1; sd$pa = dr_; \}$rel \}"
            return [R fall [list {*}$base W] $c]
        }
        div {
            set c "\{$guards $decl if (!ta_ && !tb_) \{ if (TBC_UNLIKELY(ib_ == 0 || (ia_ == INT64_MIN && ib_ == -1))) goto D$pc; ir_ = ia_ / ib_; if (ia_ % ib_ != 0 && ((ia_ < 0) != (ib_ < 0))) ir_--; sw$pa = 0; si$pa = ir_; \} else \{ if (TBC_UNLIKELY(db_ == 0.0)) goto D$pc; dr_ = da_ / db_; if (TBC_UNLIKELY(dr_ != dr_)) goto D$pc; sw$pa = 1; sd$pa = dr_; \}$rel \}"
            return [R fall [list {*}$base W] $c]
        }
        mod {
            set c "\{$guards $decl if (TBC_UNLIKELY(ta_ || tb_ || ib_ == 0)) goto D$pc; if (ib_ == -1) ir_ = 0; else \{ ir_ = ia_ % ib_; if (ir_ != 0 && ((ir_ < 0) != (ib_ < 0))) ir_ += ib_; \}$rel si$pa = ir_; \}"
            return [R fall [list {*}$base I] $c]
        }
        default {
            set sym [dict get $cmp $op]
            set c "\{$guards $decl if (!ta_ && !tb_) \{ ir_ = (ia_ $sym ib_); \} else \{ if (TBC_UNLIKELY((!ta_ && (ia_ > TBC_2P53 || ia_ < -TBC_2P53)) || (!tb_ && (ib_ > TBC_2P53 || ib_ < -TBC_2P53)))) goto D$pc; ir_ = (da_ $sym db_); \}$rel si$pa = ir_; \}"
            return [R fall [list {*}$base I] $c]
        }
    }
}

# A comparison (< <= > >= == !=) of anything that is not a number of the kinds typed code holds unboxed: Tcl compares two numbers as numbers and anything else as strings,
# and the generic compare of the boxed code does that.  Typed code calls it for the operands as they are (tbc_cmpo) instead of handing over, and the result is an integer
# like any comparison's.  Where the code above would hand over because an object is not an integer (a double, text, a list...), this is the path taken from there; a
# comparison with an operand that has no numeric kind at all (a text literal) takes it directly.  Errors (none that a comparison can raise, an interrupted evaluation
# aside) hand over as before, with nothing consumed.
proc stepArith {P pc op in d} {
    set r [stepArith0 $P $pc $op $in $d]
    if {$op ni {lt le gt ge eq neq}} { return $r }
    set pa [expr {$d-2}]; set pb [expr {$d-1}]
    set ea [lindex $in $pa]; set eb [lindex $in $pb]
    if {[kd $ea] ni {B I D W L} || [kd $eb] ni {B I D W L}} { return $r }
    if {[kd $ea] ne "B" && [kd $eb] ne "B" && [dict get $r flow] ne "dead"} { return $r }
    if {[dict get $r flow] ni {fall dead}} { return $r }
    if {[kd [lindex [dict get $r out] end]] eq "U"} { return $r }
    set base [lrange $in 0 [expr {$pa-1}]]
    set rel ""; set pre ""; set post ""
    foreach {p e v} [list $pa $ea ta_ $pb $eb tb_] {
        if {[kd $e] eq "B"} { set ox s$p; append rel " Tcl_DecrRefCount(s$p);" } else { set ox $v; append pre " Tcl_Obj *$v = [boxe $P $p $e];"; append post " Tcl_DecrRefCount($v);" }
        set O($v) $ox
    }
    set cu [string toupper $op]
    set slow "\{$pre int64_t r_; int e_ = tbc_cmpo(interp, TBC_$cu, $O(ta_), $O(tb_), &r_);$post if (TBC_UNLIKELY(e_)) goto D$pc;$rel si$pa = r_; \}"
    if {[dict get $r flow] eq "dead"} { return [R fall [list {*}$base I] $slow] }
    set c [string map [list "goto D$pc;" "goto CS$pc;"] [dict get $r code]]
    return [R fall [dict get $r out] "\{ $c goto CK$pc; CS$pc: ; $slow CK$pc: ; \}"]
}
proc stepArith0 {P pc op in d} {
    set pa [expr {$d-2}]; set pb [expr {$d-1}]
    set ea [lindex $in $pa]; set eb [lindex $in $pb]
    # `$x == {}` and `$x != ""`: the empty string is not a number, so the operands are compared as strings: a number held unboxed is never equal to it, any other
    # value is when its string form is empty
    if {$op in {eq neq}} {
        foreach {pe pk} [list $pb $pa $pa $pb] {
            set le [lindex $in $pe]; set oe [lindex $in $pk]
            if {[kd $le] ne "L" || [lindex $::PI($P,lits) [lt $le]] ne "" || [kd $oe] ni {I D B}} continue
            set base [lrange $in 0 [expr {$pa-1}]]
            set want [expr {$op eq "eq" ? 1 : 0}]
            if {[kd $oe] eq "B"} {
                return [R fall [list {*}$base I] "\{ int l_; (void) Tcl_GetStringFromObj(s$pk, &l_); Tcl_DecrRefCount(s$pk); si$pa = (l_ == 0) == $want; \}"]
            }
            return [R fall [list {*}$base I] "si$pa = [expr {$op eq "eq" ? 0 : 1}];"]
        }
    }
    lassign [operandOf $P $pc $pa $ea] ca ga xa
    lassign [operandOf $P $pc $pb $eb] cb gb xb
    set base [lrange $in 0 [expr {$pa-1}]]
    if {$ca eq "X" || $cb eq "X"} { return [R dead {} "goto D$pc;"] }
    if {$ca eq "U" || $cb eq "U"} { return [R fall [list {*}$base U] ""] }
    set rel ""
    if {[kd $ea] eq "B"} { append rel " Tcl_DecrRefCount(s$pa);" }
    if {[kd $eb] eq "B"} { append rel " Tcl_DecrRefCount(s$pb);" }
    set guards "$ga $gb"
    set cmp {lt < le <= gt > ge >= eq == neq !=}
    if {$::curWpol && ([kd $ea] eq "W" || [kd $eb] eq "W" || [kd $ea] eq "B" || [kd $eb] eq "B")} { return [stepArithW $P $pc $op $in $d] }
    if {$ca eq "I" && $cb eq "I"} {
        switch $op {
            add - sub - mult {
                set bi [dict get {add __builtin_add_overflow sub __builtin_sub_overflow mult tbc_mul_ovf} $op]
                set c "\{ int64_t r_; $guards if (TBC_UNLIKELY(${bi}($xa, $xb, &r_))) goto D$pc;$rel si$pa = r_; \}"
                return [R fall [list {*}$base I] $c]
            }
            div {
                set c "\{ int64_t a_, b_, r_; $guards a_ = $xa; b_ = $xb; if (TBC_UNLIKELY(b_ == 0 || (a_ == INT64_MIN && b_ == -1))) goto D$pc; r_ = a_ / b_; if (a_ % b_ != 0 && ((a_ < 0) != (b_ < 0))) r_--;$rel si$pa = r_; \}"
                return [R fall [list {*}$base I] $c]
            }
            mod {
                set c "\{ int64_t a_, b_, r_; $guards a_ = $xa; b_ = $xb; if (TBC_UNLIKELY(b_ == 0)) goto D$pc; if (b_ == -1) r_ = 0; else \{ r_ = a_ % b_; if (r_ != 0 && ((r_ < 0) != (b_ < 0))) r_ += b_; \}$rel si$pa = r_; \}"
                return [R fall [list {*}$base I] $c]
            }
            default {
                set c "\{ int64_t r_; $guards r_ = ($xa [dict get $cmp $op] $xb);$rel si$pa = r_; \}"
                return [R fall [list {*}$base I] $c]
            }
        }
    }
    # at least one double
    if {$op eq "mod"} { return [R dead {} "goto D$pc;"] }
    set conv ""
    set xda $xa; set xdb $xb
    if {$ca eq "I"} {
        set xda "(double) ($xa)"
        if {$op in {lt le gt ge eq neq}} { append conv " if (TBC_UNLIKELY(($xa) > TBC_2P53 || ($xa) < -TBC_2P53)) goto D$pc;" }
    }
    if {$cb eq "I"} {
        set xdb "(double) ($xb)"
        if {$op in {lt le gt ge eq neq}} { append conv " if (TBC_UNLIKELY(($xb) > TBC_2P53 || ($xb) < -TBC_2P53)) goto D$pc;" }
    }
    switch $op {
        add - sub - mult {
            set sym [dict get {add + sub - mult *} $op]
            set c "\{ double r_; $guards$conv r_ = $xda $sym $xdb; if (TBC_UNLIKELY(r_ != r_)) goto D$pc;$rel sd$pa = r_; \}"
            return [R fall [list {*}$base D] $c]
        }
        div {
            set c "\{ double r_, b_; $guards$conv b_ = $xdb; if (TBC_UNLIKELY(b_ == 0.0)) goto D$pc; r_ = $xda / b_; if (TBC_UNLIKELY(r_ != r_)) goto D$pc;$rel sd$pa = r_; \}"
            return [R fall [list {*}$base D] $c]
        }
        default {
            set c "\{ int64_t r_; $guards$conv r_ = ($xda [dict get $cmp $op] $xdb);$rel si$pa = r_; \}"
            return [R fall [list {*}$base I] $c]
        }
    }
}

# &, |, ^, << and >> on machine integers (anything else leaves typed mode: the boxed code raises the interpreter's errors, or goes to bignums)
proc stepBit {P pc op in d} {
    set pa [expr {$d-2}]; set pb [expr {$d-1}]
    set ea [lindex $in $pa]; set eb [lindex $in $pb]
    lassign [operandOf $P $pc $pa $ea] ca ga xa
    lassign [operandOf $P $pc $pb $eb] cb gb xb
    set base [lrange $in 0 [expr {$pa-1}]]
    if {$ca eq "X" || $cb eq "X"} { return [R dead {} "goto D$pc;"] }
    if {$ca eq "U" || $cb eq "U"} { return [R fall [list {*}$base U] ""] }
    if {$ca ne "I" || $cb ne "I"} { return [R dead {} "goto D$pc;"] }
    set rel ""
    if {[kd $ea] eq "B"} { append rel " Tcl_DecrRefCount(s$pa);" }
    if {[kd $eb] eq "B"} { append rel " Tcl_DecrRefCount(s$pb);" }
    set guards "$ga $gb"
    switch $op {
        bitand { set c "\{ int64_t r_; $guards r_ = ($xa & $xb);$rel si$pa = r_; \}" }
        bitor { set c "\{ int64_t r_; $guards r_ = ($xa | $xb);$rel si$pa = r_; \}" }
        bitxor { set c "\{ int64_t r_; $guards r_ = ($xa ^ $xb);$rel si$pa = r_; \}" }
        lshift { set c "\{ int64_t a_, b_, r_; $guards a_ = $xa; b_ = $xb; if (TBC_UNLIKELY(b_ < 0 || b_ > 62)) goto D$pc; r_ = (int64_t) ((uint64_t) a_ << b_); if (TBC_UNLIKELY((r_ >> b_) != a_)) goto D$pc;$rel si$pa = r_; \}" }
        rshift { set c "\{ int64_t a_, b_, r_; $guards a_ = $xa; b_ = $xb; if (TBC_UNLIKELY(b_ < 0)) goto D$pc; r_ = b_ >= 64 ? (a_ < 0 ? -1 : 0) : (a_ >> b_);$rel si$pa = r_; \}" }
    }
    return [R fall [list {*}$base I] $c]
}
proc stepUnary {P pc op in d} {
    set p [expr {$d-1}]; set e [lindex $in $p]
    if {$op in {uminus uplus not} && ([kd $e] eq "W" || ($::curWpol && [kd $e] eq "B"))} {
        set base [lrange $in 0 [expr {$p-1}]]
        set load ""; set rel ""
        if {[kd $e] eq "B"} { set load "if (TBC_UNLIKELY(!tbc_wload(s$p, &sw$p, &si$p, &sd$p))) goto D$pc;"; set rel " Tcl_DecrRefCount(s$p);" }
        switch $op {
            uplus { return [R fall [list {*}$base W] "\{ $load$rel \}"] }
            uminus { return [R fall [list {*}$base W] "\{ $load if (sw$p) \{ sd$p = -sd$p; \} else \{ if (TBC_UNLIKELY(si$p == INT64_MIN)) goto D$pc; si$p = -si$p; \}$rel \}"] }
            not { return [R fall [list {*}$base I] "\{ int64_t r_; $load if (sw$p) \{ if (TBC_UNLIKELY(sd$p != sd$p)) goto D$pc; r_ = (sd$p == 0.0); \} else r_ = (si$p == 0);$rel si$p = r_; \}"] }
        }
    }
    lassign [operandOf $P $pc $p $e] ca ga xa
    set base [lrange $in 0 [expr {$p-1}]]
    if {$ca eq "X"} { return [R dead {} "goto D$pc;"] }
    if {$ca eq "U"} { return [R fall [list {*}$base U] ""] }
    set rel ""; if {[kd $e] eq "B"} { set rel " Tcl_DecrRefCount(s$p);" }
    if {$ca eq "I"} {
        switch $op {
            uminus { return [R fall [list {*}$base I] "\{ int64_t r_; $ga if (TBC_UNLIKELY($xa == INT64_MIN)) goto D$pc; r_ = -($xa);$rel si$p = r_; \}"] }
            bitnot { return [R fall [list {*}$base I] "\{ int64_t r_; $ga r_ = ~($xa);$rel si$p = r_; \}"] }
            not { return [R fall [list {*}$base I] "\{ int64_t r_; $ga r_ = ($xa == 0);$rel si$p = r_; \}"] }
            uplus { return [R fall [list {*}$base I] "\{ int64_t r_; $ga r_ = $xa;$rel si$p = r_; \}"] }
        }
    }
    # a double
    switch $op {
        uminus { return [R fall [list {*}$base D] "sd$p = -sd$p;"] }
        not { return [R fall [list {*}$base I] "\{ int64_t r_; if (TBC_UNLIKELY(sd$p != sd$p)) goto D$pc; r_ = (sd$p == 0.0); si$p = r_; \}"] }
        default { return [R dead {} "goto D$pc;"] }
    }
}

proc stepReverse {P in d n} {
    set q [expr {$d - $n}]
    set old [lrange $in $q end]
    set new [lreverse $old]
    set c ""
    # copy the affected slots to temporaries of the right type, then store them in their new places
    for {set j 0} {$j < $n} {incr j} {
        set e [lindex $old $j]; set k [kd $e]; set p [expr {$q + $j}]
        switch $k { I { append c "int64_t ti$j = si$p; " } D { append c "double td$j = sd$p; " } B { append c "Tcl_Obj *tb$j = s$p; " } }
    }
    for {set j 0} {$j < $n} {incr j} {
        set src [expr {$n - 1 - $j}]; set e [lindex $old $src]; set k [kd $e]; set p [expr {$q + $j}]
        switch $k { I { append c "si$p = ti$src; " } D { append c "sd$p = td$src; " } B { append c "s$p = tb$src; " } }
    }
    return [R fall [list {*}[lrange $in 0 [expr {$q-1}]] {*}$new] "\{ $c\}"]
}

# code that leaves typed mode: write the state (locals into the frame, the stack into an array) and continue in G_<proc> at gpc.  `pre` runs
# first.  A function that was called directly has no frame: it reports tbc_st 3 and the caller makes the call the ordinary way.
proc enterG {key gpc slots pre flush} {
    lassign [keysplit $key] P sig
    set c "if (TBC_UNLIKELY(!inframe)) \{ tbc_st = 3; rc = TCL_OK; goto [flAll $key $slots]; \} $pre"
    append c [boxLocals $key $flush $slots]
    foreach v $::PI($P,rvars) { append c " tbc_rflush(interp, loc_, $v, &rv$v);" }
    set vs $flush
    foreach e $slots { if {[kd $e] in {A M}} { lappend vs [lt $e] } }
    foreach v [lsort -integer -unique $vs] { append c " if (l$v) tbc_flushr(interp, loc_, $v, l$v);" }
    set ::boxMode alias
    set n [llength $slots]
    for {set p 0} {$p < $n} {incr p} { append c " [boxc $P $p [lindex $slots $p]]" }
    set ::boxMode copy
    set arr {}; for {set p 0} {$p < $n} {incr p} { lappend arr s$p }
    append c " \{ Tcl_Obj *stk_\[[expr {$n + 1}]\] = { [join [concat $arr NULL] {, }] }; int g_ = G_[cident $P](interp, $gpc, stk_, $n);"
    if {$::PI($P,hasYield)} { append c " if (TBC_UNLIKELY(tbc_susp)) \{ tbc_st = 4; rc = TCL_OK; goto ret; \}" }
    append c " if (g_ == TCL_OK) \{ tbc_box = tbc_takeres(interp); tbc_st = 1; rc = TCL_OK; \} else \{ rc = g_; \} goto ret; \}"
    return $c
}

proc stepInvoke {key pc in d n} {
    global PI VK translatable pureProcs csafeProcs
    lassign [keysplit $key] P sig
    set dead [R dead {} "goto D$pc;"]
    set q [expr {$d - $n}]
    set cmdE [lindex $in $q]
    set below [lrange $in 0 [expr {$q-1}]]
    set args [lrange $in [expr {$q+1}] end]
    # direct call to a translated proc?
    if {[kd $cmdE] eq "L"} {
        set nm0 [lindex $PI($P,lits) [lt $cmdE]]
        set ns [namespace qualifiers $P]; if {$ns eq ""} { set ns :: }
        set nm [resolveProc $ns $nm0]
        if {$nm ni $pureProcs} { set nm "" }
        if {[regexp {^(?:::)?tcl::mathfunc::(\w+)$} $nm0 -> mf] && [resolveProc $ns $nm0] eq ""} {
            set r [mathFunc $P $pc $in $d $n $q $mf]
            if {$r ne ""} { return $r }
        }
        set isLrepeat [expr {$nm0 in {lrepeat ::lrepeat} && [resolveProc $ns $nm0] eq ""}]
        if {$isLrepeat && [llength $args] == 2 && "U" in [lmap e $args {kd $e}]} {
            return [R fall [list {*}$below U] ""]
        }
        if {$isLrepeat && [llength $args] == 2 && [kd [lindex $args 0]] eq "I" && [kd [lindex $args 1]] eq "I"} {
            set p1 [expr {$q+1}]; set p2 [expr {$q+2}]
            return [R fall [list {*}$below N] "if (TBC_UNLIKELY(!tbc_is_lrepeat(interp))) goto D$pc; sv$q = tbc_ivec_new(si$p1, si$p2); if (TBC_UNLIKELY(!sv$q.p)) goto D$pc;"]
        }
        set hasVec 0
        foreach e $args { if {[kd $e] in {A N M Q}} { set hasVec 1 } }
        set omitted {}
        if {!$hasVec && $nm ne "" && $PI($nm,argsIdx) < 0 && [llength $args] < $PI($nm,nargs)} {
            # trailing arguments left out: their defaults, if they are numbers
            foreach dflt [lrange $PI($nm,defaults) [llength $args] end] {
                set dc [expr {[llength $dflt] ? [defaultConst [lindex $dflt 0]] : ""}]
                if {$dc eq ""} { set omitted fail; break }
                lappend omitted $dc
            }
        }
        if {!$hasVec && $nm ne "" && $PI($nm,argsIdx) < 0 && $omitted ne "fail" && [llength $args] + [llength $omitted] == $PI($nm,nargs)} {
            if {"U" in [lmap e $args {kd $e}]} { return [R fall [list {*}$below U] ""] }
            set csig ""; set cargs {}
            set pos [expr {$q+1}]
            foreach e $args {
                switch [kd $e] {
                    I { append csig I; lappend cargs si$pos }
                    D { append csig D; lappend cargs sd$pos }
                    B { append csig B; lappend cargs s$pos }
                    L { append csig B; lappend cargs L_[cident $P]_[lt $e] }
                }
                incr pos
            }
            foreach dc $omitted { append csig [lindex $dc 0]; lappend cargs [lindex $dc 1] }
            set ckey [newVariant $nm $csig]
            set rk $VK($ckey,ret)
            set rel ""
            set pos [expr {$q+1}]
            foreach e $args { if {[kd $e] eq "B"} { append rel " Tcl_DecrRefCount(s$pos);" }; incr pos }
            set cid [cident $nm]
            if {$rk in {- U}} { set outk U } else { set outk $rk }
            set rtype [ctype [expr {$outk eq "U" ? "B" : $outk}]]
            set rvar [svar [expr {$outk eq "U" ? "B" : $outk}] $q]
            set c "if (TBC_UNLIKELY(!tbc_valid_$cid[expr {$PI($nm,wadapt) ? " || tbc_wp_$cid" : ""}])) \{ tbc_st = 3; goto C$pc; \} \{ $rtype r_ = V_${cid}_${csig}(interp, rem - 1, 0[expr {[llength $cargs] ? ", " : ""}][join $cargs {, }]); if (TBC_UNLIKELY(tbc_st)) goto C$pc;$rel $rvar = r_; \}"
            # post-call stub: error, or a boxed result because the callee fell back to its generic code
            set nextpc $PI($P,next,$pc)
            # a callee that had to leave typed mode reports it (tbc_st 3): the call is then made the ordinary way, with boxed arguments
            set ov "Tcl_Obj *ov_\[$n\]; int r2_; tbc_st = 0; ov_\[0\] = Tcl_NewStringObj([cstring $nm0], -1); Tcl_IncrRefCount(ov_\[0\]);"
            set j 1; set pos [expr {$q+1}]
            foreach e $args {
                switch [kd $e] {
                    I { append ov " ov_\[$j\] = tbc_newint(si$pos);" }
                    D { append ov " ov_\[$j\] = tbc_newdbl(sd$pos);" }
                    B { append ov " ov_\[$j\] = s$pos; Tcl_IncrRefCount(ov_\[$j\]);" }
                    L { append ov " ov_\[$j\] = L_[cident $P]_[lt $e]; Tcl_IncrRefCount(ov_\[$j\]);" }
                }
                incr j; incr pos
            }
            append ov " tbc_setpc(interp, $pc); r2_ = Tcl_EvalObjv(interp, $n, ov_, TBC_EV); \{ int i_; for (i_ = 0; i_ < $n; i_++) Tcl_DecrRefCount(ov_\[i_\]); \}"
            append ov " if (r2_ != TCL_OK) \{ tbc_st = 0; rc = tbc_rc = r2_; [enterG $key [expr {-$pc-1}] $in "" [flushSet $P $pc]] \} r_ = tbc_takeres(interp);"
            set stub "C$pc: TBC_HIT([cstring "C:$key:$pc"]); if (tbc_st == 2) \{ tbc_st = 0; rc = tbc_rc; goto [fl $key $in]; \}\n"
            # the boxed result of an ordinary call (or of a callee that fell back) goes on in typed code when it is of the kind the callee's typed code returns
            set cont ""
            if {[info exists VK($key,in,$nextpc)]} {
                set ostate [list {*}$below $outk]
                set edge ""
                if {[llength $VK($key,in,$nextpc)] == [llength $ostate]} { set edge [edgec $P $ostate $VK($key,in,$nextpc)] }
                switch $outk {
                    I { set cont "\{ int64_t w_; if (tbc_arg_int(s$q, &w_)) \{ Tcl_DecrRefCount(s$q); si$q = w_; $edge goto T$nextpc; \} \}" }
                    D { set cont "\{ double dv_; if (tbc_arg_dbl(s$q, &dv_)) \{ Tcl_DecrRefCount(s$q); sd$q = dv_; $edge goto T$nextpc; \} \}" }
                    B { set cont "$edge goto T$nextpc;" }
                }
            }
            append stub "    \{ Tcl_Obj *r_; if (tbc_st == 3) \{ if (!inframe) \{ rc = TCL_OK; goto [fl $key $in]; \} $ov \} else \{ r_ = tbc_box; \} tbc_st = 0;$rel s$q = r_; $cont [enterG $key $nextpc [list {*}$below B] "" [flushSet $P $nextpc]] \}\n"
            return [R fall [list {*}$below $outk] $c calls [list [list $nm $csig]] stub $stub]
        }
    }
    # a command that cannot see or change the frame (a built-in that is pure): box the words and let the interpreter dispatch.  Anything else
    # leaves typed mode: the boxed code runs it with the variables in the frame.
    if {[kd $cmdE] ne "L"} { return $dead }
    set nm0 [lindex $PI($P,lits) [lt $cmdE]]
    set ns [namespace qualifiers $P]; if {$ns eq ""} { set ns :: }
    set cp [resolveProc $ns $nm0]
    if {$cp ne ""} {
        # a translated proc that needs a frame (arrays, global, variable...): the interpreter makes the call, with boxed arguments, and typed code goes on
        # with the result.  The callee cannot reach this proc's variables (it is caller-safe), so they can stay in C variables.  The call has effects, so an
        # error is not repeated: it is handled by the boxed code's error path for the call.
        if {$cp ni $csafeProcs} { return $dead }
        foreach e $args { if {[kd $e] in {A N M Q}} { return $dead } }
        if {"U" in [lmap e $args {kd $e}]} { return [R fall [list {*}$below U] ""] }
        set pre ""; set slots {}; set rel ""
        for {set k $q} {$k < $d} {incr k} {
            append pre [boxc $P $k [lindex $in $k]] " "
            lappend slots s$k; append rel " Tcl_DecrRefCount(s$k);"
        }
        set st [list {*}$below {*}[lrepeat $n B]]
        set c "$pre\{ Tcl_Obj *ov_\[\] = { [join $slots {, }] }; int r_; tbc_setpc(interp, $pc); r_ = Tcl_EvalObjv(interp, $n, ov_, TBC_EV); if (r_ != TCL_OK) \{ rc = tbc_rc = r_; tbc_st = 0; [enterG $key [expr {-$pc-1}] $st "" [flushSet $P $pc]] \}$rel s$q = tbc_takeres(interp); \}"
        return [R fall [list {*}$below B] $c]
    }
    if {[regexp {^(?:::)?tcl::binary::scan$} $nm0]} {
        set r [binScan $key $P $pc $in $d $n $q]
        if {$r ne ""} { return $r }
    }
    set sub [expr {[llength $args] ? [expr {[kd [lindex $args 0]] eq "L" ? [lindex $PI($P,lits) [lt [lindex $args 0]]] : "-"}] : "-"}]
    if {![pureBuiltin $nm0 $sub]} { return $dead }
    foreach e $args { if {[kd $e] in {A N M Q}} { return $dead } }
    set pre ""; set slots {}; set rel ""
    for {set k $q} {$k < $d} {incr k} {
        append pre [boxc $P $k [lindex $in $k]] " "
        lappend slots s$k; append rel " Tcl_DecrRefCount(s$k);"
    }
    set st [list {*}$below {*}[lrepeat $n B]]
    # (the math functions are Tcl's own while tbc_mf_ok says so; otherwise the boxed code makes the call)
    set guard [expr {[isMathBuiltin $nm0] ? "if (TBC_UNLIKELY(!tbc_mf_ok)) goto D$pc; " : ""}]
    # (a built-in that the module has pinned is called through its C procedure when nothing the interpreter's dispatch would do can matter: tbc_direct)
    set call "Tcl_EvalObjv(interp, $n, ov_, TBC_EV)"
    if {![isMathBuiltin $nm0]} {
        set dcid dc_[cident $nm0]
        dict set ::DCNAMES $nm0 $dcid
        set ecid NULL
        set ei [ensIndex $nm0]
        if {$ei >= 0} { set ecid "tbc_ens_pin\[$ei\]" }
        # (an execution trace on the ensemble is run by the interpreter's dispatch of `binary format`, not by a call of ::tcl::binary::format by name: boxed code makes the call then)
        if {$ecid ne "NULL"} { append guard "if (TBC_UNLIKELY($ecid && ($ecid->flags & CMD_HAS_EXEC_TRACES))) goto D$pc; " }
        set call "(tbc_direct(interp, tbc_$dcid, $ecid, $n, ov_) ? TCL_OK : $call)"
    }
    set c "$guard$pre\{ Tcl_Obj *ov_\[\] = { [join $slots {, }] }; int r_; tbc_setpc(interp, $pc); r_ = $call; if (r_ != TCL_OK) \{ rc = r_; goto [fl $key $st]; \}$rel s$q = tbc_takeres(interp); \}"
    return [R fall [list {*}$below B] $c]
}

# `binary scan $data <t>[u]* var` with var a local held as an object: the list is built in C (tbc_bscan) and stored like a `set`; the result of the command is 1.
# "" when the call is not of that form (the boxed code then runs the command).
proc binScan {key P pc in d n q} {
    global PI
    if {$n != 4} { return "" }
    set below [lrange $in 0 [expr {$q-1}]]
    lassign [lrange $in [expr {$q+1}] end] ed ef ev
    if {[kd $ef] ne "L" || [kd $ev] ne "L" || [kd $ed] ni {B L U}} { return "" }
    if {![regexp $::tbcScanFmt [lindex $PI($P,lits) [lt $ef]] -> t u]} { return "" }
    set vi [lsearch -exact $PI($P,vnames) [lindex $PI($P,lits) [lt $ev]]]
    if {$vi < 0 || [kap $key $vi] ni {B -}} { return "" }
    if {[kd $ed] eq "U"} { return [R fall [list {*}$below U] ""] }
    set pd [expr {$q+1}]
    set dx [expr {[kd $ed] eq "B" ? "s$pd" : "L_[cident $P]_[lt $ed]"}]
    set rel [expr {[kd $ed] eq "B" ? " Tcl_DecrRefCount(s$pd);" : ""}]
    set c "\{ Tcl_Obj *n_ = tbc_bscan($dx, '$t', [expr {$u eq "u"}]);$rel Tcl_IncrRefCount(n_); if (l$vi) Tcl_DecrRefCount(l$vi); l$vi = n_; si$q = 1; \}"
    return [R fall [list {*}$below I] $c stores [list [list $vi B]]]
}

# A math function computed in typed code, or "" when the generic call has to do it.  `in` is the stack state before the call: the command word at
# q, the arguments above it.  The result goes into slot q.  Every case leaves the state unchanged when it gives up (goto D$pc); the conversions
# and the result checks are those of Tcl's ExprUnaryFunc/ExprBinaryFunc/CheckDoubleResult and of the functions below (see tclBasic.c).
proc mathFunc {P pc in d n q mf} {
    set below [lrange $in 0 [expr {$q-1}]]
    set args [lrange $in [expr {$q+1}] end]
    set unary {sin sin cos cos tan tan asin asin acos acos atan atan sinh sinh cosh cosh tanh tanh exp exp log log log10 log10}
    set unaryPlain {sqrt sqrt floor floor ceil ceil}
    set binary {pow pow atan2 atan2 fmod fmod hypot hypot}
    if {$mf in [dict keys $unary] || $mf in [dict keys $unaryPlain] || $mf in {double int wide round abs}} { set arity 1 } elseif {$mf in [dict keys $binary]} { set arity 2 } else { return "" }
    if {$n != $arity + 1} { return "" }
    foreach e $args { if {[kd $e] eq "U"} { return [R fall [list {*}$below U] ""] } }
    set pos [expr {$q + 1}]
    # operands as doubles (an integer is converted, as Tcl_GetDoubleFromObj does; an object must hold a finite number)
    set pre ""; set rel ""; set xs {}
    set k 0
    foreach e $args {
        set p [expr {$q + 1 + $k}]
        # (floor and ceil convert an integer through a bignum, which truncates where a C cast rounds: only integers a double holds exactly are done here)
        set exact [expr {$mf in {floor ceil} ? "_exact" : ""}]
        switch [kd $e] {
            I {
                if {$exact ne ""} { append pre "if (TBC_UNLIKELY(si$p < -INT64_C(9007199254740992) || si$p > INT64_C(9007199254740992))) goto D$pc; " }
                lappend xs "(double) si$p"
            }
            D { lappend xs "sd$p" }
            W {
                if {$exact ne ""} { append pre "if (TBC_UNLIKELY(!sw$p && (si$p < -INT64_C(9007199254740992) || si$p > INT64_C(9007199254740992)))) goto D$pc; " }
                lappend xs "(sw$p ? sd$p : (double) si$p)"
            }
            B { append pre "double x${k}_; if (TBC_UNLIKELY(!tbc_getdbl${exact}(s$p, &x${k}_))) goto D$pc; "; append rel " Tcl_DecrRefCount(s$p);"; lappend xs x${k}_ }
            default { return "" }
        }
        incr k
    }
    set guard "if (TBC_UNLIKELY(!tbc_mf_ok)) goto D$pc; "
    set e0 [lindex $args 0]; set p0 [expr {$q + 1}]
    if {[dict exists $unary $mf]} {
        set fn [dict get $unary $mf]
        set c "\{ double r_; $pre${guard}errno = 0; r_ = tbc_opaque_dbl(${fn}([lindex $xs 0])); if (TBC_UNLIKELY(!TBC_MF_OK(r_, errno))) goto D$pc;$rel sd$q = r_; \}"
        return [R fall [list {*}$below D] $c]
    }
    if {[dict exists $unaryPlain $mf]} {
        set fn [dict get $unaryPlain $mf]
        set c "\{ double r_; $pre${guard}r_ = ${fn}([lindex $xs 0]); if (TBC_UNLIKELY(r_ != r_)) goto D$pc;$rel sd$q = r_; \}"
        return [R fall [list {*}$below D] $c]
    }
    if {[dict exists $binary $mf]} {
        set fn [dict get $binary $mf]
        set c "\{ double r_; $pre${guard}errno = 0; r_ = tbc_opaque_dbl(${fn}([lindex $xs 0], [lindex $xs 1])); if (TBC_UNLIKELY(!TBC_MF_OK(r_, errno))) goto D$pc;$rel sd$q = r_; \}"
        return [R fall [list {*}$below D] $c]
    }
    if {$mf in {int wide round abs} && [kd [lindex $args 0]] eq "W"} { return "" }
    switch $mf {
        double {
            return [R fall [list {*}$below D] "\{ $pre${guard}sd$q = [lindex $xs 0];$rel \}"]
        }
        int - wide {
            switch [kd $e0] {
                I { return [R fall [list {*}$below I] "${guard}\{ if (TBC_UNLIKELY(sizeof(long) != 8)) goto D$pc; si$q = si$p0; \}"] }
                D { return [R fall [list {*}$below I] "\{ int64_t r_; ${guard}if (TBC_UNLIKELY(!tbc_dbl_to_int(sd$p0, &r_))) goto D$pc; si$q = r_; \}"] }
                B { return [R fall [list {*}$below I] "\{ Tcl_WideInt w_; double d_; int64_t r_; int k_; ${guard}k_ = tbc_num(s$p0, &w_, &d_); if (sizeof(long) != 8) goto D$pc; if (k_ == 1) r_ = w_; else if (!(k_ == 2 && tbc_dbl_to_int(d_, &r_))) goto D$pc; Tcl_DecrRefCount(s$p0); si$q = r_; \}"] }
            }
            return ""
        }
        round {
            switch [kd $e0] {
                I { return [R fall [list {*}$below I] "si$q = si$p0;"] }
                D { return [R fall [list {*}$below I] "\{ int64_t r_; ${guard}if (TBC_UNLIKELY(!tbc_dbl_round(sd$p0, &r_))) goto D$pc; si$q = r_; \}"] }
            }
            return ""
        }
        abs {
            switch [kd $e0] {
                I { return [R fall [list {*}$below I] "\{ int64_t a_ = si$p0; ${guard}if (TBC_UNLIKELY(a_ == INT64_MIN)) goto D$pc; si$q = a_ < 0 ? -a_ : a_; \}"] }
                D { return [R fall [list {*}$below D] "${guard}sd$q = fabs(sd$p0);"] }
            }
            return ""
        }
    }
    return ""
}

# is a call of the built-in command nm (first word after it: sub, or -) free of any access to variables and of callbacks into scripts?
proc pureBuiltin {nm sub} {
    regsub {^::} $nm {} b
    if {[regexp {^tcl::dict::(\w+)$} $b -> s1]} { set b dict; set sub $s1 }
    if {[string match tcl::string::* $b] || [string match tcl::list::* $b] || [isMathBuiltin $b]} { return 1 }
    if {$b eq "dict"} { return [expr {$sub in {size keys values get exists create merge replace remove}}] }
    return [expr {$b in $::tbcPureBuiltins}]
}

# ---------------------------------------------------------------- fixpoint for one variant
# returns 1 if the result kind of this variant changed or a new variant was discovered
# Variables that an instruction uses as a number: a load of the variable whose next user is an arithmetic, comparison or bit operation.
proc numVars {P} {
    global PI NUMV
    if {[info exists NUMV($P)]} { return $NUMV($P) }
    set res {}
    foreach pc $PI($P,reach) {
        lassign $PI($P,ins,$pc) op a
        if {$op ni {loadScalar1 loadScalar4}} continue
        set q $PI($P,depth,$pc)
        set cur $PI($P,next,$pc)
        for {set steps 0} {$steps < 60 && [info exists PI($P,depth,$cur)]} {incr steps} {
            lassign $PI($P,ins,$cur) cop ca
            set cd $PI($P,depth,$cur)
            lassign [effect $cop $ca $cd [lindex $PI($P,mk,$cur) end]] pops pushes kind
            if {$kind ne "fall"} break
            if {$cd - $pops <= $q} {
                if {$cop in {add sub mult div mod lt le gt ge eq neq bitand bitor bitxor lshift rshift}} { lappend res [operand [lindex $a 0]] }
                break
            }
            set cur $PI($P,next,$cur)
        }
    }
    set NUMV($P) [lsort -integer -unique $res]
    return $NUMV($P)
}
# Does the store at pc keep a value that was loaded from an array or a list, straight before it, into a variable that is used as a number?  Such a store is
# speculated to be an integer (kind S of the variable, see jk): typed code checks the value and hands over if it is not one.
proc specStore {P pc v} {
    global PI
    if {$v ni [numVars $P]} { return 0 }
    foreach p $PI($P,reach) { if {$PI($P,next,$p) == $pc && [lindex $PI($P,ins,$p) 0] in {loadArray1 loadArray4 listIndex listIndexImm}} { return 1 } }
    return 0
}

# The typed state after an instruction that typed code hands over at and that links variables of the frame by name (`variable $name`, `upvar 0 $name x`,
# `global`): {pc state} for the code that goes on when the boxed code enters typed code again at a loop head, or "" (see osrAttempt).  Only where a loop head can be
# reached from there, and only when no stack slot holds something a typed state cannot be rebuilt for.
proc frameSeed {P pc in} {
    global PI
    lassign $PI($P,ins,$pc) op a
    if {$op ni {invokeStk1 invokeStk4} || $PI($P,hasYield)} { return "" }
    set n [lindex $a 0]; set q [expr {[llength $in] - $n}]
    set ce [lindex $in $q]
    if {[kd $ce] ne "L" || [lt $ce] eq ""} { return "" }
    if {[string trimleft [lindex $PI($P,lits) [lt $ce]] :] ni {variable upvar global}} { return "" }
    set st {}
    foreach e [lrange $in 0 [expr {$q-1}]] {
        switch [kd $e] { I - D - B - T { lappend st $e } L { lappend st B } default { return "" } }
    }
    lappend st B
    set nx $PI($P,next,$pc)
    set seen [dict create $nx 1]; set todo [list $nx]; set found 0
    while {[llength $todo] && !$found} {
        set c [lindex $todo end]; set todo [lrange $todo 0 end-1]
        if {$c in $PI($P,loopheads)} { set found 1; break }
        foreach t $PI($P,succ,$c) { if {![dict exists $seen $t]} { dict set seen $t 1; lappend todo $t } }
    }
    if {!$found} { return "" }
    return [list $nx $st]
}

# Instructions that take a tagged number (W) on the stack as it is; for any other instruction the W slots it consumes are made objects on the edge into it.
set wAware {add sub mult div mod lt le gt ge eq neq bitand bitor bitxor lshift rshift uminus uplus bitnot not jumpTrue1 jumpTrue4 jumpFalse1 jumpFalse4
    storeScalar1 storeScalar4 pop dup done incrScalar1}
proc wnorm {P out sop} {
    global PI wAware
    if {[lsearch -exact $out W] < 0} { return $out }
    lassign $PI($P,ins,$sop) op a
    if {$op in $wAware} { return $out }
    set n [llength $out]
    if {$op in {invokeStk1 invokeStk4}} {
        set ce [lindex $out [expr {$n - [lindex $a 0]}]]
        if {[kd $ce] eq "L" && [lt $ce] ne "" && [regexp {^(?:::)?tcl::mathfunc::(?:double|sqrt|sin|cos|tan|asin|acos|atan|atan2|sinh|cosh|tanh|exp|log|log10|fmod|hypot|floor|ceil|pow)$} [lindex $PI($P,lits) [lt $ce]]]} { return $out }
    }
    set pops [lindex [effect $op $a [llength $out] [lindex $PI($P,mk,$sop) end]] 0]
    for {set i [expr {max($n - $pops, 0)}]} {$i < $n} {incr i} { if {[kd [lindex $out $i]] eq "W"} { set out [lreplace $out $i $i B] } }
    return $out
}

# What a hand-over site is, for tbc::hot: "<kind> <op> <detail>" (kind: unsupported = typed code has no code for the instruction, guard = it hands over when a check
# fails; detail: the command a call instruction calls).  The text has no other spaces in its first two words.
proc siteInfo {P pc in kind} {
    global PI
    set op [lindex $PI($P,ins,$pc) 0]; set detail ""
    if {$op in {invokeStk1 invokeStk4}} {
        set nn [lindex $PI($P,ins,$pc) 1]; set ce [lindex $in [expr {[llength $in] - $nn}]]
        set detail [expr {[kd $ce] eq "L" ? [lindex $PI($P,lits) [lt $ce]] : "<dynamic>"}]
    } elseif {$op in {loadScalar1 loadScalar4 storeScalar1 storeScalar4 incrScalar1 incrScalar1Imm}} {
        set vi [operand [lindex $PI($P,ins,$pc) 1]]
        if {[string is integer -strict $vi] && $vi < [llength $PI($P,vnames)]} { set detail [lindex $PI($P,vnames) $vi] }
    }
    return "$kind $op [string map {{ } _} $detail]"
}

# TBC_REPORT=1: for every variant of every proc, how much of it runs as typed code and where it can hand over to the boxed code.  `unsupported` instructions are
# those typed code has no code for (they hand over every time they are reached: the first thing to look at); `guarded` ones hand over only when a check fails
# (an operand of another kind than the code assumes, an overflow, a variable with a trace); a guarded instruction is counted once however many checks it has.
proc variantReport {key P tpcs usedD dsiteVar} {
    global PI VK
    upvar $dsiteVar DS
    set uns {}; set guarded 0
    foreach pc $tpcs {
        lassign $DS($key,$pc) kind op detail
        if {$kind eq "unsupported"} { lappend uns [expr {$detail ne "" ? "$op $detail" : $op}]@$pc } elseif {[dict exists $usedD $pc]} { incr guarded }
    }
    set kinds {}
    dict for {v k} $VK($key,kap) { set vn [lindex $PI($P,vnames) $v]; if {$vn eq ""} { set vn "#$v" }; lappend kinds "$vn=$k" }
    return [list [llength $PI($P,reach)] [expr {[llength $tpcs] - [llength $uns]}] $guarded $uns $kinds $VK($key,ret)]
}

proc analyze {key} {
    global VK PI variants
    lassign [keysplit $key] P sig
    set ::curWpol [wpolK $key]
    set nvar [llength $PI($P,vnames)]
    set nbefore [llength $variants]
    set oldret $VK($key,ret)
    while 1 {
        array unset IN
        set IN(0) {}
        set work [list 0]
        set stores {}; set estores {}; set rets {}; set calls {}
        while {[llength $work]} {
            set pc [lindex $work end]; set work [lrange $work 0 end-1]
            set r [stepT $key $pc $IN($pc)]
            foreach s [dict get $r stores] { lappend stores $s }
            foreach s [dict get $r estores] { lappend estores $s }
            if {[dict get $r ret] ne ""} { lappend rets [dict get $r ret] }
            set flow [dict get $r flow]
            set out [dict get $r out]
            set succs {}
            # (a yield hands over to the boxed code and has no successor; the typed state after it, for the code that goes on when the coroutine is resumed, is a seed)
            if {[dict exists $r seed]} {
                lassign [dict get $r seed] sn sout
                if {![info exists IN($sn)]} { set IN($sn) $sout; lappend work $sn } else {
                    set j [jstate $IN($sn) $sout]
                    if {$j ne $IN($sn)} { set IN($sn) $j; lappend work $sn }
                }
            }
            # (an instruction that links variables of the frame by name hands over to the boxed code, which goes on until a loop head where typed code can be entered
            # again: typed code is analysed from the next instruction, as for a yield)
            if {$flow eq "dead" && ![dict exists $r seed]} {
                set sd [frameSeed $P $pc $IN($pc)]
                if {$sd ne ""} {
                    lassign $sd sn sout
                    if {![info exists IN($sn)]} { set IN($sn) $sout; lappend work $sn } else {
                        set j [jstate $IN($sn) $sout]
                        if {$j ne $IN($sn)} { set IN($sn) $j; lappend work $sn }
                    }
                }
            }
            switch $flow {
                fall { set succs [list $PI($P,next,$pc)] }
                jump { set succs [list [dict get $r tgt]] }
                cond { set succs [list $PI($P,next,$pc) [dict get $r tgt]] }
                multi { set succs [concat [dict get $r tgts] [list $PI($P,next,$pc)]] }
            }
            foreach s $succs {
                set outs $out
                if {$::curWpol} { set outs [wnorm $P $out $s] }
                if {![info exists IN($s)]} {
                    set IN($s) $outs; lappend work $s
                } else {
                    set j [jstate $IN($s) $outs]
                    if {$j ne $IN($s)} { set IN($s) $j; lappend work $s }
                }
            }
        }
        # variable kinds: join of everything stored
        set kap $VK($key,kap)
        set nk $kap
        foreach s $stores { lassign $s v k; dict set nk $v [jk [dict get $nk $v] $k] }
        foreach v [mustBoxOf $P] { if {[dict get $nk $v] in {I D A M W}} { dict set nk $v B } }
        foreach v [flaggedOf $P] { if {[dict get $nk $v] in {A M W}} { dict set nk $v B } }
        if {$PI($P,hasYield)} { dict for {v k} $nk { if {$k in {A M}} { dict set nk $v B } } }
        set ekap $VK($key,ekap)
        set nek $ekap
        foreach s $estores { lassign $s v k; dict set nek $v [jek [dict get $nek $v] $k] }
        if {$nk eq $kap && $nek eq $ekap} {
            set pending 0
            dict for {v k} $nk { if {$k eq "-"} { dict set nk $v B; set pending 1 } elseif {$k eq "S"} { dict set nk $v B; set pending 1 } }
            dict for {v k} $nek { if {$k eq "-"} { dict set nek $v B; set pending 1 } }
            if {!$pending} break
        }
        set VK($key,kap) $nk
        set VK($key,ekap) $nek
    }
    foreach k [array names VK [globEsc $key],in,*] { unset VK($k) }
    foreach k [array names IN] { set VK($key,in,$k) $IN($k) }
    set rk $VK($key,ret)
    foreach r $rets { set rk [jk $rk [expr {$r eq "L" ? "B" : $r}]] }
    if {$rk eq "W"} { set rk B }
    set VK($key,ret) $rk
    return [expr {$rk ne $oldret || [llength $variants] != $nbefore}]
}

# ================================================================== boxed (generic) code for one instruction
# labels for leaving an instruction abnormally: an error, or another result code (in rcg_).  Without exception ranges they are the
# stack-releasing chain; with ranges every instruction has its own stub that dispatches like the interpreter does.
proc hasRanges {P} { global PI; expr {[llength $PI($P,ranges)] > 0} }
proc errLabel {P pc d} { return GE$pc }
proc xLabel {P pc d} { return X$pc }

# flags of a store-like instruction
proc gStoreFlags {op} {
    if {[string match lappend* $op]} { return "TCL_LEAVE_ERR_MSG|TCL_APPEND_VALUE|TCL_LIST_ELEMENT" }
    if {[string match append* $op]} { return "TCL_LEAVE_ERR_MSG|TCL_APPEND_VALUE" }
    return TCL_LEAVE_ERR_MSG
}
# the instructions the bytecode executor implements as calls of a command that uses no variable: {number of stack operands, command, leading words,
# trailing words}.  Boxed code calls the command; typed code does the same with boxed operands (stepCmdOp).
proc cmdOpSpec {op a} {
    set nocase [expr {[lindex $a 0] ne "+0" && [lindex $a 0] ne "0"}]
    switch -- $op {
        listIn { return [list 2 ::tcl::mathop::in {} {}] }
        listNotIn { return [list 2 ::tcl::mathop::ni {} {}] }
        strindex { return [list 2 ::tcl::string::index {} {}] }
        strfind { return [list 2 ::tcl::string::first {} {}] }
        strrfind { return [list 2 ::tcl::string::last {} {}] }
        strrange { return [list 3 ::tcl::string::range {} {}] }
        strreplace { return [list 4 ::tcl::string::replace {} {}] }
        strcaseUpper { return [list 1 ::tcl::string::toupper {} {}] }
        strcaseLower { return [list 1 ::tcl::string::tolower {} {}] }
        strcaseTitle { return [list 1 ::tcl::string::totitle {} {}] }
        strtrim { return [list 2 ::tcl::string::trim {} {}] }
        strtrimLeft { return [list 2 ::tcl::string::trimleft {} {}] }
        strtrimRight { return [list 2 ::tcl::string::trimright {} {}] }
        strmatch { return [list 2 ::tcl::string::match [expr {$nocase ? {-nocase} : {}}] {}] }
        regexp { return [list 2 ::regexp [expr {$nocase ? {-nocase --} : {--}}] {}] }
        strrangeImm { return [list 1 ::tcl::string::range {} [list [string trimleft [lindex $a 0] .] [string trimleft [lindex $a 1] .]]] }
        listRangeImm { return [list 1 ::lrange {} [list [string trimleft [lindex $a 0] .] [string trimleft [lindex $a 1] .]]] }
        lindexMulti { return [list [lindex $a 0] ::lindex {} {}] }
    }
    return ""
}

# the one-byte-character fast path of string first / last / index / range in boxed code (see stepStrFast): the start of an if-statement whose else branch is the
# call of the command, or "" for any other instruction
proc gStrFast {d op a} {
    set q0 s[expr {$d-1}]
    switch $op {
        strfind - strrfind {
            set sa s[expr {$d-2}]; set sb s[expr {$d-1}]
            set fn [expr {$op eq "strfind" ? "tbc_s_first" : "tbc_s_last"}]
            return "\{ int64_t m_; if (${fn}($sa, $sb, &m_)) \{ Tcl_DecrRefCount($sa); Tcl_DecrRefCount($sb); $sa = tbc_newint(m_); \} "
        }
        strindex {
            set ss s[expr {$d-2}]; set si s[expr {$d-1}]
            return "\{ Tcl_Obj *r_; if (tbc_isint($si) && tbc_wide($si) == (int32_t) tbc_wide($si) && tbc_s_index($ss, tbc_wide($si), &r_)) \{ Tcl_DecrRefCount($ss); Tcl_DecrRefCount($si); $ss = r_; \} "
        }
        strrange {
            set ss s[expr {$d-3}]; set s1 s[expr {$d-2}]; set s2 s[expr {$d-1}]
            return "\{ Tcl_Obj *r_; if (tbc_isint($s1) && tbc_wide($s1) == (int32_t) tbc_wide($s1) && tbc_isint($s2) && tbc_wide($s2) == (int32_t) tbc_wide($s2) && tbc_s_range($ss, tbc_wide($s1), tbc_wide($s2), &r_)) \{ Tcl_DecrRefCount($ss); Tcl_DecrRefCount($s1); Tcl_DecrRefCount($s2); $ss = r_; \} "
        }
        strrangeImm {
            foreach w [list [lindex $a 0] [lindex $a 1]] { if {![regexp {^\.(-?\d+)$} $w -> v] || $v > 2147483647 || $v < -2147483648} { return "" } }
            regexp {^\.(-?\d+)$} [lindex $a 0] -> v1; regexp {^\.(-?\d+)$} [lindex $a 1] -> v2
            return "\{ Tcl_Obj *r_; if (tbc_s_range($q0, INT64_C($v1), INT64_C($v2), &r_)) \{ Tcl_DecrRefCount($q0); $q0 = r_; \} "
        }
    }
    return ""
}

# a command called in place of an instruction: the n topmost stack slots are its arguments (after the optional leading words pre and before the
# trailing words post, given as index strings), the result replaces them
proc gCmd {d n name nan {pre {}} {post {}}} {
    set slots {}; set rel ""
    foreach w $pre { lappend slots "TBC_NM([cstring $w])" }
    for {set k 0} {$k < $n} {incr k} { lappend slots s[expr {$d-$n+$k}]; append rel " Tcl_DecrRefCount(s[expr {$d-$n+$k}]);" }
    foreach w $post { lappend slots "TBC_NM([cstring $w])" }
    set e GE[set ::curpc]
    return "\{ Tcl_Obj *av_\[[expr {[llength $slots] + 1}]\] = { [join $slots {, }], NULL }, *r_; if (tbc_cmdcall(interp, TBC_NM([cstring $name]), [llength $slots], av_, $nan, &r_)) goto $e;$rel s[expr {$d-$n}] = r_; \}"
}

proc genG {key pc d} {
    global PI VK
    set ::curpc $pc
    lassign [keysplit $key] P sig
    lassign $PI($P,ins,$pc) op a
    set X [list @E@ [errLabel $P $pc $d] @X@ [xLabel $P $pc $d] @PC@ $pc @D@ $d @s1@ s[expr {$d-1}] @s2@ s[expr {$d-2}] @s3@ s[expr {$d-3}] @sn@ s$d @sn1@ s[expr {$d+1}] @sn2@ s[expr {$d+2}] @P@ [cident $P]]
    switch -- $op {
        nop - startCommand - beginCatch4 { return "" }
        endCatch { return "Tcl_ResetResult(interp); rcg_ = TCL_OK;" }
        tryCvtToNumeric { return [string map $X {if (tbc_trycvt(interp, &@s1@)) goto @E@;}] }
        push1 - push4 { return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {@sn@ = L_@P@_@N@; Tcl_IncrRefCount(@sn@);}] }
        pop { return [string map $X {Tcl_DecrRefCount(@s1@);}] }
        dup { return [string map $X {@sn@ = @s1@; Tcl_IncrRefCount(@sn@);}] }
        loadScalar1 - loadScalar4 {
            set n [operand [lindex $a 0]]
            return [string map [concat $X [list @N@ $n]] {{ Tcl_Obj *o_ = tbc_ld(interp, loc_, @N@); if (!o_) goto @E@; @sn@ = o_; Tcl_IncrRefCount(@sn@); }}]
        }
        storeScalar1 - storeScalar4 {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_setloc(interp, loc_, @N@, @s1@, TCL_LEAVE_ERR_MSG); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        incrScalar1Imm {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]] @IMM@ [lindex $a 1]]] {{ Tcl_Obj *r_ = tbc_incrimm(interp, loc_, @N@, @IMM@); if (!r_) goto @E@; @sn@ = r_; Tcl_IncrRefCount(@sn@); }}]
        }
        incrScalar1 {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_incrloc(interp, loc_, @N@, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        add - sub - mult - div - mod - lt - le - gt - ge - eq - neq {
            return [string map [concat $X [list @OP@ [dict get {add ADD sub SUB mult MULT div DIV mod MOD lt LT le LE gt GT ge GE eq EQ neq NEQ} $op]]] {if (tbc_bin_@OP@(interp, &@s2@, @s1@)) goto @E@;}]
        }
        jump1 - jump4 { return "goto G[operand [lindex $a 0]];" }
        jumpTrue1 - jumpTrue4 - jumpFalse1 - jumpFalse4 {
            set neg [expr {[string match jumpFalse* $op] ? "!" : ""}]
            return [string map [concat $X [list @TGT@ [operand [lindex $a 0]] @NEG@ $neg]] {{ int t_; if (tbc_truth(interp, @s1@, &t_) != TCL_OK) goto @E@; Tcl_DecrRefCount(@s1@); if (@NEG@t_) goto G@TGT@; }}]
        }
        done {
            set rel ""
            for {set k [expr {$d-2}]} {$k >= 0} {incr k -1} { append rel " Tcl_DecrRefCount(s$k);" }
            return "Tcl_SetObjResult(interp, s[expr {$d-1}]); Tcl_DecrRefCount(s[expr {$d-1}]);$rel goto gok;"
        }
        invokeStk1 - invokeStk4 {
            set n [lindex $a 0]; set slots {}; set rel ""
            for {set k 0} {$k < $n} {incr k} { lappend slots s[expr {$d-$n+$k}]; append rel " Tcl_DecrRefCount(s[expr {$d-$n+$k}]);" }
            return "\{ Tcl_Obj *ov_\[\] = { [join $slots {, }] }; int r_; tbc_setpc(interp, $pc); r_ = Tcl_EvalObjv(interp, $n, ov_, TBC_EV); rcg_ = r_; if (r_ != TCL_OK) \{ goto [xLabel $P $pc $d]; \}$rel s[expr {$d-$n}] = tbc_takeres(interp); \}"
        }
        strcat {
            set n [lindex $a 0]; set slots {}; set rel ""
            for {set k 0} {$k < $n} {incr k} { lappend slots s[expr {$d-$n+$k}]; append rel " Tcl_DecrRefCount(s[expr {$d-$n+$k}]);" }
            return "\{ Tcl_Obj *ov_\[\] = { [join $slots {, }] }; Tcl_Obj *r_ = tbc_concat($n, ov_);$rel s[expr {$d-$n}] = r_; \}"
        }
        strlen { return [string map $X {{ Tcl_Obj *r_ = Tcl_NewWideIntObj(Tcl_GetCharLength(@s1@)); Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}] }
        reverse {
            set n [lindex $a 0]; set c ""
            for {set k 0} {$k < $n/2} {incr k} { append c "\{ Tcl_Obj *t_ = s[expr {$d-$n+$k}]; s[expr {$d-$n+$k}] = s[expr {$d-1-$k}]; s[expr {$d-1-$k}] = t_; \} " }
            return $c
        }
        appendScalar1 - appendScalar4 {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_setloc(interp, loc_, @N@, @s1@, TCL_LEAVE_ERR_MSG|TCL_APPEND_VALUE); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        listIndexImm {
            regexp {^\.(-?\d+|end)(?:-(\d+))?$} [lindex $a 0] -> ix kk
            set call [expr {$ix eq "end" ? "tbc_lindex_end(interp, @s1@, [expr {$kk eq "" ? 0 : $kk}])" : "tbc_lindex_i(interp, @s1@, $ix)"}]
            return [string map $X "\{ Tcl_Obj *r_ = $call; if (!r_) goto @E@; Tcl_DecrRefCount(@s1@); @s1@ = r_; \}"]
        }
        listLength { return [string map $X {{ int n_; if (Tcl_ListObjLength(interp, @s1@, &n_) != TCL_OK) goto @E@; Tcl_DecrRefCount(@s1@); @s1@ = tbc_newint(n_); }}] }
        list {
            set n [lindex $a 0]; set slots {}; set rel ""
            for {set k 0} {$k < $n} {incr k} { lappend slots s[expr {$d-$n+$k}]; append rel " Tcl_DecrRefCount(s[expr {$d-$n+$k}]);" }
            return "\{ Tcl_Obj *ov_\[\] = { [join $slots {, }] }; Tcl_Obj *r_ = Tcl_NewListObj($n, ov_); Tcl_IncrRefCount(r_);$rel s[expr {$d-$n}] = r_; \}"
        }
        listIndex { return [string map $X {{ Tcl_Obj *r_ = tbc_lindex(interp, @s2@, @s1@); if (!r_) goto @E@; Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}] }
        lsetList { return [string map $X {{ Tcl_Obj *lst_ = @s1@, *r_; Tcl_DecrRefCount(lst_); r_ = TclLsetList(interp, lst_, @s3@, @s2@); if (!r_) { Tcl_IncrRefCount(lst_); goto @E@; } Tcl_DecrRefCount(@s2@); Tcl_DecrRefCount(@s3@); @s3@ = r_; }}] }
        dictGet - dictExists {
            set n [lindex $a 0]
            if {$n == 1} {
                if {$op eq "dictGet"} { return [string map $X {{ Tcl_Obj *v_ = NULL; if (Tcl_DictObjGet(interp, @s2@, @s1@, &v_) != TCL_OK) goto @E@; if (!v_) { tbc_dict_nokey(interp, @s1@); goto @E@; } Tcl_IncrRefCount(v_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = v_; }}] }
                return [string map $X {{ Tcl_Obj *v_ = NULL; int f_ = (Tcl_DictObjGet(NULL, @s2@, @s1@, &v_) == TCL_OK && v_ != NULL); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = f_ ? tbcOne : tbcZero; Tcl_IncrRefCount(@s2@); }}]
            }
            set base [expr {$d - $n - 1}]
            set keys {}; for {set k 1} {$k <= $n} {incr k} { lappend keys s[expr {$base + $k}] }
            set rel ""; for {set k [expr {$d-1}]} {$k >= $base} {incr k -1} { append rel " Tcl_DecrRefCount(s$k);" }
            if {$op eq "dictGet"} {
                return "\{ Tcl_Obj *kv_\[\] = { [join $keys {, }], NULL }, *r_; int f_; r_ = tbc_dictpath(interp, s$base, $n, kv_, 0, &f_); if (!r_) goto [errLabel $P $pc $d]; Tcl_IncrRefCount(r_);$rel s$base = r_; \}"
            }
            return "\{ Tcl_Obj *kv_\[\] = { [join $keys {, }], NULL }; int f_ = 0; (void) tbc_dictpath(interp, s$base, $n, kv_, 1, &f_);$rel s$base = f_ ? tbcOne : tbcZero; Tcl_IncrRefCount(s$base); \}"
        }
        lappendScalar1 - lappendScalar4 {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_setloc(interp, loc_, @N@, @s1@, TCL_LEAVE_ERR_MSG|TCL_APPEND_VALUE|TCL_LIST_ELEMENT); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        dictIncrImm {
            return [string map [concat $X [list @IMM@ [lindex $a 0] @N@ [operand [lindex $a 1]]]] {{ Tcl_Obj *r_ = tbc_dictincr_var(interp, loc_, @N@, @s1@, @IMM@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        verifyDict { return [string map $X {{ int n_; if (Tcl_DictObjSize(interp, @s1@, &n_) != TCL_OK) goto @E@; Tcl_DecrRefCount(@s1@); }}] }
        dictFirst {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *k_, *v_; int dn_; if (dd@N@) { Tcl_DictObjDone(&ds@N@); Tcl_DecrRefCount(dd@N@); dd@N@ = NULL; } if (Tcl_DictObjFirst(interp, @s1@, &ds@N@, &k_, &v_, &dn_) != TCL_OK) goto @E@; dd@N@ = @s1@; if (dn_) k_ = v_ = tbcEmpty; @s1@ = v_; Tcl_IncrRefCount(@s1@); @sn@ = k_; Tcl_IncrRefCount(@sn@); @sn1@ = dn_ ? tbcOne : tbcZero; Tcl_IncrRefCount(@sn1@); }}]
        }
        dictNext {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *k_, *v_; int dn_; Tcl_DictObjNext(&ds@N@, &k_, &v_, &dn_); if (dn_) k_ = v_ = tbcEmpty; @sn@ = v_; Tcl_IncrRefCount(@sn@); @sn1@ = k_; Tcl_IncrRefCount(@sn1@); @sn2@ = dn_ ? tbcOne : tbcZero; Tcl_IncrRefCount(@sn2@); }}]
        }
        unsetScalar {
            set n [operand [lindex $a 1]]
            if {$n in $PI($P,iters)} { return "if (dd$n) \{ Tcl_DictObjDone(&ds$n); Tcl_DecrRefCount(dd$n); dd$n = NULL; \}" }
            return [string map [concat $X [list @N@ $n @FL@ [lindex $a 0]]] {if (tbc_unsetloc(interp, loc_, @N@, @FL@)) goto @E@;}]
        }
        expandStart {
            set L [llength $PI($P,mk,$pc)]
            return "if (ex${L}_) Tcl_DecrRefCount(ex${L}_); ex${L}_ = Tcl_NewListObj(0, NULL); Tcl_IncrRefCount(ex${L}_);"
        }
        expandStkTop {
            set L [expr {[llength $PI($P,mk,$pc)] - 1}]; set d0 [lindex $PI($P,mk,$pc) end]
            set c "\{ int oc_, i_; Tcl_Obj **ov_; if (TclListObjGetElements(interp, s[expr {$d-1}], &oc_, &ov_) != TCL_OK) goto [errLabel $P $pc $d];"
            for {set k $d0} {$k < $d-1} {incr k} { append c " Tcl_ListObjAppendElement(NULL, ex${L}_, s$k); Tcl_DecrRefCount(s$k);" }
            append c " for (i_ = 0; i_ < oc_; i_++) Tcl_ListObjAppendElement(NULL, ex${L}_, ov_\[i_\]); Tcl_DecrRefCount(s[expr {$d-1}]); \}"
            return $c
        }
        invokeExpanded {
            set L [expr {[llength $PI($P,mk,$pc)] - 1}]; set d0 [lindex $PI($P,mk,$pc) end]
            set c "\{ int oc_, r_; Tcl_Obj **ov_;"
            for {set k $d0} {$k < $d} {incr k} { append c " Tcl_ListObjAppendElement(NULL, ex${L}_, s$k);" }
            append c " Tcl_ListObjGetElements(NULL, ex${L}_, &oc_, &ov_); if (oc_ == 0) \{ s$d0 = Tcl_NewObj(); Tcl_IncrRefCount(s$d0); \} else \{ tbc_setpc(interp, $pc); r_ = Tcl_EvalObjv(interp, oc_, ov_, TBC_EV); rcg_ = r_; if (r_ != TCL_OK) goto [xLabel $P $pc $d];"
            for {set k [expr {$d-1}]} {$k >= $d0} {incr k -1} { append c " Tcl_DecrRefCount(s$k);" }
            append c " s$d0 = tbc_takeres(interp); \} \}"
            return $c
        }
        expandDrop {
            set d0 [lindex $PI($P,mk,$pc) end]
            set c ""
            for {set k [expr {$d-1}]} {$k >= $d0} {incr k -1} { append c "Tcl_DecrRefCount(s$k); " }
            return $c
        }
        invokeReplace {
            lassign $a objc opnd
            set base [expr {$d - 1 - $objc}]
            set words {}; for {set k 0} {$k < $objc} {incr k} { lappend words s[expr {$base + $k}] }
            set rel ""; for {set k [expr {$d-1}]} {$k >= $base} {incr k -1} { append rel " Tcl_DecrRefCount(s$k);" }
            return "\{ Tcl_Obj *wv_\[\] = { [join $words {, }], NULL }, *cp_, **cv_; int cn_, r_; cp_ = Tcl_NewListObj(0, NULL); Tcl_IncrRefCount(cp_); Tcl_ListObjAppendElement(NULL, cp_, s[expr {$d-1}]); Tcl_ListObjReplace(NULL, cp_, LIST_MAX, 0, $objc - $opnd, wv_ + $opnd); tbc_setpc(interp, $pc); TclInitRewriteEnsemble(interp, $opnd, 1, wv_); TclMarkTailcall(interp); Tcl_ListObjGetElements(NULL, cp_, &cn_, &cv_); r_ = Tcl_EvalObjv(interp, cn_, cv_, TCL_EVAL_INVOKE); TclClearRootEnsemble(NULL, interp, r_); Tcl_DecrRefCount(cp_); rcg_ = r_; if (r_ != TCL_OK) goto [xLabel $P $pc $d];$rel s$base = tbc_takeres(interp); \}"
        }
        dictSet - dictUnset {
            set nk [lindex $a 0]; set v [operand [lindex $a 1]]
            set mode [expr {$op eq "dictSet" ? 0 : 1}]
            set base [expr {$d - $nk - ($op eq "dictSet" ? 1 : 0)}]
            set keys {}; for {set k 0} {$k < $nk} {incr k} { lappend keys s[expr {$base + $k}] }
            set val [expr {$op eq "dictSet" ? "s[expr {$d-1}]" : "NULL"}]
            set rel ""; for {set k [expr {$d-1}]} {$k >= $base} {incr k -1} { append rel " Tcl_DecrRefCount(s$k);" }
            return "\{ Tcl_Obj *kv_\[\] = { [join $keys {, }], NULL }, *r_ = tbc_dictmod(interp, loc_, $v, $mode, $nk, kv_, $val); if (!r_) goto [errLabel $P $pc $d]; Tcl_IncrRefCount(r_);$rel s$base = r_; \}"
        }
        dictAppend - dictLappend {
            set v [operand [lindex $a 0]]
            set mode [expr {$op eq "dictAppend" ? 2 : 3}]
            return [string map [concat $X [list @V@ $v @M@ $mode]] {{ Tcl_Obj *kv_[] = { @s2@, NULL }, *r_ = tbc_dictmod(interp, loc_, @V@, @M@, 1, kv_, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        arrayMakeImm { return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {if (tbc_arrmake(interp, loc_, @N@, NULL)) goto @E@;}] }
        arrayMakeStk { return [string map $X {if (tbc_arrmake(interp, loc_, -1, @s1@)) goto @E@; Tcl_DecrRefCount(@s1@);}] }
        exprStk {
            return [string map $X {{ Tcl_Obj *r_; tbc_setpc(interp, @PC@); if (Tcl_ExprObj(interp, @s1@, &r_) != TCL_OK) goto @E@; Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        tryCvtToBoolean {
            return [string map $X {@sn@ = (@s1@->typePtr == &tclBooleanType || TclSetBooleanFromAny(NULL, @s1@) == TCL_OK) ? tbcOne : tbcZero; Tcl_IncrRefCount(@sn@);}]
        }
        numericType { return [string map $X {{ Tcl_Obj *r_ = tbc_newint(tbc_numtype(@s1@)); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}] }
        clockRead { return [string map [concat $X [list @W@ [lindex $a 0]]] {@sn@ = Tcl_NewWideIntObj(tbc_clock(@W@)); Tcl_IncrRefCount(@sn@);}] }
        resolveCmd {
            return [string map $X {{ Tcl_Command cmd_ = Tcl_GetCommandFromObj(interp, @s1@); Tcl_Obj *r_ = Tcl_NewObj(); if (cmd_ != NULL) Tcl_GetCommandFullName(interp, cmd_, r_); Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        originCmd {
            return [string map $X {{ Tcl_Command cmd_ = Tcl_GetCommandFromObj(interp, @s1@), orig_; Tcl_Obj *r_; if (cmd_ == NULL) { Tcl_SetObjResult(interp, Tcl_ObjPrintf("invalid command name \"%s\"", Tcl_GetString(@s1@))); Tcl_SetErrorCode(interp, "TCL", "LOOKUP", "COMMAND", Tcl_GetString(@s1@), NULL); goto @E@; } orig_ = TclGetOriginalCommand(cmd_); if (orig_ == NULL) orig_ = cmd_; r_ = Tcl_NewObj(); Tcl_GetCommandFullName(interp, orig_, r_); Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        evalStk {
            return [string map $X {{ tbc_setpc(interp, @PC@); NRE_callback *root_ = TOP_CB(interp); ByteCode *bc_ = TclCompileObj(interp, @s1@, NULL, 0); int r_ = TclNRRunCallbacks(interp, TclNRExecuteByteCode(interp, bc_), root_); rcg_ = r_; if (r_ != TCL_OK) goto @X@; Tcl_DecrRefCount(@s1@); @s1@ = tbc_takeres(interp); }}]
        }
        coroName {
            return [string map $X {{ CoroutineData *cp_ = ((Interp *) interp)->execEnvPtr->corPtr; Tcl_Obj *r_ = Tcl_NewObj(); if (cp_ && !(cp_->cmdPtr->flags & CMD_IS_DELETED)) Tcl_GetCommandFullName(interp, (Tcl_Command) cp_->cmdPtr, r_); Tcl_IncrRefCount(r_); @sn@ = r_; }}]
        }
        dictExpand {
            return [string map $X {{ int oc_; Tcl_Obj **ov_, *r_; if (TclListObjGetElements(interp, @s1@, &oc_, &ov_) != TCL_OK) goto @E@; r_ = TclDictWithInit(interp, @s2@, oc_, ov_); if (r_ == NULL) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        dictRecombineImm {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ int oc_; Tcl_Obj **ov_; Var *vp_ = &loc_[@N@]; if (TclListObjGetElements(interp, @s2@, &oc_, &ov_) != TCL_OK) goto @E@; TBC_FOLLOW(vp_); if (TclDictWithFinish(interp, vp_, NULL, NULL, NULL, @N@, oc_, ov_, @s1@) != TCL_OK) goto @E@; Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); }}]
        }
        dictRecombineStk {
            return [string map $X {{ int oc_, r_; Tcl_Obj **ov_; Var *vp_, *ap_ = NULL; if (TclListObjGetElements(interp, @s2@, &oc_, &ov_) != TCL_OK) goto @E@; vp_ = TclObjLookupVarEx(interp, @s3@, NULL, TCL_LEAVE_ERR_MSG, "set", 1, 1, &ap_); if (vp_ == NULL) goto @E@; r_ = TclDictWithFinish(interp, vp_, ap_, @s3@, NULL, -1, oc_, ov_, @s1@); if (r_ != TCL_OK) goto @E@; Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); Tcl_DecrRefCount(@s3@); }}]
        }
        dictUpdateStart {
            lassign $a var n vars
            return [string map [concat $X [list @N@ [operand $var] @NV@ [llength $vars] @VI@ [join $vars {, }]]] {{ static const int vi_[] = { @VI@ }; if (tbc_dupstart(interp, loc_, @N@, vi_, @NV@, @s1@)) goto @E@; }}]
        }
        dictUpdateEnd {
            lassign $a var n vars
            return [string map [concat $X [list @N@ [operand $var] @NV@ [llength $vars] @VI@ [join $vars {, }]]] {{ static const int vi_[] = { @VI@ }; if (tbc_dupend(interp, loc_, @N@, vi_, @s1@)) goto @E@; Tcl_DecrRefCount(@s1@); }}]
        }
        yield - yieldToInvoke {
            set below {}
            for {set k 0} {$k < $d - 1} {incr k} { lappend below s$k }
            set nx $PI($P,next,$pc)
            if {$op eq "yield"} {
                set what "yield"; set typ NULL
                set setup "Tcl_SetObjResult(interp, @s1@); Tcl_DecrRefCount(@s1@);"
            } else {
                set what "yieldto"; set typ "INT2PTR(1)"
                set setup "if (((Namespace *) TclGetCurrentNamespace(interp))->flags & NS_DYING) { Tcl_SetObjResult(interp, Tcl_NewStringObj(\"yieldto called in deleted namespace\", -1)); Tcl_SetErrorCode(interp, \"TCL\", \"COROUTINE\", \"YIELDTO_IN_DELETED\", NULL); goto @E@; } Tcl_IncrRefCount(@s1@); ((Interp *) interp)->execEnvPtr = cp_->callerEEPtr; TclSetTailcall(interp, @s1@); ((Interp *) interp)->execEnvPtr = cp_->eePtr; Tcl_DecrRefCount(@s1@);"
            }
            return [string map [concat $X [list @PC@ $pc]] "\{ CoroutineData *cp_ = ((Interp *) interp)->execEnvPtr->corPtr; if (!cp_) \{ Tcl_SetObjResult(interp, Tcl_NewStringObj(\"$what can only be called in a coroutine\", -1)); Tcl_SetErrorCode(interp, \"TCL\", \"COROUTINE\", \"ILLEGAL_YIELD\", NULL); goto @E@; \} $setup \{ Tcl_Obj *bl_\[\] = { [join [concat $below NULL] {, }] }; tbc_setpc(interp, @PC@); tbc_do_yield(interp, tbc_yres_[cident $P], $nx, [expr {$d - 1}], bl_, $typ); \} rcg_ = TCL_OK; goto gexit; \}"]
        }
        tailcall {
            set n [lindex $a 0]
            set slots {}; set rel ""
            for {set k 0} {$k < $n} {incr k} { lappend slots s[expr {$d-$n+$k}]; append rel " Tcl_DecrRefCount(s[expr {$d-$n+$k}]);" }
            return [string map $X "\{ Interp *ip_ = (Interp *) interp; Tcl_Obj *ov_\[\] = { [join $slots {, }] }, *lp_, *nso_; if (!(ip_->varFramePtr->isProcCallFrame & 1)) \{ Tcl_SetObjResult(interp, Tcl_NewStringObj(\"tailcall can only be called from a proc or lambda\", -1)); Tcl_SetErrorCode(interp, \"TCL\", \"TAILCALL\", \"ILLEGAL\", NULL); goto @E@; \} lp_ = Tcl_NewListObj($n, ov_); nso_ = Tcl_NewStringObj(ip_->varFramePtr->nsPtr->fullName, -1); TclListObjSetElement(interp, lp_, 0, nso_); if (ip_->varFramePtr->tailcallPtr) Tcl_DecrRefCount(ip_->varFramePtr->tailcallPtr); ip_->varFramePtr->tailcallPtr = lp_; rcg_ = TCL_RETURN; goto @X@; \}"]
        }
        over { return "s$d = s[expr {$d - 1 - [operand [lindex $a 0]]}]; Tcl_IncrRefCount(s$d);" }
        streq - strneq {
            set inv [expr {$op eq "strneq" ? "!" : ""}]
            return [string map [concat $X [list @INV@ $inv]] {{ Tcl_Obj *r_ = @INV@(TclStringCmp(@s2@, @s1@, 1, 0, -1) == 0) ? tbcOne : tbcZero; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        strcmp {
            return [string map $X {{ int m_ = TclStringCmp(@s2@, @s1@, 0, 0, -1); Tcl_Obj *r_ = tbc_newint(m_ < 0 ? -1 : m_ > 0 ? 1 : 0); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        strclass {
            set n [lsearch -exact {alnum alpha ascii control digit graph lower print punct space upper word xdigit} [string trimleft [lindex $a 0] =]]
            if {$n < 0} { refuse "string class [lindex $a 0]" }
            return [string map [concat $X [list @N@ $n]] {{ int ll_, m_ = 1; const Tcl_UniChar *u_ = Tcl_GetUnicodeFromObj(@s1@, &ll_); if (ll_ > 0) { const Tcl_UniChar *p_, *e_ = u_ + ll_; for (p_ = u_; p_ < e_; ) { int ch_; p_ += TclUniCharToUCS4(p_, &ch_); if (!tclStringClassTable[@N@].comparator(ch_)) { m_ = 0; break; } } } Tcl_DecrRefCount(@s1@); @s1@ = m_ ? tbcOne : tbcZero; Tcl_IncrRefCount(@s1@); }}]
        }
        uminus - uplus - not - bitnot {
            return [string map [concat $X [list @OP@ [dict get {uminus NEG uplus POS not LNOT bitnot BNOT} $op]]] {if (tbc_un(interp, TBC_@OP@, &@s1@)) goto @E@;}]
        }
        bitand - bitor - bitxor - lshift - rshift - expon {
            return [string map [concat $X [list @OP@ [dict get {bitand BAND bitor BOR bitxor BXOR lshift SHL rshift SHR expon POW} $op]]] {if (tbc_bin_@OP@(interp, &@s2@, @s1@)) goto @E@;}]
        }
        listIn - listNotIn - strindex - strfind - strrfind - strrange - strreplace - strcaseUpper - strcaseLower - strcaseTitle - strtrim - strtrimLeft -
        strtrimRight - strmatch - regexp - strrangeImm - listRangeImm - lindexMulti {
            lassign [cmdOpSpec $op $a] n name pre post
            if {$op eq "regexp"} {
                set sp s[expr {$d-2}]; set ss s[expr {$d-1}]
                return "\{ int m_ = 0; if (tbc_s_regexp(interp, $ss, $sp, [expr {[lindex $a 0]}], &m_)) goto GE[set ::curpc]; Tcl_DecrRefCount($sp); Tcl_DecrRefCount($ss); $sp = tbc_newint(m_); \}"
            }
            if {$op eq "strmatch"} {
                set nocase [expr {[lindex $a 0] ne "+0" && [lindex $a 0] ne "0"}]
                set sp s[expr {$d-2}]; set ss s[expr {$d-1}]
                return "\{ int m_ = tbc_s_match($ss, $sp, $nocase); Tcl_DecrRefCount($sp); Tcl_DecrRefCount($ss); $sp = tbc_newint(m_); \}"
            }
            set fast [gStrFast $d $op $a]
            if {$fast ne ""} { return "$fast else [gCmd $d $n $name 0 $pre $post] \}" }
            return [gCmd $d $n $name 0 $pre $post]
        }
        concatStk {
            set n [lindex $a 0]; set slots {}; set rel ""
            for {set k 0} {$k < $n} {incr k} { lappend slots s[expr {$d-$n+$k}]; append rel " Tcl_DecrRefCount(s[expr {$d-$n+$k}]);" }
            return "\{ Tcl_Obj *ov_\[\] = { [join $slots {, }] }; Tcl_Obj *r_ = Tcl_ConcatObj($n, ov_); Tcl_IncrRefCount(r_);$rel s[expr {$d-$n}] = r_; \}"
        }
        strmap {
            return [string map $X {{ Tcl_Obj *mv_[2] = { @s3@, @s2@ }, *r_, *m_, *av_[2]; int e_; m_ = Tcl_NewListObj(2, mv_); Tcl_IncrRefCount(m_); av_[0] = m_; av_[1] = @s1@; e_ = tbc_cmdcall(interp, TBC_NM("::tcl::string::map"), 2, av_, 0, &r_); Tcl_DecrRefCount(m_); if (e_) goto @E@; Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); Tcl_DecrRefCount(@s3@); @s3@ = r_; }}]
        }
        listConcat {
            return [string map $X {{ Tcl_Obj *r_; if (Tcl_IsShared(@s2@)) { r_ = Tcl_DuplicateObj(@s2@); Tcl_IncrRefCount(r_); if (Tcl_ListObjAppendList(interp, r_, @s1@) != TCL_OK) { Tcl_DecrRefCount(r_); goto @E@; } Tcl_DecrRefCount(@s2@); @s2@ = r_; } else { if (Tcl_ListObjAppendList(interp, @s2@, @s1@) != TCL_OK) goto @E@; } Tcl_DecrRefCount(@s1@); }}]
        }
        lsetFlat {
            set n [expr {[lindex $a 0] - 2}]
            set lst "s[expr {$d-1}]"; set val "s[expr {$d-2}]"; set idx0 [expr {$d-2-$n}]
            set c "\{ Tcl_Obj *lst_ = $lst, *r_, *iv_\[[expr {$n + 1}]\] = {"
            for {set k 0} {$k < $n} {incr k} { append c " s[expr {$idx0+$k}]," }
            append c " NULL }; Tcl_DecrRefCount(lst_); r_ = TclLsetFlat(interp, lst_, $n, iv_, $val); if (!r_) \{ Tcl_IncrRefCount(lst_); goto [errLabel $P $pc $d]; \}"
            for {set k [expr {$d-2}]} {$k >= $idx0} {incr k -1} { append c " Tcl_DecrRefCount(s$k);" }
            append c " s$idx0 = r_; \}"
            return $c
        }
        jumpTable {
            lassign $a n tgts map
            set c "\{ int kl_; const char *k_ = Tcl_GetStringFromObj(@s1@, &kl_);"
            foreach {key off} $map {
                set u [expr {$pc + $off}]
                append c " if (kl_ == [cbytes $key] && !memcmp(k_, [cstring $key], kl_)) \{ Tcl_DecrRefCount(@s1@); goto G$u; \}"
            }
            append c " Tcl_DecrRefCount(@s1@); \}"
            return [string map $X $c]
        }
        infoLevelNumber { return [string map $X {@sn@ = tbc_newint(((Interp *) interp)->varFramePtr->level);}] }
        infoLevelArgs {
            return [string map $X {{ int level_; CallFrame *fp_ = ((Interp *) interp)->varFramePtr, *rf_ = ((Interp *) interp)->rootFramePtr; Tcl_Obj *r_;
                if (TclGetIntFromObj(interp, @s1@, &level_) != TCL_OK) goto @E@;
                if (level_ <= 0) level_ += fp_->level;
                for (; fp_->level != level_ && fp_ != rf_; fp_ = fp_->callerVarPtr) {}
                if (fp_ == rf_) { Tcl_SetObjResult(interp, Tcl_ObjPrintf("bad level \"%s\"", Tcl_GetString(@s1@))); Tcl_SetErrorCode(interp, "TCL", "LOOKUP", "STACK_LEVEL", Tcl_GetString(@s1@), NULL); goto @E@; }
                r_ = Tcl_NewListObj(fp_->objc, fp_->objv); Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        currentNamespace {
            return [string map $X {{ Namespace *ns_ = (Namespace *) TclGetCurrentNamespace(interp); @sn@ = (ns_ == (Namespace *) TclGetGlobalNamespace(interp)) ? Tcl_NewStringObj("::", 2) : Tcl_NewStringObj(ns_->fullName, (int) strlen(ns_->fullName)); Tcl_IncrRefCount(@sn@); }}]
        }
        loadArray1 - loadArray4 {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_vload(interp, loc_, @N@, NULL, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        loadArrayStk {
            return [string map $X {{ Tcl_Obj *r_ = tbc_vload(interp, loc_, -1, @s2@, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        loadStk - loadScalarStk {
            return [string map $X {{ Tcl_Obj *r_ = tbc_vload(interp, loc_, -1, @s1@, NULL); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        storeArray1 - storeArray4 - appendArray1 - appendArray4 - lappendArray1 - lappendArray4 {
            set fl [gStoreFlags $op]
            return [string map [concat $X [list @N@ [operand [lindex $a 0]] @FL@ $fl]] {{ Tcl_Obj *r_ = tbc_vstore(interp, loc_, @N@, NULL, @s2@, @s1@, @FL@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        storeArrayStk - appendArrayStk - lappendArrayStk {
            set fl [gStoreFlags $op]
            return [string map [concat $X [list @FL@ $fl]] {{ Tcl_Obj *r_ = tbc_vstore(interp, loc_, -1, @s3@, @s2@, @s1@, @FL@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); Tcl_DecrRefCount(@s3@); @s3@ = r_; }}]
        }
        storeStk - storeScalarStk - appendStk - lappendStk {
            set fl [gStoreFlags $op]
            return [string map [concat $X [list @FL@ $fl]] {{ Tcl_Obj *r_ = tbc_vstore(interp, loc_, -1, @s2@, NULL, @s1@, @FL@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        incrArray1 {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_vincr(interp, loc_, @N@, NULL, @s2@, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        incrArray1Imm {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]] @IMM@ [lindex $a 1]]] {{ Tcl_Obj *i_ = tbc_newint(@IMM@), *r_ = tbc_vincr(interp, loc_, @N@, NULL, @s1@, i_); Tcl_DecrRefCount(i_); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        incrArrayStk {
            return [string map $X {{ Tcl_Obj *r_ = tbc_vincr(interp, loc_, -1, @s3@, @s2@, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); Tcl_DecrRefCount(@s3@); @s3@ = r_; }}]
        }
        incrArrayStkImm {
            return [string map [concat $X [list @IMM@ [lindex $a 0]]] {{ Tcl_Obj *i_ = tbc_newint(@IMM@), *r_ = tbc_vincr(interp, loc_, -1, @s2@, @s1@, i_); Tcl_DecrRefCount(i_); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        incrStk - incrScalarStk {
            return [string map $X {{ Tcl_Obj *r_ = tbc_vincr(interp, loc_, -1, @s2@, NULL, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        incrStkImm - incrScalarStkImm {
            return [string map [concat $X [list @IMM@ [lindex $a 0]]] {{ Tcl_Obj *i_ = tbc_newint(@IMM@), *r_ = tbc_vincr(interp, loc_, -1, @s1@, NULL, i_); Tcl_DecrRefCount(i_); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        lappendList {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_vlappend(interp, loc_, @N@, 0, NULL, NULL, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        lappendListArray {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_vlappend(interp, loc_, @N@, 1, NULL, @s2@, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        lappendListStk {
            return [string map $X {{ Tcl_Obj *r_ = tbc_vlappend(interp, loc_, -1, 0, @s2@, NULL, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        lappendListArrayStk {
            return [string map $X {{ Tcl_Obj *r_ = tbc_vlappend(interp, loc_, -1, 0, @s3@, @s2@, @s1@); if (!r_) goto @E@; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); Tcl_DecrRefCount(@s3@); @s3@ = r_; }}]
        }
        existScalar {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ @sn@ = tbc_vexist(interp, loc_, @N@, NULL, NULL) ? tbcOne : tbcZero; Tcl_IncrRefCount(@sn@); }}]
        }
        existArray {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ Tcl_Obj *r_ = tbc_vexist(interp, loc_, @N@, NULL, @s1@) ? tbcOne : tbcZero; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        existArrayStk {
            return [string map $X {{ Tcl_Obj *r_ = tbc_vexist(interp, loc_, -1, @s2@, @s1@) ? tbcOne : tbcZero; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@); @s2@ = r_; }}]
        }
        existStk {
            return [string map $X {{ Tcl_Obj *r_ = tbc_vexist(interp, loc_, -1, @s1@, NULL) ? tbcOne : tbcZero; Tcl_IncrRefCount(r_); Tcl_DecrRefCount(@s1@); @s1@ = r_; }}]
        }
        unsetArray {
            return [string map [concat $X [list @FL@ [expr {[lindex $a 0] ? "TCL_LEAVE_ERR_MSG" : "0"}] @N@ [operand [lindex $a 1]]]] {if (tbc_vunset(interp, loc_, @N@, NULL, @s1@, @FL@)) goto @E@; Tcl_DecrRefCount(@s1@);}]
        }
        unsetArrayStk {
            return [string map [concat $X [list @FL@ [expr {[lindex $a 0] ? "TCL_LEAVE_ERR_MSG" : "0"}]]] {if (tbc_vunset(interp, loc_, -1, @s2@, @s1@, @FL@)) goto @E@; Tcl_DecrRefCount(@s1@); Tcl_DecrRefCount(@s2@);}]
        }
        unsetStk {
            return [string map [concat $X [list @FL@ [expr {[lindex $a 0] ? "TCL_LEAVE_ERR_MSG" : "0"}]]] {if (tbc_vunset(interp, loc_, -1, @s1@, NULL, @FL@)) goto @E@; Tcl_DecrRefCount(@s1@);}]
        }
        arrayExistsImm {
            return [string map [concat $X [list @N@ [operand [lindex $a 0]]]] {{ int r_ = tbc_arrexists(interp, loc_, @N@, NULL); if (r_ < 0) goto @E@; @sn@ = r_ ? tbcOne : tbcZero; Tcl_IncrRefCount(@sn@); }}]
        }
        arrayExistsStk {
            return [string map $X {{ int r_ = tbc_arrexists(interp, loc_, -1, @s1@); if (r_ < 0) goto @E@; Tcl_DecrRefCount(@s1@); @s1@ = r_ ? tbcOne : tbcZero; Tcl_IncrRefCount(@s1@); }}]
        }
        lmap_collect {
            # lmap: the collecting list lies below the loop's state (the nl value lists, the counters and the info object), the result is on top;
            # the loop's step follows, and carries nl
            set nl [lindex $PI($P,ins,$PI($P,next,$pc)) 1 1]
            return "Tcl_ListObjAppendElement(NULL, s[expr {$d - 4 - $nl}], s[expr {$d - 1}]); Tcl_DecrRefCount(s[expr {$d - 1}]);"
        }
        foreach_start {
            lassign $a n nl jo vl stepPc
            set c "\{ long im_ = 0, nt_;"
            set d0 [expr {$d - $nl}]
            for {set i 0} {$i < $nl} {incr i} {
                set nv [llength [lindex $vl $i]]
                append c " \{ int ll_; Tcl_Obj *l_ = s[expr {$d0+$i}]; if (TclListObjLength(interp, l_, &ll_) != TCL_OK) goto @E@; if (Tcl_IsShared(l_)) \{ Tcl_Obj *c_ = TclListObjCopy(NULL, l_); Tcl_IncrRefCount(c_); Tcl_DecrRefCount(l_); s[expr {$d0+$i}] = c_; \} nt_ = (ll_ + [expr {$nv-1}]) / $nv; if (nt_ > im_) im_ = nt_; \}"
            }
            append c " \{ Tcl_Obj *c_ = Tcl_NewObj(); c_->internalRep.twoPtrValue.ptr1 = INT2PTR(0); c_->internalRep.twoPtrValue.ptr2 = INT2PTR(im_); Tcl_IncrRefCount(c_); s$d = c_; \} s[expr {$d+1}] = tbcEmpty; Tcl_IncrRefCount(tbcEmpty); \} goto G$stepPc;"
            return [string map $X $c]
        }
        foreach_step {
            lassign $a n nl jo vl stepPc
            set d0 [expr {$d - $nl - 2}]
            set c "\{ Tcl_Obj *c_ = s[expr {$d-2}]; long it_ = PTR2INT(c_->internalRep.twoPtrValue.ptr1); if (it_ < PTR2INT(c_->internalRep.twoPtrValue.ptr2)) \{ c_->internalRep.twoPtrValue.ptr1 = INT2PTR(it_ + 1);"
            for {set i 0} {$i < $nl} {incr i} {
                append c " \{ Tcl_Obj **el_; int ll_; TclListObjGetElements(interp, s[expr {$d0+$i}], &ll_, &el_);"
                set j 0
                foreach var [lindex $vl $i] {
                    append c " \{ long ix_ = it_ * [llength [lindex $vl $i]] + $j; Tcl_Obj *v_ = ix_ >= ll_ ? NULL : el_\[ix_\], *r_; if (!v_) \{ v_ = Tcl_NewObj(); Tcl_IncrRefCount(v_); r_ = tbc_setloc(interp, loc_, $var, v_, TCL_LEAVE_ERR_MSG); Tcl_DecrRefCount(v_); \} else r_ = tbc_setloc(interp, loc_, $var, v_, TCL_LEAVE_ERR_MSG); if (!r_) goto @E@; \}"
                    incr j
                }
                append c " \}"
            }
            append c " goto G[expr {$stepPc + $jo}]; \} \}"
            return [string map $X $c]
        }
        foreach_end {
            lassign $a n nl
            set c ""
            for {set k [expr {$d-1}]} {$k >= $d - $nl - 2} {incr k -1} { append c "Tcl_DecrRefCount(s$k); " }
            return $c
        }
        pushResult { return [string map $X {{ @sn@ = tbc_takeres(interp); }}] }
        pushReturnCode { return [string map $X {@sn@ = tbc_newint(rcg_);}] }
        pushReturnOpts { return [string map $X {{ Tcl_Obj *o_ = Tcl_GetReturnOptions(interp, rcg_); Tcl_IncrRefCount(o_); @sn@ = o_; }}] }
        break { return [string map $X {rcg_ = TCL_BREAK; goto @X@;}] }
        continue { return [string map $X {rcg_ = TCL_CONTINUE; goto @X@;}] }
        returnCodeBranch {
            # five jumps follow; the result code selects one (offsets 1, 3, 5, 7, 9)
            set c "\{ int code_; if (TclGetIntFromObj(NULL, s[expr {$d-1}], &code_) != TCL_OK) Tcl_Panic(\"returnCodeBranch: not a return code\"); if (code_ < TCL_ERROR || code_ > TCL_CONTINUE) code_ = TCL_CONTINUE + 1; Tcl_DecrRefCount(s[expr {$d-1}]); switch (code_) \{"
            set k 1
            foreach o {1 3 5 7 9} { append c " case $k: goto G[expr {$pc + $o}];"; incr k }
            append c " default: goto G[expr {$pc + 9}]; \} \}"
            return $c
        }
        returnImm - syntax {
            lassign $a code level
            return [string map [concat $X [list @CODE@ $code @LEVEL@ $level @CLR@ [expr {$op eq "syntax" ? "((Interp *) interp)->flags &= ~ERR_ALREADY_LOGGED; " : ""}]]] {{ int r_ = TclProcessReturn(interp, @CODE@, @LEVEL@, @s1@); if (r_ == TCL_OK) { Tcl_DecrRefCount(@s1@); } else { Tcl_SetObjResult(interp, @s2@); rcg_ = r_; @CLR@goto @X@; } }}]
        }
        returnStk {
            return [string map $X {{ int r_ = Tcl_SetReturnOptions(interp, @s2@); if (r_ == TCL_OK) { Tcl_DecrRefCount(@s2@); @s2@ = @s1@; } else { if (r_ == TCL_ERROR) { Tcl_SetObjResult(interp, @s1@); Tcl_SetReturnOptions(interp, @s2@); } else { Tcl_SetObjResult(interp, @s1@); } rcg_ = r_; goto @X@; } }}]
        }
        variable {
            set n [operand [lindex $a 0]]
            return [string map [concat $X [list @N@ $n]] {{ Var *vp_; Var *o_ = TclObjLookupVarEx(interp, @s1@, NULL, (TCL_NAMESPACE_ONLY | TCL_LEAVE_ERR_MSG), "access", 1, 1, &vp_); if (!o_) goto @E@; TclSetVarNamespaceVar(o_); if (tbc_linkvars(interp, loc_, @N@, o_)) goto @E@; Tcl_DecrRefCount(@s1@); }}]
        }
        upvar {
            set n [operand [lindex $a 0]]
            return [string map [concat $X [list @N@ $n]] {{ CallFrame *fr_, *sv_; Var *vp_, *o_; Interp *ip_ = (Interp *) interp; if (TclObjGetFrame(interp, @s2@, &fr_) == -1) goto @E@; sv_ = ip_->varFramePtr; ip_->varFramePtr = fr_; o_ = TclObjLookupVarEx(interp, @s1@, NULL, TCL_LEAVE_ERR_MSG, "access", 1, 1, &vp_); ip_->varFramePtr = sv_; if (!o_) goto @E@; if (tbc_linkvars(interp, loc_, @N@, o_)) goto @E@; Tcl_DecrRefCount(@s1@); }}]
        }
        nsupvar {
            set n [operand [lindex $a 0]]
            return [string map [concat $X [list @N@ $n]] {{ Tcl_Namespace *ns_; Namespace *sv_; Var *vp_, *o_; Interp *ip_ = (Interp *) interp; if (TclGetNamespaceFromObj(interp, @s2@, &ns_) != TCL_OK) goto @E@; sv_ = ip_->varFramePtr->nsPtr; ip_->varFramePtr->nsPtr = (Namespace *) ns_; o_ = TclObjLookupVarEx(interp, @s1@, NULL, (TCL_NAMESPACE_ONLY | TCL_LEAVE_ERR_MSG | TCL_AVOID_RESOLVERS), "access", 1, 1, &vp_); ip_->varFramePtr->nsPtr = sv_; if (!o_) goto @E@; if (tbc_linkvars(interp, loc_, @N@, o_)) goto @E@; Tcl_DecrRefCount(@s1@); }}]
        }
        default { error "genG: no handler for $op" }
    }
}

# ================================================================== the boxed code of a proc: one function, entered at any instruction
# Locals live in the interpreter's own call frame (Var slots), the operand stack in C variables holding references, exactly as the
# bytecode executor does it; the function runs inside the frame the interpreter built for the proc.  Typed code that gives up
# writes its state into the frame and the stack array and enters here at the instruction it was executing.
# jump to the handler of catch range r from an instruction with d operands on the stack: drop what lies above the stack depth the catch began at
proc catchJump {P r d} {
    global PI
    set tg [dict get $r catch]
    set from [dict get $r from]
    set t $PI($P,depth,$from)
    set c ""
    for {set k [expr {$d - 1}]} {$k >= $t} {incr k -1} { append c "Tcl_DecrRefCount(s$k); " }
    return "${c}goto G$tg;\n"
}

# The entries of the boxed functions that anything calls: the typed variants hand over at their deoptimisation points, call sites and error paths, each
# with a literal entry number, and the module's own wrappers enter at 0.  Only those get a case in the entry switch (a case for every instruction would be
# called for about 5% of them).  All typed code is emitted before the first boxed function, so the text so far holds every such call.
proc entryCalled {cid pc} {
    global out ENT
    if {$pc == 0} { return 1 }
    if {![info exists ENT]} {
        array set ENT {}
        foreach {all c n} [regexp -all -inline {\yG_(\w+)\(interp, (-?\d+),} $out] { set ENT($c,$n) 1 }
        foreach {all c n} [regexp -all -inline {TBC_GNOF\(resumed_, G_(\w+), interp, (-?\d+),} $out] { set ENT($c,$n) 1 }
        # (the resume callbacks of the procs that yield enter at the instruction after each yield, and at the yield itself with an error)
        global PI translatable
        foreach P $translatable {
            if {!$PI($P,hasYield)} continue
            foreach ypc $PI($P,reach) { if {[lindex $PI($P,ins,$ypc) 0] in {yield yieldToInvoke}} { set ENT([cident $P],$PI($P,next,$ypc)) 1; set ENT([cident $P],[expr {-$ypc-1}]) 1 } }
        }
        # (a re-entry that gives up goes on in the boxed code at the loop head it was entered from)
        global OSRKEY OSRKEYW
        dict for {P gk} $OSRKEY { foreach rp [resumePoints $gk] { set ENT([cident $P],$rp) 1 } }
        dict for {P gk} $OSRKEYW { foreach rp [resumePoints $gk] { set ENT([cident $P],$rp) 1 } }
    }
    return [info exists ENT($cid,$pc)]
}

# the callback that continues the boxed code of P after a yield: when the coroutine is resumed the interpreter runs it, with the interpreter's result (the value the
# resumer passed) as the result of the yield instruction.  A coroutine that is deleted while suspended rewinds: the stack is released and nothing runs.
proc emitResume {P} {
    global PI REKEY
    set cid [cident $P]
    set maxd2 [expr {$PI($P,maxd) + 2}]
    set fn "static int tbc_yres_${cid}(ClientData data\[\], Tcl_Interp *interp, int result)\n\{\n"
    append fn "    Interp *iPtr = (Interp *) interp;\n    TbcYieldRec *rec = (TbcYieldRec *) data\[0\];\n    Tcl_Obj *stk\[$maxd2\];\n    int i, n = rec->n, pc = rec->pc, code = TCL_ERROR;\n"
    append fn "    for (i = 0; i < n; i++) stk\[i\] = rec->o\[i\];\n    ckfree((char *) rec);\n"
    append fn "    if (iPtr->execEnvPtr->rewind) \{ for (i = 0; i < n; i++) Tcl_DecrRefCount(stk\[i\]); return TCL_ERROR; \}\n"
    append fn "    stk\[n\] = Tcl_GetObjResult(interp); Tcl_IncrRefCount(stk\[n\]);\n    iPtr->numLevels--; tbc_nest++; tbc_maxdepth = Tcl_SetRecursionLimit(interp, 0);\n"
    set ok ""; set bad ""
    global REKEY VK
    set re [expr {[dict exists $REKEY $P] ? [dict get $REKEY $P] : ""}]
    set pts [expr {$re ne "" ? [resumePoints $re] : {}}]
    if {$re ne ""} {
        set rk $VK($re,ret); if {$rk in {- U}} { set rk B }
        switch $rk {
            I { set fin "int64_t r_ = V_${cid}_RE(interp, tbc_maxdepth - iPtr->numLevels + TBC_REMK, pc, stk, n + 1); if (tbc_st) code = tbc_finish(interp); else \{ Tcl_SetObjResult(interp, Tcl_NewWideIntObj(r_)); code = TCL_OK; \}" }
            D { set fin "double r_ = V_${cid}_RE(interp, tbc_maxdepth - iPtr->numLevels + TBC_REMK, pc, stk, n + 1); if (tbc_st) code = tbc_finish(interp); else \{ Tcl_SetObjResult(interp, Tcl_NewDoubleObj(r_)); code = TCL_OK; \}" }
            default { set fin "Tcl_Obj *r_ = V_${cid}_RE(interp, tbc_maxdepth - iPtr->numLevels + TBC_REMK, pc, stk, n + 1); if (tbc_st) code = tbc_finish(interp); else \{ Tcl_SetObjResult(interp, r_); Tcl_DecrRefCount(r_); code = TCL_OK; \}" }
        }
    }
    foreach pc $PI($P,reach) {
        if {[lindex $PI($P,ins,$pc) 0] ni {yield yieldToInvoke}} continue
        set nx $PI($P,next,$pc)
        if {$nx in $pts} { append ok "        case $nx: \{ $fin \} break;\n" } else {
        append ok "        case $nx: code = G_${cid}(interp, $nx, stk, n + 1); break;\n" }
        append bad "        case $nx: code = G_${cid}(interp, [expr {-$pc-1}], stk, n + 1); break;\n"
    }
    append fn "    if (result == TCL_OK) \{\n        switch (pc) \{\n$ok        default: break;\n        \}\n    \} else \{\n        tbc_rc = result;\n        switch (pc) \{\n$bad        default: break;\n        \}\n    \}\n"
    append fn "    tbc_nest--; iPtr->numLevels++;\n    if (tbc_susp) \{ tbc_susp = 0; return TCL_OK; \}\n    if (code == TCL_ERROR) iPtr->flags |= ERR_ALREADY_LOGGED;\n    return code;\n\}\n"
    return $fn
}

# The points at which the boxed code of P may enter typed code again: the loop heads the typed analysis knows the state at (resumePoints of the generic variant).
proc osrPointsOf {P} {
    global OSRKEY OSRKEYW
    set r {}
    if {[dict exists $OSRKEY $P]} { set r [resumePoints [dict get $OSRKEY $P]] }
    if {[dict exists $OSRKEYW $P]} { set r [lsort -integer -unique [concat $r [resumePoints [dict get $OSRKEYW $P]]]] }
    return $r
}
# At such a loop head, once per activation of the boxed code: hand the stack and the frame to the typed variant for boxed arguments, which starts there.  It
# checks the locals and the stack against the kinds the typed code assumes and, if they do not fit, goes on in the boxed code itself (with osr_ off, see
# TBC_GNOF); if they fit, typed code runs to the end of the call and this activation returns its result.  The stack slots belong to the variant from the call on.
# A proc that adapts has two such variants (the second with tagged numbers, used once its flag is set).
proc osrFin {P gk pc d} {
    global VK PI
    set cid [cident $P]
    set rk $VK($gk,ret); if {$rk in {- U}} { set rk B }
    set nulls [string repeat ", NULL" $PI($P,nargs)]
    set call "V_${cid}_[lindex [keysplit $gk] 1](interp, tbc_maxdepth - ((Interp *) interp)->numLevels + TBC_REMK, 1$nulls)"
    switch $rk {
        I { return "int64_t r_ = $call; if (tbc_st) rcg_ = tbc_finish(interp); else \{ Tcl_SetObjResult(interp, Tcl_NewWideIntObj(r_)); rcg_ = TCL_OK; \}" }
        D { return "double r_ = $call; if (tbc_st) rcg_ = tbc_finish(interp); else \{ Tcl_SetObjResult(interp, Tcl_NewDoubleObj(r_)); rcg_ = TCL_OK; \}" }
    }
    return "Tcl_Obj *r_ = $call; if (tbc_st) rcg_ = tbc_finish(interp); else \{ Tcl_SetObjResult(interp, r_); Tcl_DecrRefCount(r_); rcg_ = TCL_OK; \}"
}
proc osrAttempt {P pc d} {
    global OSRKEY OSRKEYW PI
    set cid [cident $P]
    set slots {}; for {set i 0} {$i < $d} {incr i} { lappend slots s$i }
    set gk ""; set wk ""
    if {[dict exists $OSRKEY $P] && $pc in [resumePoints [dict get $OSRKEY $P]]} { set gk [dict get $OSRKEY $P] }
    if {[dict exists $OSRKEYW $P] && $pc in [resumePoints [dict get $OSRKEYW $P]]} { set wk [dict get $OSRKEYW $P] }
    if {$gk eq "" && $wk eq ""} { return "" }
    if {$gk ne "" && $wk ne ""} { set fin "if (tbc_wp_$cid) \{ [osrFin $P $wk $pc $d] \} else \{ [osrFin $P $gk $pc $d] \}"; set cond "osr_" } \
    elseif {$wk ne ""} { set fin [osrFin $P $wk $pc $d]; set cond "osr_ && tbc_wp_$cid" } \
    else { set fin [osrFin $P $gk $pc $d]; set cond [expr {$PI($P,wadapt) ? "osr_ && !tbc_wp_$cid" : "osr_"}] }
    return "    if ($cond) \{ Tcl_Obj *rs_\[[expr {$d + 1}]\] = { [join [concat $slots NULL] {, }] }; osr_ = 0; tbc_rpc1 = $pc + 1; tbc_rstk = rs_; tbc_rn = $d; $fin goto gexit; \}\n"
}

proc emitG {P} {
    global PI
    set cid [cident $P]
    set maxd2 [expr {$PI($P,maxd) + 1}]
    set fn ""
    if {$PI($P,hasYield)} { append fn "static int tbc_yres_${cid}(ClientData data\[\], Tcl_Interp *interp, int result);\n" }
    append fn "static int G_${cid}(Tcl_Interp *interp, int entryPc, Tcl_Obj **stk, int nstk)\n\{\n"
    append fn "    Var *loc_ = ((Interp *) interp)->varFramePtr->compiledLocals;\n    int rcg_ = TCL_OK;\n    (void) stk; (void) nstk; (void) loc_;\n"
    set osrPts [osrPointsOf $P]
    if {[llength $osrPts]} { append fn "    int osr_ = !tbc_noosr; tbc_noosr = 0;\n" }
    for {set k 0} {$k < $maxd2} {incr k} { append fn "    Tcl_Obj *s$k = NULL;\n" }
    foreach it $PI($P,iters) { append fn "    Tcl_DictSearch ds$it; Tcl_Obj *dd$it = NULL;\n" }
    for {set it 0} {$it < $PI($P,exlevels)} {incr it} { append fn "    Tcl_Obj *ex${it}_ = NULL;\n" }
    append fn "    switch (entryPc) \{\n"
    foreach pc $PI($P,reach) {
        set d $PI($P,depth,$pc)
        if {[entryCalled $cid $pc]} {
            append fn "    case $pc: "
            for {set i 0} {$i < $d} {incr i} { append fn "s$i = stk\[$i\]; " }
            append fn "goto G$pc;\n"
        }
        if {[lindex $PI($P,ins,$pc) 0] in {invokeStk1 invokeStk4 yield yieldToInvoke} && [entryCalled $cid [expr {-$pc-1}]]} {
            append fn "    case [expr {-$pc-1}]: "
            for {set i 0} {$i < $d} {incr i} { append fn "s$i = stk\[$i\]; " }
            append fn "rcg_ = tbc_rc; goto X$pc;\n"
        }
    }
    append fn "    default: Tcl_SetObjResult(interp, Tcl_ObjPrintf(\"tbc: internal error: the boxed code has no entry at instruction %d\", entryPc)); rcg_ = TCL_ERROR; goto gexit;\n    \}\n"
    foreach pc $PI($P,reach) {
        set d $PI($P,depth,$pc)
        append fn "G$pc: ;  /* $PI($P,ins,$pc) */\n"
        if {$pc in $PI($P,loopheads)} { append fn "    if (TBC_UNLIKELY(((++tbc_ticks & 63) == 0) && tbc_poll(interp))) goto GE$pc;\n" }
        if {$pc in $osrPts} { append fn [osrAttempt $P $pc $d] }
        append fn "    [genG $P/ $pc $d]\n"
    }
    # what happens when an instruction ends with an error or another result code (rcg_): errors are logged in the errorInfo as the interpreter
    # does it; with exception ranges around, the interpreter's exception processing follows, resolved statically for each instruction
    # (ranges are known; only the result code is dynamic)
    array set usedE {}
    foreach {m kind n} [regexp -all -inline {\m(GE|X)(\d+)\M} $fn] { set usedE($n) 1 }
    foreach pc $PI($P,reach) {
        if {![info exists usedE($pc)]} continue
        set d $PI($P,depth,$pc)
        lassign $PI($P,ins,$pc) op a
        set cleanup [switch $op { yield - yieldToInvoke { expr 1 } invokeStk1 - invokeStk4 - tailcall { lindex $a 0 } evalStk { expr 1 } invokeReplace { expr {[lindex $a 0] + 1} } invokeExpanded { expr {$d - [lindex $PI($P,mk,$pc) end]} } returnImm - syntax - returnStk { expr 2 } default { expr 0 } }]
        lassign [expr {$PI($P,src,$pc) eq "" ? {-1 0} : $PI($P,src,$pc)}] so sl
        set tos ""; for {set k 0} {$k < $d} {incr k} { append tos ", s$k" }
        append fn "GE$pc: rcg_ = TCL_ERROR;\nX$pc: TBC_XLOG($pc, $so, $sl, $d$tos);\n"
        if {![hasRanges $P]} { append fn "    goto gf_$d;\n"; continue }
        set swStart [string length $fn]
        append fn "    switch (rcg_) \{\n"
        foreach {code mode} {TCL_BREAK 3 TCL_CONTINUE 4} {
            if {![tbcCanBC $op $a]} continue
            set r [findRange $PI($P,ranges) $pc $mode]
            if {[info exists PI($P,drop,$pc,$mode)] && $r ne "" && [dict get $r type] ne "catch"} { set r "" }
            append fn "    case $code: "
            if {$r eq ""} { append fn "goto gf_$d;\n"; continue }
            if {[dict get $r type] eq "catch"} {
                append fn [catchJump $P $r $d]
            } else {
                for {set k [expr {$d - 1}]} {$k >= $d - $cleanup} {incr k -1} { append fn "Tcl_DecrRefCount(s$k); " }
                set tg [dict get $r [expr {$mode == 3 ? "break" : "continue"}]]
                append fn "rcg_ = TCL_OK; goto G$tg;\n"
            }
        }
        set r [findRange $PI($P,ranges) $pc 1]
        if {$r eq "" && [string length $fn] == $swStart + [string length "    switch (rcg_) \{\n"]} {
            # nothing but the default: no switch
            set fn "[string range $fn 0 [expr {$swStart - 1}]]    goto gf_$d;\n"
        } else {
            append fn "    default: "
            if {$r eq ""} { append fn "goto gf_$d;\n" } else { append fn [catchJump $P $r $d] }
            append fn "    \}\n"
        }
    }
    for {set k $maxd2} {$k >= 1} {incr k -1} { append fn "gf_$k: Tcl_DecrRefCount(s[expr {$k-1}]);\n" }
    append fn "gf_0: goto gexit;\ngok: rcg_ = TCL_OK;\ngexit:\n"
    foreach it $PI($P,iters) { append fn "    if (dd$it) \{ Tcl_DictObjDone(&ds$it); Tcl_DecrRefCount(dd$it); \}\n" }
    for {set it 0} {$it < $PI($P,exlevels)} {incr it} { append fn "    if (ex${it}_) Tcl_DecrRefCount(ex${it}_);\n" }
    append fn "    return rcg_;\n\}\n"
    if {$PI($P,hasYield)} { append fn [emitResume $P] }
    return $fn
}

# ================================================================== emitting one variant
proc rettype {rk} { ctype [expr {$rk in {- U} ? "B" : $rk}] }

# the instructions after the yields of P at which the generic variant `key` has a typed state
proc resumePoints {key} {
    global VK PI
    lassign [keysplit $key] P sig
    set pts {}
    foreach pc $PI($P,reach) {
        if {[lindex $PI($P,ins,$pc) 0] ni {yield yieldToInvoke}} continue
        set nx $PI($P,next,$pc)
        if {[info exists VK($key,in,$nx)] && [resumeWorthwhile $P $nx]} { lappend pts $nx }
    }
    # a proc that does not yield: the loop heads, for the boxed code to enter typed code again after typed code has handed over (see osrAttempt)
    if {!$PI($P,hasYield) && ![llength $PI($P,iters)] && !$PI($P,exlevels)} {
        set kap $VK($key,kap)
        # (only the outermost loops: the boxed code that reaches an inner loop head from the middle of a loop is soon at the head of the loop around it)
        set ends [dict create]
        foreach pc $PI($P,reach) { foreach t $PI($P,succ,$pc) { if {$t <= $pc} { dict set ends $t [expr {[dict exists $ends $t] ? max([dict get $ends $t], $pc) : $pc}] } } }
        foreach pc $PI($P,loopheads) {
            if {![info exists VK($key,in,$pc)] || $pc ni $PI($P,reach)} continue
            set inner 0
            dict for {h e} $ends { if {$h < $pc && $pc <= $e} { set inner 1; break } }
            if {$inner} continue
            set ok 1
            foreach e $VK($key,in,$pc) { if {[kd $e] ni {I D B T}} { set ok 0; break } }
            foreach v $PI($P,may,$pc) { if {[dict get $kap $v] ni {I D B F W}} { set ok 0; break } }
            if {$ok} { lappend pts $pc }
        }
    }
    return $pts
}
# Typed code after a yield pays for the change from boxed code (the locals are read from the frame and checked) and for the change back at the next yield.  Only
# a loop can make the work between two yields outgrow that: re-enter typed code where a loop that contains no yield can be reached from the resume point before
# the next yield.  (A generator whose loop body is the yield stays in boxed code, which is as fast as the interpreter's.)
proc resumeWorthwhile {P nx} {
    global PI
    set seen [dict create $nx 1]; set todo [list $nx]; set backs {}
    while {[llength $todo]} {
        set pc [lindex $todo end]; set todo [lrange $todo 0 end-1]
        if {[lindex $PI($P,ins,$pc) 0] in {yield yieldToInvoke}} continue
        foreach t $PI($P,succ,$pc) {
            if {$t <= $pc} { lappend backs [list $pc $t] }
            if {![dict exists $seen $t]} { dict set seen $t 1; lappend todo $t }
        }
    }
    foreach b $backs {
        lassign $b src tgt
        set clean 1
        foreach pc $PI($P,reach) { if {$pc >= $tgt && $pc <= $src && [lindex $PI($P,ins,$pc) 0] in {yield yieldToInvoke}} { set clean 0; break } }
        if {$clean} { return 1 }
    }
    return 0
}
# The entry of the copy that goes on in typed code after a yield.  The boxed code has run since the typed code handed over, so nothing the typed code knew can
# be taken for granted: every local that may have been assigned is read from the frame and must be what the typed code expects (an integer for an
# integer variable, no trace, no link), and so must each stack slot; if anything is not, the boxed code goes on instead.  Checks come first and change nothing.
proc resumePrologue {key} {
    global VK PI
    lassign [keysplit $key] P sig
    set kap $VK($key,kap)
    set c "    switch (rpc) \{\n"
    set pts [resumePoints $key]
    foreach nx $pts { append c "    case $nx: goto R$nx;\n" }
    append c "    default: goto giveup;\n    \}\n"
    foreach nx $pts {
        set st $VK($key,in,$nx)
        set chk ""; set ld ""
        foreach v $PI($P,may,$nx) {
            set k [dict get $kap $v]
            if {$k eq "F"} {
                # (typed code assumes that a variable it keeps in the frame is not linked to a variable of this very frame, which it may hold unboxed; the boxed code
                # that has run since may have linked it so, see tbc_t_upvar)
                append chk "    \{ Var *vp_ = &loc_\[$v\]; if (TBC_UNLIKELY((vp_->flags & VAR_LINK) && vp_->value.linkPtr >= loc_ && vp_->value.linkPtr < loc_ + [llength $PI($P,vnames)])) goto giveup; \}\n"
                continue
            }
            append chk "    \{ Var *vp_ = &loc_\[$v\]; if (TBC_UNLIKELY(vp_->flags & (VAR_ARRAY | VAR_LINK | VAR_TRACED_READ | VAR_TRACED_WRITE | VAR_TRACED_UNSET | VAR_TRACE_ACTIVE))) goto giveup;"
            switch $k {
                I - D {
                    set conv [expr {$k eq "I" ? "tbc_arg_int" : "tbc_arg_dbl"}]
                    set var [expr {$k eq "I" ? "i$v" : "d$v"}]
                    if {$v in [flaggedOf $P]} {
                        append chk " if (vp_->value.objPtr) \{ if (!${conv}(vp_->value.objPtr, &$var)) goto giveup; g$v = 1; \} else g$v = 0; \}\n"
                    } else {
                        append chk " if (!vp_->value.objPtr || !${conv}(vp_->value.objPtr, &$var)) goto giveup; \}\n"
                    }
                }
                W {
                    append chk " if (!vp_->value.objPtr || !tbc_wload_canon(vp_->value.objPtr, &wt$v, &i$v, &d$v)) goto giveup; \}\n"
                }
                B {
                    append chk " \}\n"
                    append ld "    \{ Var *vp_ = &loc_\[$v\]; if (vp_->value.objPtr) \{ l$v = vp_->value.objPtr; Tcl_IncrRefCount(l$v); \} \}\n"
                }
                default { append chk " goto giveup; \}\n" }
            }
        }
        for {set p 0} {$p < [llength $st]} {incr p} {
            set e [lindex $st $p]
            switch [kd $e] {
                I { append chk "    if (!tbc_arg_int(rstk\[$p\], &si$p)) goto giveup;\n"; append ld "    Tcl_DecrRefCount(rstk\[$p\]);\n" }
                D { append chk "    if (!tbc_arg_dbl(rstk\[$p\], &sd$p)) goto giveup;\n"; append ld "    Tcl_DecrRefCount(rstk\[$p\]);\n" }
                B { append ld "    s$p = rstk\[$p\];\n" }
                T {
                    set sp [lt $e]
                    append ld "    fit_$sp = PTR2INT(rstk\[$p\]->internalRep.twoPtrValue.ptr1); fmax_$sp = PTR2INT(rstk\[$p\]->internalRep.twoPtrValue.ptr2); Tcl_DecrRefCount(rstk\[$p\]);\n"
                }
                default { append chk "    goto giveup;\n" }
            }
        }
        append c "R$nx: ;\n$chk$ld    goto T$nx;\n"
    }
    append c "giveup:\n    \{ int g_ = G_[cident $P](interp, rpc, rstk, rn); if (TBC_UNLIKELY(tbc_susp)) \{ tbc_st = 4; rc = TCL_OK; goto ret; \} if (g_ == TCL_OK) \{ tbc_box = tbc_takeres(interp); tbc_st = 1; rc = TCL_OK; \} else \{ rc = g_; \} goto ret; \}\n"
    return $c
}

proc emitVariant {key recursive {resume 0}} {
    global VK PI FM FRM typedMode
    lassign [keysplit $key] P sig
    set ::curWpol [wpolK $key]
    set cid [cident $P]
    set kap $VK($key,kap)
    set rk $VK($key,ret); if {$rk in {- U}} { set rk B }
    set nv [llength $PI($P,vnames)]; set maxd $PI($P,maxd)
    set maxd2 [expr {$maxd + 1}]
    array unset FM [globEsc $key],*
    array unset FRM [globEsc $key],*
    # parameters
    set plist {}
    for {set v 0} {$v < $PI($P,nargs)} {incr v} { lappend plist "[ctype [string index $sig $v]] a$v" }
    if {$resume} {
        # the copy of the generic variant that goes on after a yield: the boxed code has run, so the locals and the operand stack come from the frame and from
        # the array the resume callback holds (see resumePrologue)
        set fn "static [rettype $rk] V_${cid}_RE(Tcl_Interp *interp, int rem, int rpc, Tcl_Obj **rstk, int rn)\n\{\n    const int inframe = 1;\n"
    } else {
        set fn "static [rettype $rk] V_${cid}_${sig}(Tcl_Interp *interp, int rem, int inframe[expr {[llength $plist] ? ", " : ""}][join $plist {, }])\n\{\n"
    }
    append fn "    int rc = TCL_ERROR;\n    [rettype $rk] rv = 0;\n    Var *loc_ = inframe ? ((Interp *) interp)->varFramePtr->compiledLocals : NULL;\n    (void) rem; (void) loc_;\n"
    for {set v 0} {$v < $nv} {incr v} {
        append fn "    Tcl_Obj *l$v = NULL; (void) l$v;"
        switch [dict get $kap $v] { W { append fn " int64_t i$v = 0; double d$v = 0; int wt$v = 0; (void) i$v; (void) d$v; (void) wt$v;" } I { append fn " int64_t i$v = 0; (void) i$v;" } D { append fn " double d$v = 0; (void) d$v;" } A { append fn " tbc_ivec av$v = {NULL, 0};" } M { append fn " tbc_imap mv$v; memset(&mv$v, 0, sizeof mv$v);" } R { append fn " tbc_rmap rv$v; memset(&rv$v, 0, sizeof rv$v);" } }
        if {$v in [flaggedOf $P] && [dict get $kap $v] in {I D}} { append fn " int g$v = 0; (void) g$v;" }
        append fn "\n"
    }
    for {set k 0} {$k < $maxd2} {incr k} { append fn "    Tcl_Obj *s$k = NULL; int64_t si$k = 0; double sd$k = 0; (void) s$k; (void) si$k; (void) sd$k;[expr {$::curWpol ? " int sw$k = 0; (void) sw$k;" : ""}]\n" }
    foreach pc $PI($P,reach) { if {[lindex $PI($P,ins,$pc) 0] eq "foreach_step"} { set sp [lindex $PI($P,ins,$pc) 1 4]; append fn "    long fit_$sp = 0, fmax_$sp = 0; (void) fit_$sp; (void) fmax_$sp;\n" } }
    append fn "@@VECDECLS@@"
    if {$recursive && !$resume} {
        append fn "    if (TBC_UNLIKELY(rem < 0)) \{ tbc_depth_error(interp); tbc_st = 2; tbc_rc = TCL_ERROR; return rv; \}\n"
    }
    # the variant the boxed code enters at a loop head: locals and stack come from the frame and from tbc_rstk (see resumePrologue)
    set osrHere [expr {!$resume && (([dict exists $::OSRKEY $P] && [dict get $::OSRKEY $P] eq $key) || ([dict exists $::OSRKEYW $P] && [dict get $::OSRKEYW $P] eq $key))}]
    if {$osrHere} {
        append fn "    int resumed_ = 0, rpc = 0, rn = 0; Tcl_Obj **rstk = NULL; (void) rstk; (void) rn;\n"
        append fn "    if (TBC_UNLIKELY(tbc_rpc1)) \{ resumed_ = 1; rpc = tbc_rpc1 - 1; rstk = tbc_rstk; rn = tbc_rn; tbc_rpc1 = 0; goto RESUME; \}\n"
    }
    # arguments into locals
    for {set v 0} {$v < $PI($P,nargs) && !$resume} {incr v} {
        set s [string index $sig $v]; set k [dict get $kap $v]
        if {$k eq "F"} {
            # (lives in the frame)
        } elseif {$k eq "W"} {
            # (an integer or double argument of a variable that holds either)
            switch $s { I { append fn "    wt$v = 0; i$v = a$v;\n" } D { append fn "    wt$v = 1; d$v = a$v;\n" } }
        } elseif {$s eq $k} {
            switch $k { I { append fn "    i$v = a$v;\n" } D { append fn "    d$v = a$v;\n" } B { append fn "    l$v = a$v; Tcl_IncrRefCount(l$v);\n" } }
        } else {
            switch $s { I { append fn "    l$v = tbc_newint(a$v);\n" } D { append fn "    l$v = tbc_newdbl(a$v);\n" } }
        }
    }
    if {$resume} {
        append fn "    TBC_HIT([cstring "V:$key/RE"]);\n"
        append fn [resumePrologue $key]
    } else {
        append fn "    TBC_HIT([cstring "V:$key"]);\n"
        append fn "    goto [expr {[info exists VK($key,in,0)] && $typedMode && ![string match *w $sig] ? "T0" : "redo_all"}];\n"
        if {$osrHere} {
            append fn "RESUME: ;\n    TBC_HIT([cstring "V:$key/RE"]);\n"
            append fn [resumePrologue $key]
        }
    }

    # ---- typed code
    set tpcs {}
    foreach pc $PI($P,reach) { if {$typedMode && [info exists VK($key,in,$pc)]} { lappend tpcs $pc } }
    if {$resume || [string match *w $sig]} {
        # a copy that is entered at its resume points holds only the code that can be reached from them (so does the tagged version of a proc that adapts: the boxed code runs
        # such a proc up to its first loop head, where it is entered)
        set seen [dict create]; set todo [resumePoints $key]
        foreach t $todo { dict set seen $t 1 }
        while {[llength $todo]} {
            set pc [lindex $todo end]; set todo [lrange $todo 0 end-1]
            if {$pc ni $tpcs} continue
            foreach t $PI($P,succ,$pc) { if {![dict exists $seen $t]} { dict set seen $t 1; lappend todo $t } }
        }
        set tpcs [lmap pc $tpcs {expr {[dict exists $seen $pc] ? $pc : [continue]}}]
    }
    set stubs ""
    foreach pc $tpcs {
        set in $VK($key,in,$pc)
        set r [stepT $key $pc $in]
        set flow [dict get $r flow]; set out [dict get $r out]; set code [dict get $r code]
        set DSITE($key,$pc) [siteInfo $P $pc $in [expr {$flow eq "dead" ? "unsupported" : "guard"}]]
        if {$flow eq "dead" && [info exists ::env(TBC_DEADOPS)]} { set cmdn ""; if {[lindex $PI($P,ins,$pc) 0] in {invokeStk1 invokeStk4}} { set nn [lindex $PI($P,ins,$pc) 1]; set ce [lindex $in [expr {[llength $in] - $nn}]]; if {[kd $ce] eq "L"} { set cmdn [lindex $PI($P,lits) [lt $ce]] } else { set cmdn "<dynamic>" } }; puts stderr "DEADOP [lindex $PI($P,ins,$pc) 0] $cmdn :: $key $pc [lindex $in end]" }
        append fn "T$pc: ;  /* $PI($P,ins,$pc) */\n"
        if {$pc in $PI($P,loopheads)} { append fn "    if (TBC_UNLIKELY(tbc_tick_due(interp))) goto D$pc;\n" }
        if {[info exists ::env(TBC_FORCE_DEOPT)]} { append fn "    if (TBC_UNLIKELY(tbc_force_due())) goto D$pc;\n" }
        switch $flow {
            fall {
                set nx $PI($P,next,$pc)
                append fn "    $code [edgec $P $out $VK($key,in,$nx)]\n"
            }
            jump {
                set tg [dict get $r tgt]
                append fn "    $code [edgec $P $out $VK($key,in,$tg)] goto T$tg;\n"
            }
            cond {
                set tg [dict get $r tgt]; set nx $PI($P,next,$pc)
                set code [string map [list @TAKEN@ [edgec $P $out $VK($key,in,$tg)]] $code]
                append fn "    $code [edgec $P $out $VK($key,in,$nx)]\n"
            }
            multi {
                set nx $PI($P,next,$pc)
                set edges {}
                foreach tg [dict get $r tgts] { lappend edges @E${tg}@ [edgec $P $out $VK($key,in,$tg)] }
                append fn "    [string map $edges $code] [edgec $P $out $VK($key,in,$nx)]\n"
            }
            term { append fn "    $code\n" }
            dead { append fn "    $code\n" }
        }
        append stubs [dict get $r stub]
    }
    # ---- fall-back stubs: leave typed mode at this instruction.  A function running in its own frame writes its state into that frame
    # and continues in the boxed code; a function called directly (no frame) reports that the call must be made the ordinary way.
    set usedD {}
    foreach m [regexp -all -inline {goto D(\d+)} "$fn$stubs"] { if {![string match goto* $m]} { dict set usedD $m 1 } }
    if {[info exists ::env(TBC_REPORT)]} { set ::REPORT($key) [variantReport $key $P $tpcs $usedD DSITE] }
    foreach pc $tpcs {
        if {![dict exists $usedD $pc]} continue
        set in $VK($key,in,$pc)
        append fn "D$pc: ; TBC_HITI([cstring "D:$key:$pc"], [cstring $DSITE($key,$pc)]); [enterG $key $pc $in "" [flushSet $P $pc]]\n"
    }
    append fn $stubs
    # resume stubs of a proc with variables in the frame (see `fl`)
    foreach fk [lsort [array names FRM [globEsc $key],*]] {
        lassign [split [string range $fk [string length "$key,"] end] ,] fpc fm
        append fn "FR${fpc}_$fm: ; TBC_HIT([cstring "R:$key:$fpc"]); [enterG $key $fpc $FRM($fk) "" [flushSet $P $fpc]]\n"
    }

    # ---- failure chains, exit
    set masks {}
    foreach k [array names FM [globEsc $key],*] { lappend masks [string range $k [string length "$key,"] end] }
    foreach m [lsort -unique $masks] {
        set bits [expr {"0x$m"}]
        append fn "F$m: ;"
        for {set p 63} {$p >= 0} {incr p -1} { if {$bits & (1 << $p)} { append fn " Tcl_DecrRefCount(s$p);" } }
        append fn " goto redo_all;\n"
    }
    # an error in typed code, or a call that had to be made the ordinary way: the typed attempt had no effects, so the whole call is
    # started again in the boxed code (which produces the error exactly as the interpreter would, with its error info), or, in a function
    # that has no frame, the caller is told to make the call the ordinary way
    if {$resume} {
        # (nothing in a copy that resumes starts the call again: failures resume at the failing instruction)
        append fn "redo_all:\n    Tcl_SetObjResult(interp, Tcl_NewStringObj(\"tbc: restart in a resumed body\", -1)); rc = TCL_ERROR; goto ret;\n"
    } else {
    append fn "redo_all:\n    if (!inframe) \{ tbc_st = 3; rc = TCL_OK; goto ret; \}\n    Tcl_ResetResult(interp); tbc_st = 0;\n"
    append fn "    \{ int g_ = G_${cid}(interp, 0, NULL, 0);[expr {$PI($P,hasYield) ? " if (TBC_UNLIKELY(tbc_susp)) { tbc_st = 4; rc = TCL_OK; goto ret; }" : ""}] if (g_ == TCL_OK) \{ tbc_box = tbc_takeres(interp); tbc_st = 1; rc = TCL_OK; \} else \{ rc = g_; \} \}\n"
    }
    append fn "ret:\n"
    for {set v 0} {$v < $nv} {incr v} { append fn "    if (l$v) Tcl_DecrRefCount(l$v);[expr {[dict get $kap $v] eq "A" ? " free(av$v.p);" : [dict get $kap $v] eq "M" ? " tbc_imap_free(&mv$v);" : [dict get $kap $v] eq "R" ? " tbc_rfree(&rv$v);" : ""}]\n" }
    append fn "early:\n    if (rc != TCL_OK) \{ tbc_st = 2; tbc_rc = rc; \}\n    return rv;\n\}\n"
    # scratch vectors and maps of the stack slots are declared only where used (they would cost a zeroed frame on every call otherwise)
    set decls ""
    for {set k 0} {$k < $maxd2} {incr k} {
        if {[string first "sv$k" $fn] >= 0} { append decls "    tbc_ivec sv$k = {NULL, 0}; (void) sv$k;\n" }
        if {[string first "qv$k" $fn] >= 0} { append decls "    tbc_imap qv$k; memset(&qv$k, 0, sizeof qv$k);\n" }
        if {[string first "kb$k" $fn] >= 0} { append decls "    char kb$k\[104\]; int kl$k = 0; (void) kl$k;\n" }
        if {[string first "ka$k" $fn] >= 0} { append decls "    int64_t ka$k = 0, kj$k = 0; (void) ka$k; (void) kj$k;\n" }
    }
    set fn [string map [list @@VECDECLS@@ $decls] $fn]
    # a variant that was entered from the boxed code, and every hand-over from it, must not make the boxed code enter typed code again (see osrAttempt)
    if {$osrHere} { set fn [regsub -all "G_${cid}\\(interp," $fn "TBC_GNOF(resumed_, G_${cid}, interp,"] }
    return $fn
}

# ================================================================== driver
# entry signatures
set hints {}
if {$hintFile ne ""} {
    set f [open $hintFile]; set txt [read $f]; close $f
    # (names as in the proc listing: fully qualified)
    foreach l [split $txt \n] { if {[llength $l] >= 2} { set hn [lindex $l 0]; dict set hints [expr {[string match ::* $hn] ? $hn : "::$hn"}] [lrange $l 1 end] } }
}
# the `args` parameter is always a list: boxed
# A signature from how the body uses each argument (decision 41): I for an argument that some use takes as a number (arithmetic, a numeric comparison,
# `incr`, an index of lindex/lset/string index), B for one that is only passed on, used as a name (upvar), as text or as a container.  A proc that takes a
# count and an array name gets the variant IB, where the all-integer variant could never be chosen and the generic one hands over at the arithmetic.
proc useSig {P} {
    global PI
    set num {}
    set numops {add sub mult div mod expon lt gt le ge eq neq bitand bitor bitxor lshift rshift uminus uplus tryCvtToNumeric}
    foreach pc $PI($P,reach) {
        lassign $PI($P,ins,$pc) op a
        if {$op in {incrScalar1 incrScalar1Imm incrScalar4 incrScalar4Imm}} { set v [operand [lindex $a 0]]; if {$v < $PI($P,nargs)} { dict set num $v 1 } }
        if {$op ni {loadScalar1 loadScalar4}} continue
        set v [operand [lindex $a 0]]
        if {$v >= $PI($P,nargs) || [dict exists $num $v]} continue
        set users [slotUsers $P $pc $PI($P,depth,$pc)]
        foreach u $users {
            lassign $u uop pos upc
            if {$uop in $numops || ($uop in {listIndex strindex} && $pos == 0) || ($uop eq "lsetList" && $pos == 1)} { dict set num $v 1; break }
        }
    }
    set sig ""
    for {set v 0} {$v < $PI($P,nargs)} {incr v} { append sig [expr {[dict exists $num $v] ? "I" : "B"}] }
    return $sig
}
proc fixSig {P sig} {
    global PI
    set i $PI($P,argsIdx)
    if {$i >= 0 && [string length $sig] > $i} { set sig [string replace $sig $i $i B] }
    return $sig
}
foreach P $translatable {
    set k $PI($P,nargs)
    newVariant $P [string repeat B $k]
    if {$typedMode && $PI($P,wadapt)} { newVariant $P [string repeat B $k]w }
    set entries [list [string repeat B $k]]
    if {$typedMode} {
        set sigs [list [fixSig $P [string repeat I $k]]]
        lappend sigs [fixSig $P [useSig $P]]
        if {[dict exists $hints $P]} { set sigs [concat [lmap h [dict get $hints $P] {fixSig $P $h}] $sigs] }
        foreach s [lsort -unique $sigs] {
            if {[string length $s] != $k || [regexp {[^IDB]} $s]} continue
            newVariant $P $s
            if {$s ne [string repeat B $k]} { lappend entries $s }
        }
    }
    set ENTRIES($P) $entries
}

# fixpoint over all variants: result kinds and the set of variants (discovered through direct calls)
set round 0
while 1 {
    set changed 0
    foreach key $variants { if {[analyze $key]} { set changed 1 } }
    if {!$changed} {
        # results that never became known (functions that never return normally) are boxed
        foreach key $variants { if {$VK($key,ret) in {- U}} { set VK($key,ret) B; set changed 1 } }
        if {!$changed} break
    }
    if {[incr round] > 50} { error "type analysis did not converge" }
}

# which variants can be re-entered through their own calls (need the recursion-depth guard)?
foreach key $variants { set edges($key) {} }
foreach key $variants {
    lassign [keysplit $key] P sig
    foreach pc [array names VK [globEsc $key],in,*] {
        set pc [string range $pc [string length "$key,in,"] end]
        set r [stepT $key $pc $VK($key,in,$pc)]
        foreach c [dict get $r calls] { lappend edges($key) [lindex $c 0]/[lindex $c 1] }
    }
}
proc reaches {from to} {
    global edges
    set seen {}; set todo $edges($from)
    while {[llength $todo]} {
        set x [lindex $todo end]; set todo [lrange $todo 0 end-1]
        if {$x eq $to} { return 1 }
        if {$x in $seen} continue
        lappend seen $x
        set todo [concat $todo $edges($x)]
    }
    return 0
}
foreach key $variants { set REC($key) [reaches $key $key] }

# ---- output
# the procs whose generic variant has a copy that goes on in typed code after a yield
set REKEY {}
set OSRKEY {}
set OSRKEYW {}
if {$typedMode} {
    foreach P $translatable {
        set gk $P/[string repeat B $PI($P,nargs)]
        if {[info exists VK($gk,kap)] && [llength [resumePoints $gk]]} { if {$PI($P,hasYield)} { dict set REKEY $P $gk } else { dict set OSRKEY $P $gk } }
        set wk ${gk}w
        if {[info exists VK($wk,kap)] && [llength [resumePoints $wk]]} { dict set OSRKEYW $P $wk }
    }
}
if {[info commands ::tbc::fingerprint] eq ""} { error "translate.tcl must run under tcl-aot-sh, a tclsh with tbc::fingerprint linked in (tools/translator-shell.c)" }
set out "/* Generated by tcl-aot (translate.tcl) from [file tail $srcFile]: [llength $translatable] procs, [llength $variants] typed variants.\n * Do not edit. */\n#include \"tbc_hook.h\"\n\n/*@@DC@@*/\n"
foreach P $translatable {
    set cid [cident $P]
    append out "static int tbc_valid_$cid = 0;\n"
    if {$PI($P,wadapt)} { append out "static int tbc_wp_$cid = 0;\n" }
    append out ""
    set i 0
    foreach l $PI($P,lits) { append out "static Tcl_Obj *L_[cident $P]_$i;\n"; incr i }
}
append out "\n"
proc vproto {key} {
    global PI VK
    lassign [keysplit $key] P sig
    set plist {}
    for {set v 0} {$v < $PI($P,nargs)} {incr v} { lappend plist [ctype [string index $sig $v]] }
    return "[rettype $VK($key,ret)] V_[cident $P]_${sig}(Tcl_Interp *, int, int[expr {[llength $plist] ? ", " : ""}][join $plist {, }]);\n"
}
proc gproto {P} { return "int G_[cident $P](Tcl_Interp *, int, Tcl_Obj **, int);\n" }
foreach key $variants { append out "static [vproto $key]" }
dict for {P gk} $REKEY { append out "static [rettype [expr {$VK($gk,ret) in {- U} ? "B" : $VK($gk,ret)}]] V_[cident $P]_RE(Tcl_Interp *, int, int, Tcl_Obj **, int);\n" }
foreach P $translatable { append out "static [gproto $P]" }
append out "\n"
foreach key $variants {
    set t [emitVariant $key $REC($key)]
    append out $t "\n"
    lassign [keysplit $key] P sig
    append VTXT($P) $t "\n"
}
dict for {P gk} $REKEY { set t [emitVariant $gk $REC($gk) 1]; append out $t "\n"; append VTXT($P) $t "\n" }
foreach P $translatable { set t [emitG $P]; append out $t "\n"; set GTXT($P) $t }
# every literal entry into the boxed code that generated code makes must have a case in the entry switch of that proc (a missing one would run `default`)
foreach P $translatable { set G2P([cident $P]) $P }
foreach {all c n} [concat [regexp -all -inline {\yG_(\w+)\(interp, (-?\d+),} $out] [regexp -all -inline {TBC_GNOF\(resumed_, G_(\w+), interp, (-?\d+),} $out]] {
    if {$n == 0 || ![info exists G2P($c)]} continue
    if {[string first "    case $n: " $GTXT($G2P($c))] < 0} { error "internal error: the boxed code of $G2P($c) is entered at instruction $n and has no case for it" }
}
set outAfterG [string length $out]

proc entryCall {cid s cargs rk ind} {
    set call "V_${cid}_${s}(interp, tbc_maxdepth - ((Interp *) interp)->numLevels + TBC_REMK, 1[expr {[llength $cargs] ? ", " : ""}][join $cargs {, }])"
    switch $rk {
        I { return "${ind}\{ int64_t r_ = $call; if (tbc_st) return tbc_finish(interp); Tcl_SetObjResult(interp, Tcl_NewWideIntObj(r_)); return TCL_OK; \}\n" }
        D { return "${ind}\{ double r_ = $call; if (tbc_st) return tbc_finish(interp); Tcl_SetObjResult(interp, Tcl_NewDoubleObj(r_)); return TCL_OK; \}\n" }
        default { return "${ind}\{ Tcl_Obj *r_ = $call; if (tbc_st) return tbc_finish(interp); Tcl_SetObjResult(interp, r_); Tcl_DecrRefCount(r_); return TCL_OK; \}\n" }
    }
}

proc sigOrder {a b} {
    set na [string length [string map {B {}} $a]]; set nb [string length [string map {B {}} $b]]
    if {$na != $nb} { return [expr {$nb - $na}] }
    return [string compare $a $b]
}
# the entry of a compiled body: the interpreter has set up the frame and bound the arguments; pick a typed variant if they fit
foreach P $translatable {
    set cid [cident $P]; set k $PI($P,nargs)
    # (the most specific signature first: the first that fits the arguments is taken)
    set sigs [lsort -command sigOrder [lsort -unique $ENTRIES($P)]]
    set e "static int tbc_nat_${cid}(Tcl_Interp *interp, Proc *procPtr)\n\{\n    Var *loc_ = ((Interp *) interp)->varFramePtr->compiledLocals;\n    Tcl_Obj *objv\[[expr {$k+1}]\];\n    (void) procPtr;\n    objv\[0\] = NULL;\n"
    for {set v 0} {$v < $k} {incr v} { append e "    objv\[[expr {$v+1}]\] = loc_\[$v\].value.objPtr;\n" }
    append e "    tbc_maxdepth = Tcl_SetRecursionLimit(interp, 0);\n"
    set generic [string repeat B $k]
    if {$PI($P,wadapt)} {
        set wcargs {}
        for {set v 0} {$v < $k} {incr v} { lappend wcargs "objv\[[expr {$v+1}]\]" }
        append e "    if (tbc_wp_$cid) return G_${cid}(interp, 0, NULL, 0);\n"
    }
    foreach s $sigs {
        if {$s eq $generic} continue
        set key $P/$s
        set decl ""; set tests {}; set cargs {}
        for {set v 0} {$v < $k} {incr v} {
            switch [string index $s $v] {
                I { append decl " int64_t a$v;"; lappend tests "tbc_arg_int(objv\[[expr {$v+1}]\], &a$v)" }
                D { append decl " double a$v;"; lappend tests "tbc_arg_dbl(objv\[[expr {$v+1}]\], &a$v)" }
                B { lappend tests 1; append decl " Tcl_Obj *a$v = objv\[[expr {$v+1}]\];" }
            }
            lappend cargs a$v
        }
        set rk $VK($key,ret)
        append e "    \{$decl\n        if ([expr {[llength $tests] ? [join $tests { && }] : 1}]) \{\n"
        append e [entryCall $cid $s $cargs $rk "            "]
        append e "        \}\n    \}\n"
    }
    set gcargs {}
    for {set v 0} {$v < $k} {incr v} { lappend gcargs "objv\[[expr {$v+1}]\]" }
    append e [entryCall $cid $generic $gcargs $VK($P/$generic,ret) "    "]
    append e "\}\n\n"
    append out $e
}
# canonical argument list (names, defaults) as the interpreter's Proc holds it: name, or name \003 default, joined by \002
proc canonArgs {P} { join $::PI($P,infoArgs) "\002" }
# The built-ins the compiled code was analysed against.  The module lists the distinct names, the distinct namespaces they are looked up from and the pairs;
# each entry lists its pairs (those of the procs it calls included).  The runtime checks them when the proc is entered (see tbc_guard_ok).
set gnames {}; set gnss {}; set gall {}
foreach P $translatable {
    foreach d [gdeps $P] {
        lassign $d n sp
        if {$n ni $gnames} { lappend gnames $n }
        if {$sp ni $gnss} { lappend gnss $sp }
        if {$d ni $gall} { lappend gall $d }
    }
}
set gall [lsort $gall]
if {[llength $gall]} {
    append out "static const char *const tbc_gn_${initName}\[\] = { [join [lmap n $gnames {cstring $n}] {, }] };\n"
    append out "static const char *const tbc_gs_${initName}\[\] = { [join [lmap n $gnss {cstring $n}] {, }] };\n"
    append out "static const TbcGDep tbc_gd_${initName}\[\] = { [join [lmap d $gall {format "{%d, %d}" [lsearch -exact $gnames [lindex $d 0]] [lsearch -exact $gnss [lindex $d 1]]}] {, }] };\n"
    append out "static TbcGuard tbc_guard_${initName} = { tbc_gn_${initName}, [llength $gnames], tbc_gs_${initName}, [llength $gnss], tbc_gd_${initName}, [llength $gall] };\n"
}
foreach P $translatable {
    set cid [cident $P]
    set ns [namespace qualifiers $P]; if {$ns eq ""} { set ns :: }
    set fp $PI($P,fp)
    set gx [lmap d [gdeps $P] {lsearch -exact $gall $d}]
    if {[llength $gx]} { append out "static const unsigned short tbc_gx_$cid\[\] = { [join $gx {, }] };\n" }
    if {[llength [ydeps $P]]} { append out "static int *tbc_yd_$cid\[\] = { [join [lmap c [ydeps $P] {string cat &tbc_valid_[cident $c]}] {, }], NULL };\n" }
    append out "static TbcEntry tbc_e_$cid = \{ [cstring $P], [cstring $ns], [cstring [canonArgs $P]], [cstring $PI($P,infoBody)], UINT64_C(0x$fp), tbc_nat_$cid, &tbc_valid_$cid, 0, NULL, [expr {$P in $ysafeProcs ? 1 : 0}], [expr {[llength [ydeps $P]] ? "tbc_yd_$cid" : "NULL"}], [expr {[llength $gx] ? "tbc_gx_$cid" : "NULL"}], [llength $gx], [expr {[llength $gx] ? "&tbc_guard_$initName" : "NULL"}], [expr {$P in $yresProcs ? 1 : 0}], [ensMask $P] \};\n"
}
# the procs left to the interpreter, with the reason, so that tbc::report can say why a definition equal to one of them is not compiled
if {[llength $refusedProcs]} {
    append out "static const TbcRefused tbc_refused_$initName\[\] = \{\n"
    foreach pr $refusedProcs {
        lassign $pr P why
        set ns [namespace qualifiers $P]; if {$ns eq ""} { set ns :: }
        append out "    \{ [cstring $P], [cstring $ns], [cstring [canonArgs $P]], [cstring $PI($P,infoBody)], [cstring $why] \},\n"
    }
    append out "\};\n"
}
set regId 0
append out "\nint ${initName}_Init(Tcl_Interp *interp)\n\{\n    if (tbc_check_build(interp) != TCL_OK) return TCL_ERROR;\n    /* (the registry of compiled bodies and the guard's pinned commands are the process's, and serve the first interpreter the module is initialised in: a later
     * initialisation, in that interpreter again or in another one, changes nothing, and the procs of another interpreter run interpreted - decision 40) */
    \{ static Tcl_Interp *first_; if (first_) return TCL_OK; first_ = interp; \}\n    tbc_rt_init();\n    tbc_capture_builtins(interp);\n    tbc_install(interp);\n"
if {[llength $gall]} { append out "    tbc_guard_register(interp, &tbc_guard_$initName);\n" }
# the pinned commands that typed code calls directly (tbc_direct): from the guard's table, or none for a name the guard does not hold
dict for {nm id} $DCNAMES {
    set gi [lsearch -exact $gnames $nm]
    append out "    tbc_$id = [expr {$gi >= 0 ? "tbc_guard_cmd(&tbc_guard_$initName, $gi)" : "NULL"}];\n"
}
foreach P $translatable {
    set i 0
    foreach l $PI($P,lits) {
        set e [lindex $PI($P,litd) $i]
        if {$e ne ""} { append out "    L_[cident $P]_$i = tbc_lit_d($e);\n" } else { append out "    L_[cident $P]_$i = tbc_lit([cstring $l], [cbytes $l]);\n" }
        incr i
    }
    append out "    tbc_register(interp, &tbc_e_[cident $P], [incr regId]);\n"
}
if {[llength $refusedProcs]} { append out "    tbc_register_refused(tbc_refused_$initName, [llength $refusedProcs]);\n" }
append out "#ifdef TBC_COV\n    Tcl_CreateObjCommand(interp, \"::tbc_coverage\", tbc_cov_cmd, NULL, NULL);\n    Tcl_CreateObjCommand(interp, \"::tbc::hot\", tbc_hot_cmd, NULL, NULL);\n#endif\n"
append out "    return TCL_OK;\n\}\n"

set dcDecl ""; set dcExtern ""; set dcDef ""
dict for {nm id} $DCNAMES { append dcDecl "static Command *tbc_$id;\n"; append dcExtern "extern Command *tbc_$id;\n"; append dcDef "Command *tbc_$id;\n" }
if {$splitN > 0} {
    # the same code in several files: what is shared between them has external linkage and is declared in a header; the typed code and the boxed code are
    # in files of their own (so that they can be compiled at different optimisation levels, and in parallel)
    set base [file rootname $outFile]; set tail [file tail $base]
    set hdr "/* Generated by tcl-aot (translate.tcl) from [file tail $srcFile]: the shared declarations of the split module $initName. Do not edit. */\n#ifndef TBC_[string toupper [cident $initName]]_H\n#define TBC_[string toupper [cident $initName]]_H\n#include \"tbc_hook.h\"\n\n"
    foreach P $translatable {
        set cid [cident $P]
        append hdr "extern int tbc_valid_$cid;\n"
        if {$PI($P,wadapt)} { append hdr "extern int tbc_wp_$cid;\n" }
        for {set i 0} {$i < [llength $PI($P,lits)]} {incr i} { append hdr "extern Tcl_Obj *L_${cid}_$i;\n" }
    }
    append hdr $dcExtern
    foreach key $variants { append hdr [vproto $key] }
    foreach P $translatable { append hdr [gproto $P] }
    dict for {P gk} $REKEY { append hdr "[rettype [expr {$VK($gk,ret) in {- U} ? "B" : $VK($gk,ret)}]] V_[cident $P]_RE(Tcl_Interp *, int, int, Tcl_Obj **, int);\n" }
    append hdr "\n#endif\n"
    set f [open $base.h w]; puts -nonewline $f $hdr; close $f
    # the files of the typed code and of the boxed code: contiguous runs of procs of about equal size
    proc splitGroups {texts n} {
        upvar $texts T
        global translatable
        set total 0; foreach P $translatable { incr total [string length $T($P)] }
        set groups {}; set cur {}; set acc 0; set want [expr {($total + $n - 1) / $n}]
        foreach P $translatable {
            lappend cur $P; incr acc [string length $T($P)]
            if {$acc >= $want && [llength $groups] < $n - 1} { lappend groups $cur; set cur {}; set acc 0 }
        }
        if {[llength $cur]} { lappend groups $cur }
        return $groups
    }
    set files {}
    foreach {kind arr} {v VTXT g GTXT} {
        set i 0
        foreach grp [splitGroups $arr $splitN] {
            incr i
            set txt "/* Generated by tcl-aot (translate.tcl): part $i of the [expr {$kind eq "v" ? "typed" : "boxed"}] code of $initName. Do not edit. */\n#define TBC_SPLIT_USER 1\n#include \"$tail.h\"\n\n"
            foreach P $grp {
                if {$kind eq "v"} { append txt $VTXT($P) } else { append txt $GTXT($P) "\n" }
            }
            # the definitions have external linkage here (they are declared in the header); the static helper tables inside functions keep theirs
            set txt [string map {"\nstatic int V_" "\nint V_" "\nstatic int64_t V_" "\nint64_t V_" "\nstatic double V_" "\ndouble V_" "\nstatic Tcl_Obj * V_" "\nTcl_Obj * V_" "\nstatic int G_" "\nint G_"} $txt]
            set fname ${base}_${kind}${i}.c
            set f [open $fname w]; puts -nonewline $f $txt; close $f
            lappend files $fname
        }
    }
    set init "/* Generated by tcl-aot (translate.tcl): the tables and Init of $initName (and the entry wrappers). Do not edit. */\n#define TBC_SPLIT_OWNER 1\n#include \"$tail.h\"\n\n"
    foreach P $translatable {
        set cid [cident $P]
        append init "int tbc_valid_$cid = 0;\n"
        if {$PI($P,wadapt)} { append init "int tbc_wp_$cid = 0;\n" }
        for {set i 0} {$i < [llength $PI($P,lits)]} {incr i} { append init "Tcl_Obj *L_${cid}_$i;\n" }
    }
    append init $dcDef "\n" [string range $out $outAfterG end]
    set f [open $outFile w]; puts -nonewline $f $init; close $f
    puts "tcl-aot: split into [llength $files] code files + $base.h + $outFile"
} else {
    set out [string map [list "/*@@DC@@*/" $dcDecl] $out]
    set f [open $outFile w]; puts -nonewline $f $out; close $f
}
puts "tcl-aot: [llength $translatable] of [llength $procNames] procs compiled, [llength $variants] variants"
if {[info exists ::env(TBC_REPORT)]} {
    # typed: instructions of the variant that have typed code; reach: all reachable instructions of the proc (what follows an unsupported one runs boxed)
    foreach key $variants {
        if {![info exists ::REPORT($key)]} continue
        lassign $::REPORT($key) reach typed guarded uns kinds ret
        set nuns [llength $uns]
        puts stderr [format "REPORT %-34s %3d instructions, %3d typed (%d%%), %3d guarded, %d unsupported; returns %s; locals %s" $key $reach $typed [expr {$reach ? $typed * 100 / $reach : 0}] $guarded $nuns $ret [join $kinds " "]]
        foreach u $uns { puts stderr "REPORT     unsupported: $u" }
    }
}
foreach key $variants { puts "  $key  ret=$VK($key,ret)  kinds=[dict values $VK($key,kap)]  [expr {$REC($key) ? "recursive" : ""}]" }
