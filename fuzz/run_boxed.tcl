# Differential fuzz run (see fuzz/run.sh): random string/list/dict/array/flow programs with the interpreter alone, then with the compiled module; results, error codes and error info.
source [file join [file dirname [info script]] fuzz_procs2.tcl]
set calls {}
source [file join [file dirname [info script]] fuzz_calls2.tcl]
proc runall {} {
    global calls
    set out {}
    foreach c $calls {
        set rc [catch [string reverse [string reverse $c]] r opts]
        lappend out [list $rc $r [expr {$rc == 1 ? [list [dict get $opts -errorcode] [dict get $opts -errorinfo] [dict get $opts -errorline]] : "-"}]]
    }
    return $out
}
set A [runall]
load {} Fuzzprocs2
source [file join [file dirname [info script]] fuzz_procs2.tcl]
set translated [llength [tbc::attached]]
puts "translated: $translated of [llength [info commands fg_*]] procs; [llength $calls] calls"
set B [runall]
# (attached at their first call by default: the count that matters is the one after the calls)
set attachedAfter [llength [tbc::attached]]
puts "attached after the calls: $attachedAfter"
if {$attachedAfter == 0 && [llength [info commands ::tbc::e*]] > 0} { puts "NO COMPILED BODY RAN: the comparison above would be of the interpreter with itself"; exit 1 }
set bad 0; set errs 0
foreach a $A b $B c $calls {
    if {[lindex $a 0] == 1} { incr errs }
    if {$a ne $b} {
        incr bad
        if {$bad <= 8} { puts "MISMATCH $c\n  interpreted: $a\n  translated:  $b" }
    }
}
puts "[llength $A] fuzz2 calls compared ($errs raised errors), $bad mismatches"
exit [expr {$bad ? 1 : 0}]
