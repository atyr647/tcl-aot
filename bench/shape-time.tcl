# usage: <shell> bench/shape-time.tcl   (COMPILED=Name loads the compiled module first): CPU microseconds of the three styles of bench/shape.tcl, 1024 entities, 90x90 grid, 400 ticks
if {[info exists ::env(COMPILED)]} { load {} $::env(COMPILED) }
source [file join [file dirname [info script]] shape.tcl]
proc cpu {} { set f [open /proc/self/schedstat]; set l [read $f]; close $f; expr {[lindex $l 0] / 1000.0} }
set n 1024; set w 90; set ticks 400
ns::init $n $w
set a [cpu]; set rA [ns::runA $ticks]; set b [cpu]; set rB [runB $n $w $ticks]; set c [cpu]; set rC [runC $n $w $ticks]; set d [cpu]
puts [format "A(namespace lists) %.0f us   B(local lists) %.0f us   C(local arrays) %.0f us   checksums %s %s %s" [expr {$b-$a}] [expr {$c-$b}] [expr {$d-$c}] $rA $rB $rC]
