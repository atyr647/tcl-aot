# Generates fuzz_procs.tcl (random procs), fuzz_hints.txt and fuzz_calls.tcl in the current directory.  Deterministic for a given seed.
#
#   tcl-aot-sh gen_typed.tcl seed nexpr nloop ncalls nvec nmap
#
# Arithmetic over integers and doubles (fz_), loops (fl_), integer vectors (fv_), integer maps (fm_), and programs that mix typed arithmetic with
# arrays and with links made by upvar, global and namespace upvar (fa_).  Driven by fuzz/run.sh.
set seed [expr {$argc > 0 ? [lindex $argv 0] : 7}]
set nexpr [expr {$argc > 1 ? [lindex $argv 1] : 200}]
set nloop [expr {$argc > 2 ? [lindex $argv 2] : 100}]
set ncalls [expr {$argc > 3 ? [lindex $argv 3] : 150}]
expr {srand($seed)}
proc pick {l} { lindex $l [expr {int(rand() * [llength $l])}] }
set ilits {0 1 2 3 7 -1 -5 100 2147483648 4611686018427387904 9223372036854775807}
set dlits {0.5 1.5 2.0 -3.25 1e10 0.1}
proc leaf {vars} {
    global ilits dlits
    set r [expr {rand()}]
    if {$r < 0.6} { return "\$[pick $vars]" }
    if {$r < 0.85} { return [pick $ilits] }
    return [pick $dlits]
}
proc gen {vars depth} {
    if {$depth == 0 || rand() < 0.2} { return [leaf $vars] }
    set r [expr {rand()}]
    if {$r < 0.1} { return "([gen $vars [expr {$depth-1}]] ? [gen $vars [expr {$depth-1}]] : [gen $vars [expr {$depth-1}]])" }
    set op [pick {+ + - - * * / % < <= > >= == !=}]
    return "([gen $vars [expr {$depth-1}]] $op [gen $vars [expr {$depth-1}]])"
}
set p [open fuzz_procs.tcl w]; set h [open fuzz_hints.txt w]
for {set k 0} {$k < $nexpr} {incr k} {
    puts $p "proc fz_$k {a b} { return \[expr {[gen {a b} 4]}\] }"
    puts $h "fz_$k II ID DI DD"
}
for {set k 0} {$k < $nloop} {incr k} {
    set op [pick {+ - * / %}]
    puts $p "proc fl_$k {n a} {\n    set s \$a\n    for {set i 0} {\$i < \$n} {incr i} { set s \[expr {[gen {s i a} 2]}\] }\n    return \$s\n}"
    puts $h "fl_$k II ID"
}
# int-vector programs: a list local built with lrepeat, read and written by index, aliased, re-created, returned or not
set nvec [expr {$argc > 4 ? [lindex $argv 4] : 60}]
proc idx {} { pick {{$i} {($i + 1)} {($i * 2)} {($a)} {(-1)} {($n)} {(($i + $a) % 7)} {0} {2}} }
proc vstmt {} {
    set val [gen {s i a} 1]
    set ix [idx]
    switch [expr {int(rand() * 9)}] {
        0 { return "lset v \[expr {$ix % \$len}\] \[expr {$val}\]" }
        1 { return "lset v \[expr {$ix}\] \[expr {$val}\]" }
        2 { return "set s \[expr {\$s + \[lindex \$v \[expr {$ix % \$len}\]\]}\]" }
        3 { return "set s \[expr {\$s + \[lindex \$v \[expr {$ix}\]\]}\]" }
        4 { return "set w \$v; incr s \[llength \$w\]" }
        5 { return "if {\[lindex \$v \[expr {$ix % \$len}\]\] > [pick {0 1 2}]} { incr s }" }
        6 { return "set v \[lrepeat \$len [pick {0 1 5 -3}]\]" }
        7 { return "incr s \[llength \$v\]; set s \[expr {\$s + \[lindex \$v end\]}\]" }
        8 { return "lset v [pick {0 1 2}] \[expr {$val}\]" }
    }
}
for {set k 0} {$k < $nvec} {incr k} {
    set body {}
    for {set j 0} {$j < 2 + int(rand() * 4)} {incr j} { lappend body "        [vstmt]" }
    set ret [pick {{return $s} {return $v} {return [list $s $v]} {return [list $s [lindex $v 0] [llength $v]]}}]
    puts $p "proc fv_$k {n a} {\n    set len \[expr {\$n % 9 + 1}\]\n    set v \[lrepeat \$len [pick {0 1 2}]\]\n    set s 0\n    for {set i 0} {\$i < \$n} {incr i} {\n[join $body \n]\n    }\n    $ret\n}"
    puts $h "fv_$k II ID"
}
# int-map programs
set nmap [expr {$argc > 5 ? [lindex $argv 5] : 40}]
proc mkey {} { pick {{$i} {[expr {$i % 4}]} {k$a} {x} {007} {[expr {$i * 7 % 5}]} {"k$i"} {$a}} }
proc mstmt {} {
    switch [expr {int(rand() * 8)}] {
        0 - 1 { return "dict incr d [mkey] [pick {1 1 2 -3 4611686018427387}]" }
        2 { return "if {\[dict exists \$d [mkey]\]} { incr s }" }
        3 { return "set s \[expr {\$s + \[dict get \$d [mkey]\]}\]" }
        4 { return "dict for {k v} \$d { incr s \$v }" }
        5 { return "incr s \[dict size \$d\]" }
        6 { return "set e \$d" }
        7 { return "incr s \[string length \[dict keys \$d\]\]" }
    }
}
for {set k 0} {$k < $nmap} {incr k} {
    set body {}
    for {set j 0} {$j < 2 + int(rand() * 4)} {incr j} { lappend body "        [mstmt]" }
    set ret [pick {{return $s} {return $d} {return [list $s $d]} {return [list $s [dict size $d]]}}]
    puts $p "proc fm_$k {n a} {\n    set d \[dict create\]\n    set s 0\n    for {set i 0} {\$i < \$n} {incr i} {\n[join $body \n]\n    }\n    $ret\n}"
    puts $h "fm_$k II ID"
}
# frame-variable programs: arrays with int and string keys and links to globals (upvar #0, global, namespace upvar), mixed with typed arithmetic
set nfa [expr {$argc > 6 ? [lindex $argv 6] : 50}]
proc akey {} { pick {{$i} {$i} {[expr {$i % 5}]} {[expr {$i * 3 - $a}]} {k$a} {x} {05} {5} {-1} {$a} {[expr {$i + 1}]} {"k$i"} {[expr {$i % 3}]}} }
proc aval {} { pick {{$i} {$a} {0} {1} {-7} {9223372036854775807} {abc} {1.5} {[expr {$i * 2}]} {$s} {0x10} {""} {[expr {$a + 0.5}]}} }
proc astmt {} {
    switch [expr {int(rand() * 20)}] {
        0 { return "set a([akey]) [aval]" }
        1 - 2 { return "incr a([akey])" }
        3 { return "incr a([akey]) [pick {1 -1 5 {$i} {$a} 9223372036854775807}]" }
        4 - 5 { return "set s \[expr {\$s + \$a([akey])}\]" }
        6 { return "if {\[info exists a([akey])\]} { incr s }" }
        7 { return "set s \[expr {\$s + \[info exists a([akey])\]}\]" }
        8 { return "incr g" }
        9 { return "incr g [pick {2 -3 {$i} {$a}}]" }
        10 { return "set g \[expr {\$g + \$i}\]" }
        11 { return "incr s \$g" }
        12 { return "incr ga([akey])" }
        13 { return "set ga([akey]) [aval]" }
        14 { return "set s \[expr {\$s + \$ga([akey])}\]" }
        15 { return "set b \$a([akey])" }
        16 { return "set s \[expr {\$s * 3 + \$i}\]" }
        17 { return "set g [aval]" }
        18 { return "unset -nocomplain a([akey])" }
        19 { return "incr s \[array size a\]" }
    }
}
for {set k 0} {$k < $nfa} {incr k} {
    set body {}
    for {set j 0} {$j < 2 + int(rand() * 5)} {incr j} { lappend body "        [astmt]" }
    set head [pick {{upvar #0 fzg g} {global g} {namespace upvar ::fzns g g} {variable g}}]
    set head2 [pick {{upvar #0 fzga ga} {upvar #0 fzga ga} {global ga}}]
    if {$head eq "variable g"} { set head "namespace eval ::fzns {}; namespace upvar ::fzns g g" }
    set ret [pick {{return [list $s [lsort [array get a]] $g]} {return [list $s $g [lsort [array get ga]]]} {return $s}}]
    puts $p "proc fa_$k {n a} {\n    $head\n    $head2\n    set s 0\n    for {set i 0} {\$i < \$n} {incr i} {\n[join $body \n]\n    }\n    $ret\n}"
    puts $h "fa_$k II ID"
}
close $p; close $h
set ivals {0 1 -1 2 -2 3 7 -7 10 -100 255 2147483647 2147483648 -2147483648 4294967296 9007199254740991 9007199254740992 9007199254740993 -9007199254740993 4611686018427387904 9223372036854775807 -9223372036854775807 -9223372036854775808}
set dvals {0.5 -0.5 1.5 2.0 -3.25 1e10 1e15 9007199254740992.0 1e-5 0.1 1e308 -1e308 0.0}
set c [open fuzz_calls.tcl w]
proc arg {} {
    global ivals dvals
    set r [expr {rand()}]
    if {$r < 0.55} { return [pick $ivals] }
    if {$r < 0.85} { return "\[dbl [pick $dvals]\]" }
    return [pick $dvals]
}
for {set k 0} {$k < $nexpr} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fz_$k [arg] [arg]}" }
}
for {set k 0} {$k < $nloop} {incr k} {
    for {set j 0} {$j < [expr {$ncalls/3}]} {incr j} { puts $c "lappend calls {fl_$k [expr {int(rand()*14)}] [arg]}" }
}
for {set k 0} {$k < $nvec} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fv_$k [expr {int(rand()*30)}] [arg]}" }
}
for {set k 0} {$k < $nmap} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fm_$k [expr {int(rand()*25)}] [arg]}" }
}
for {set k 0} {$k < $nfa} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fa_reset; fa_$k [expr {int(rand()*12)}] [arg]}" }
}
close $c
