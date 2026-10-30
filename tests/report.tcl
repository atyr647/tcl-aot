# tbc::report, tbc::profile and tbc::attach: exact checks of what they say (run with the shell tests/run.sh builds; TBC_EAGER=1 for eager attach)
set fails 0
proc check {what got want} { if {$got ne $want} { puts "FAIL $what: got {$got} want {$want}"; incr ::fails } else { puts "ok   $what" } }

# a proc defined before the module is loaded
proc early_proc {x} { expr {$x * 977 + 5} }
# the same definition as a proc in the module, but defined before the module is loaded
proc early_dup {x} { expr {$x + 1} }
load {} Testprocs
# run in the mode given in the environment (eager: attach at definition; lazy, the default: at the first call)
if {[info exists ::env(TBC_EAGER)] && $::env(TBC_EAGER) eq "1"} { tbc::attach eager }
set mode [tbc::attach status]
# the procs are defined while `string` is hidden: the interpreter compiles `string length` as a command call then, not as the inline instruction the module's
# code was compiled from, so the bytecode at definition does not match; once `string` is back the interpreter compiles it as the module's code expects
rename string string_hidden
source [file join [file dirname [info script]] procs.tcl]
set rs [tbc::report]
set byName0 {}; foreach e [dict get $rs procs] { dict set byName0 [lindex $e 0] $e }
# (eager: the mismatch shows at once; lazy: nothing is compiled until the first call)
if {$mode eq "eager"} { check "lazy test proc, eager: mismatch shows at once" [lindex [dict get $byName0 ::tz_lazy] 1] differs } else { check "lazy test proc, lazy: waiting for its first call" [expr {"::tz_lazy" in [dict get $rs pending_procs]}] 1 }
rename string_hidden string
check "lazy: not attached before its first call" [expr {[lsearch [tbc::attached] ::tz_lazy] < 0}] 1
check "lazy: first call computes" [tz_lazy abcd] 4
tz_trivial abc
check "trivial body: reported as trivial, not as a mismatch" [lindex [dict get [dict create {*}[concat {*}[lmap e [dict get [tbc::report] procs] {list [lindex $e 0] $e}]]] ::tz_trivial] 1] trivial
check "lazy: attached after its first call" [expr {[lsearch [tbc::attached] ::tz_lazy] >= 0}] 1
check "lazy: second proc, with a loop" [tz_lazy2 ab 3] 6
check "lazy: second proc attached too" [expr {[lsearch [tbc::attached] ::tz_lazy2] >= 0}] 1
check "lazy: compiled calls counted" [expr {[dict get [tbc::report] compiled_calls] >= 2}] 1

set r [tbc::report]
check "compiled count equals attached" [dict get $r compiled] [llength [tbc::attached]]
set byName {}; foreach e [dict get $r procs] { dict set byName [lindex $e 0] $e }

# a proc the module has no code for
proc brand_new {a b} { return [list $b $a] }
# a proc the module has code for, with another body
proc t_two {a b} { return [expr {$a * $b}] }
set r [tbc::report]; set byName {}; foreach e [dict get $r procs] { dict set byName [lindex $e 0] $e }
check "unknown proc: state" [lindex [dict get $byName ::brand_new] 1] no-code
check "unknown proc: reason" [lindex [dict get $byName ::brand_new] 2] "not in the module"
check "changed proc: state" [lindex [dict get $byName ::t_two] 1] changed
check "changed proc is not counted as compiled" [expr {[lsearch [tbc::attached] ::t_two] < 0}] 1
# the translator's refusals come with its reason (procs.tcl has procs that yield inside a dictionary iteration or an expansion, which stay interpreted: decision 5)
set refused [lmap e [dict get $r procs] {expr {[lindex $e 1] eq "refused" ? $e : [continue]}}]
check "refused procs are listed" [expr {[llength $refused] > 0}] 1
check "refused reason is the translator's" [expr {[regexp {^(opcode|yield) } [lindex [lindex $refused 0] 2]]}] 1
check "yield in a dictionary iteration is refused, with its reason" [lindex [dict get $byName ::ty_ydictfor] 2] "yield in a proc with a dictionary iteration"

# calls: compiled ones counted by the module, interpreted ones while profiling
set ref [t_arith 3 4]
tbc::profile on
set before [dict get [tbc::report] compiled_calls]
for {set i 0} {$i < 5} {incr i} { brand_new 1 2 }
for {set i 0} {$i < 3} {incr i} { t_arith 3 4 }
set after [tbc::report]
check "profile is on" [dict get $after profile] 1
set byName {}; foreach e [dict get $after procs] { dict set byName [lindex $e 0] $e }
check "interpreted proc: 5 calls" [lindex [dict get $byName ::brand_new] 3] 5
check "compiled calls grew by 3" [expr {[dict get $after compiled_calls] - $before}] 3
check "a compiled proc is not listed" [dict exists $byName ::t_arith] 0

