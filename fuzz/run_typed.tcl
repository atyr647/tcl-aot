# Differential fuzz run (see fuzz/run.sh): all random procs and calls with the interpreter alone, then with the compiled module.
source [file join [file dirname [info script]] fuzz_procs.tcl]
proc dbl {v} { expr {double($v)} }
proc fa_reset {} { set ::fzg 0; array unset ::fzga; set ::g 0; array unset ::ga; namespace eval ::fzns {}; set ::fzns::g 0 }
set calls {}
source [file join [file dirname [info script]] fuzz_calls.tcl]
proc runall {} {
    global calls
    set out {}
    foreach c $calls {
        set rc [catch $c r opts]
        lappend out [list $rc $r [expr {$rc == 1 && [dict exists $opts -errorcode] ? [dict get $opts -errorcode] : "-"}]]
    }
    return $out
}
set A [runall]
load {} Fuzzprocs
source [file join [file dirname [info script]] fuzz_procs.tcl]
set fzp [concat [info commands fz_*] [info commands fl_*] [info commands fv_*] [info commands fm_*]]
set translated [llength [tbc::attached]]
puts "translated: $translated of [llength $fzp] procs; [llength $calls] calls"
set B [runall]
# (attached at their first call by default: the count that matters is the one after the calls)
set attachedAfter [llength [tbc::attached]]
puts "attached after the calls: $attachedAfter"
if {$attachedAfter == 0 && [llength [info commands ::tbc::e*]] > 0} { puts "NO COMPILED BODY RAN: the comparison above would be of the interpreter with itself"; exit 1 }
set bad 0; set errs 0; set i 0
foreach a $A b $B c $calls {
    if {[lindex $a 0] == 1} { incr errs }
    if {$a ne $b} {
        incr bad
        if {$bad <= 15} { puts "MISMATCH $c\n  interpreted: $a\n  translated:  $b" }
    }
}
puts "[llength $A] fuzz calls compared ($errs raised errors), $bad mismatches"
if {[llength [info commands tbc_coverage]]} {
    array set cov [tbc_coverage]
    set ents 0; set dp 0; set dn 0
    foreach {k v} [array get cov] { if {[string match V:* $k]} { incr ents } elseif {[string match D:* $k]} { incr dp; incr dn $v } }
    puts "coverage: $ents variants entered; $dp distinct deopt points taken ($dn deopts)"
    # the frame-variable programs: how many ran typed, and how often they left typed mode
    set fv 0; set fvn 0; set fd 0; set fdn 0; set fr 0
    foreach {k v} [array get cov] {
        if {[string match V:::fa_* $k]} { incr fv; incr fvn $v } elseif {[string match D:::fa_* $k]} { incr fd; incr fdn $v } elseif {[string match R:::fa_* $k]} { incr fr $v }
    }
    puts "coverage of the frame-variable programs: $fv variants entered $fvn times; $fd deopt points taken $fdn times; $fr resumes"
}
exit [expr {$bad ? 1 : 0}]
