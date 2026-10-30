# the way compiled bodies are attached to procs as they are defined: `proc` is the interpreter's own command, wrapped, with nothing visible to the program
# (run with the shell tests/run.sh builds; eager attach, where the attach shows at once)
set fails 0
proc check {what got want} { if {$got ne $want} { puts "FAIL $what: got {$got} want {$want}"; incr ::fails } else { puts "ok   $what" } }
load {} Testprocs
tbc::attach eager
check "no execution trace on proc" [trace info execution proc] {}
check "no execution trace on trace" [trace info execution trace] {}
check "proc is still a command of the global namespace" [info commands ::proc] ::proc
namespace eval tns { variable v 10 }
# defined from another namespace's frame with uplevel: the proc belongs to the frame uplevel runs in
namespace eval zz { uplevel #0 {proc ta_nsupvar {} { namespace upvar ::tns v lv; incr lv; return $lv }} }
check "defined with uplevel from a namespace: attached" [expr {"::ta_nsupvar" in [tbc::attached]}] 1
check "and it runs" [ta_nsupvar] 11
# defined in a procedure's frame with uplevel 1 into a namespace
namespace eval t::ns {}
proc definer {} { uplevel 1 {proc p {x {y 1}} { return [expr {$x + $y}] }} }
namespace eval t::ns { definer }
check "defined with uplevel 1 from a proc: attached in the frame's namespace" [expr {"::t::ns::p" in [tbc::attached]}] 1
check "not in the global namespace" [expr {"::p" in [tbc::attached]}] 0
check "t::ns::p runs" [t::ns::p 4] 5
# a user-level wrapper around the renamed proc command still gets its definitions compiled
rename proc proc_orig
proc_orig proc {name args body} { set ::nproc [expr {[info exists ::nproc] ? $::nproc + 1 : 1}]; uplevel 1 [list proc_orig $name $args $body] }
proc ta_catch_opts {x} { catch {expr {10 / $x}} r o; return [list $r [dict get $o -code] [dict exists $o -errorcode]] }
check "defined through a program's own proc: counted" $::nproc 1
check "defined through a program's own proc: attached" [expr {"::ta_catch_opts" in [tbc::attached]}] 1
check "runs" [ta_catch_opts 0] {{divide by zero} 1 1}
# errors in the definition leave nothing attached and are reported as the interpreter reports them
check "wrong # args" [catch {proc a b} m] 1
check "message" $m {wrong # args: should be "proc name args body"}
check "bad arg list" [catch {proc bad {{a b c}} {}} m] 1
puts [expr {$fails ? "$fails FAILED" : "all proc wrapper checks passed"}]
exit [expr {$fails ? 1 : 0}]