# scripts evaluated at run time
eval {set ev 1}; eval {set ev 1}
uplevel #0 {set up 2}
namespace eval ::qq {set z 3}
set f [file join [file dirname [info script]] procs.tcl]
set sc {}; foreach e [dict get [tbc::report] scripts] { dict set sc "[lindex $e 0]|[lindex $e 3]" [lindex $e 1] }
check "eval seen twice" [dict get $sc "eval|set ev 1"] 2
check "uplevel seen once" [dict get $sc "uplevel|set up 2"] 1
check "namespace eval seen once" [dict get $sc "namespace eval|set z 3"] 1

# profiling does not disturb what is attached
set att [llength [tbc::attached]]
tbc::profile off
check "profile is off" [tbc::profile status] 0
check "attached unchanged by profiling" [llength [tbc::attached]] $att
check "compiled proc still computes the same" [t_arith 3 4] $ref
check "text report mentions the unknown proc" [string match "*brand_new*not in the module*" [tbc::report -text]] 1
tbc::profile reset
check "reset clears scripts" [dict get [tbc::report] scripts] {}

# a proc defined before the module was loaded: reported once it is seen running while profiling
tbc::profile on
early_proc 1
early_dup 1
set byName {}; foreach e [dict get [tbc::report] procs] { dict set byName [lindex $e 0] $e }
check "early proc (not in the module): state" [lindex [dict get $byName ::early_proc] 1] no-code
check "early proc with code in the module: state" [lindex [dict get $byName ::early_dup] 1] early
check "early proc: 1 call" [lindex [dict get $byName ::early_proc] 3] 1
tbc::profile off
# ---- tbc::capture: the definitions of procs without compiled code, written so that another interpreter gets exactly the same procs
tbc::capture clear
check "capture is off by default" [tbc::capture count] 0
tbc::capture on
proc cap1 {a {b 5} {c {}} args} { return [list $a $b $c $args] }
proc cap_noargs {} { return "no args \{ unbalanced" }
namespace eval ::cns { proc cap2 {x {y "two words"}} { return "$x $y \\ \$ \[ ]" } }
proc {cap with space} {v} { return $v }
proc cap_dup {a} { return 1 }
proc cap_dup {a} { return 1 }
proc t_arith {a b} { return 42 }
tbc::capture off
proc cap_after {} { return 1 }
check "capture count (a repeated definition counts once; later ones are not captured)" [tbc::capture count] 6
set capfile [file join [file dirname [info script]] cap_test_out.tcl]
tbc::capture write $capfile
set c [interp create]
interp eval $c [list source $capfile]
set sigScript {proc sig {pr} { list [info args $pr] [lmap a [info args $pr] {expr {[info default $pr $a d] ? [list $a $d] : [list $a]}}] [info body $pr] }}
eval $sigScript
interp eval $c $sigScript
foreach pr {::cap1 ::cap_noargs ::cns::cap2 {::cap with space} ::cap_dup ::t_arith} {
    check "captured $pr round-trips" [interp eval $c [list sig $pr]] [sig $pr]
}
check "after off, not captured" [interp eval $c {info commands ::cap_after}] {}
interp delete $c
file delete $capfile
tbc::capture clear
check "clear empties it" [tbc::capture count] 0
# ---- a proc renamed before its first call (lazy mode: the compiled code goes to it under its new name)
set ref [interp create]
interp eval $ref [list source [file join [file dirname [info script]] procs.tcl]]
set want [interp eval $ref {t_cmp 1 2}]
interp delete $ref
rename t_cmp t_cmp_renamed
check "renamed proc computes" [t_cmp_renamed 1 2] $want
if {$mode eq "lazy"} { check "renamed before its first call: attached under the new name" [expr {"::t_cmp_renamed" in [tbc::attached]}] 1 }
check "renamed proc, second call" [t_cmp_renamed 1 2] $want
# ---- coroutines: a proc that cannot yield runs compiled inside one; a proc with a yield below it runs the interpreter's version
tq_sq 2; catch {tg_outer 1}
set r0 [tbc::report]
coroutine rcy1 apply {{} { yield [tq_sq 5]; return 0 }}
set r1 [tbc::report]
check "yield-safe proc inside a coroutine runs compiled" [expr {[dict get $r1 compiled_calls] - [dict get $r0 compiled_calls]}] 1
check "yield-safe proc inside a coroutine: no call handed to the interpreter" [expr {[dict get $r1 coroutine_calls] - [dict get $r0 coroutine_calls]}] 0
rename rcy1 {}
coroutine rcy2 tg_outer 1
set r2 [tbc::report]
check "proc with a yield below it inside a coroutine: interpreter's version" [expr {[dict get $r2 coroutine_calls] - [dict get $r1 coroutine_calls] >= 1}] 1
rename rcy2 {}
# a proc that yields runs compiled inside a coroutine too, and every resumption goes on in the compiled code
ty_work 3; catch {ty_gen 1}
set r3 [tbc::report]
coroutine rcy3 ty_genw 3
rcy3; rcy3; rcy3
set r4 [tbc::report]
check "proc that yields: runs compiled in a coroutine" [expr {[dict get $r4 compiled_calls] - [dict get $r3 compiled_calls] >= 3}] 1
check "proc that yields: no call handed to the interpreter" [expr {[dict get $r4 coroutine_calls] - [dict get $r3 coroutine_calls]}] 0
puts [expr {$fails ? "$fails FAILED" : "all report checks passed"}]
exit [expr {$fails ? 1 : 0}]
