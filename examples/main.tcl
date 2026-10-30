# The program: starts the compiled module if the shell has one linked in, defines its procs as usual, and runs.
if {[info exists ::env(COMPILED)]} { load {} Collatz }
source [file join [file dirname [info script]] collatz.tcl]
set t0 [clock milliseconds]
puts [longest 30000]
puts "[expr {[clock milliseconds] - $t0}] ms"
if {[info exists ::env(COMPILED)]} { puts [tbc::report -text] }
