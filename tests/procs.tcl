# Test procs, restricted to constructs the translator supports. Every one is run by the interpreter alone and with the compiled module (see differential.tcl).
proc t_arith {a b} {
    format "%s|%s|%s|%s|%s" [expr {$a + $b}] [expr {$a - $b}] [expr {$a * $b}] [expr {$a / $b}] [expr {$a % $b}]
}
proc t_cmp {a b} {
    format "%s%s%s%s%s%s" [expr {$a < $b}] [expr {$a <= $b}] [expr {$a > $b}] [expr {$a >= $b}] [expr {$a == $b}] [expr {$a != $b}]
}
proc t_truth {x} {
    if {$x} { return yes }
    return no
}
proc t_while_cond {x} {
    set n 0
    while {$x} { incr n; set x 0 }
    return $n
}
proc t_incr {a b} {
    set i $a
    incr i
    incr i -3
    incr i $b
    return $i
}
proc t_unset {} {
    return $nosuchvar
}
proc t_unset_incr {} {
    incr nosuchvar
    return $nosuchvar
}
proc t_append {a b} {
    append s $a $b
    append s $a
    append s ,
    return [format "%d %s" [string length $s] $s]
}
proc t_append_shared {a} {
    set t $a
    append a x
    return [format "%s/%s" $t $a]
}
proc t_lindex {l i} {
    return [lindex $l $i]
}
proc t_lset {l i v} {
    lset l $i $v
    return $l
}
proc t_lset_shared {l} {
    set copy $l
    lset l 0 CHANGED
    return [format "%s|%s" $copy $l]
}
proc t_dict {d k} {
    set out ""
    set e [dict exists $d $k]
    dict incr d $k
    dict for {key v} $d { append out $key = $v , }
    return [format "%s %s" $e $out]
}
proc t_dict_empty {k} {
    set d [dict create]
    dict incr d $k
    dict incr d $k
    dict for {key v} $d { append out $key = $v , }
    return $out
}
proc t_strcat {a b} {
    set x "<$a|$b>"
    return [string length $x]$x
}
proc t_double {size y} {
    set ci [expr {2.0 * $y / $size - 1.0}]
    set z [expr {$ci * $ci - 0.5}]
    return [format "%s %s %s" $ci $z [expr {$z < $ci}]]
}
proc t_rec_err {n} {
    if {$n == 0} { return [expr {1 / $n}] }
    return [t_rec_err [expr {$n - 1}]]
}
proc t_rec_sum {n} {
    if {$n < 1} { return 0 }
    return [expr {$n + [t_rec_sum [expr {$n - 1}]]}]
}
proc t_noargs {} { return 42 }
proc t_two {a b} { return $b }
proc t_loop_accum {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        set s [expr {$s + $i * 2 % 7}]
    }
    return $s
}
proc t_call_missing {} {
    return [no_such_command_here 1]
}
proc t_result_obj_reuse {a} {
    set x [expr {$a + 1}]
    set y $x
    set x [expr {$x + 1}]
    return [format "%s %s" $x $y]
}
# a boxed argument keeps the typed variants from taking this loop, so it runs in the frame-based generator (G): a leak in any of its paths (object
# creation, variable stores, incr, array elements, list append) shows as memory growth in the stress run at the end of differential.tcl
proc t_leak_g {a n} {
    set s 0; set l {}
    for {set t 0} {$t < $n} {incr t} {
        set s [expr {($s + ($a & 0xff)) & 0xffff}]
        incr s; incr s 3
        set w([expr {$t & 7}]) $s
        incr w([expr {$t & 7}])
        if {$t % 100 == 0} { lappend l $s }
        set x [string length $a]
    }
    return [list $s [llength $l] [array size w]]
}
# integers beyond the machine range through the shifts and bitwise operators, errors included; the second form keeps the operands boxed
proc t_bigops {a b} {
    set r {}
    lappend r [catch {expr {$a & $b}} m] $m [catch {expr {$a | $b}} m] $m [catch {expr {$a ^ $b}} m] $m
    lappend r [catch {expr {$a << $b}} m] $m [catch {expr {$a >> $b}} m] $m
    lappend r [catch {expr {($a << 40) & 0xffffffff}} m] $m [catch {expr {(($a << 70) >> 65) | $b}} m] $m
    lappend r [catch {expr {$a + $b}} m] $m [catch {expr {$a - $b}} m] $m [catch {expr {$a * $b}} m] $m [catch {expr {($a * $a) - ($b * $b) + $a}} m] $m
    return $r
}
# lmap, the loops inside loops that the compiler writes for `array set` and `dict for`, and procs whose names are glob patterns or contain spaces
proc tl_lmap1 {l} { return [lmap x $l { expr {$x * 2} }] }
proc tl_lmap2 {l} { return [lmap x $l { if {$x > 2} continue; set x }] }
proc tl_lmap3 {l m} { return [lmap x $l y $m { list $x $y }] }
proc tl_lmap4 {l} { return [lmap x $l { if {$x eq "stop"} break; string toupper $x }] }
proc tl_lmap5 {l} { return [lmap x $l { lmap y $x { incr y } }] }
proc tl_lmap6 {l} { return [lmap x $l { if {$x < 0} { error "neg $x" }; set x }] }
proc tl_lmap7 {} { set r {}; foreach a {1 2 3} { lappend r [lmap x {4 5} { expr {$x + $a} }] }; return $r }
proc tl_arrset_in_loop {l} { set r {}; foreach a $l { array set AN $a; lappend r [lsort [array names AN]] }; return $r }
proc tl_arrset_odd {l} { array set AN $l; return [array size AN] }
proc tl_dictfor_in_loop {args} { set r {}; foreach d $args { dict for {k v} $d { if {$v eq "x"} continue; lappend r $k } }; return $r }
proc tl_dictfor_break {args} { set r {}; foreach d $args { dict for {k v} $d { if {$v eq "x"} break; lappend r $k } }; return $r }
proc tl_dictfor_ret {args} { foreach d $args { dict for {k v} $d { if {$v eq "x"} { return "found $k" } } }; return none }
proc tl_dictfor_err {args} { set r {}; foreach d $args { dict for {k v} $d { if {$v eq "x"} { error "bad $k" }; lappend r $k } }; return $r }
proc tl_dictfor_catch {args} { set r {}; foreach d $args { if {[catch { dict for {k v} $d { if {$v eq "x"} { error "bad $k" }; lappend r $k } } m]} { lappend r "caught:$m" } }; return $r }
proc {tw_odd?} {x} { expr {$x + 1} }
proc {tw_star*} {x} { expr {$x * 2} }
proc {tw_br[a]} {x} { expr {$x - 1} }
proc {tw with space} {x} { return "<$x>" }
proc {tw"quote} {x} { return "q$x" }
proc {tw\back} {x} { return "b$x" }
proc {tw;semi} {x} { return "s$x" }
proc tw_caller {x} { return [list [{tw_odd?} $x] [{tw_star*} $x] [{tw_br[a]} $x] [{tw with space} $x] [{tw"quote} $x] [{tw\back} $x] [{tw;semi} $x]] }
# try/finally and catch with dispatch on the result code, inside loops (returnCodeBranch and the `return -options` behind it)
proc tb_try1 {l} { set r {}; foreach x $l { try { if {$x eq "b"} { error boom } elseif {$x eq "c"} { continue } elseif {$x eq "d"} { break }; lappend r ok$x } on error m { lappend r err:$m } finally { lappend r fin$x } }; return $r }
proc tb_try2 {l} { set r {}; foreach x $l { try { if {$x eq "r"} { return early }; lappend r ok$x } finally { lappend r fin$x } }; return $r }
proc tb_try3 {l} { set r {}; foreach x $l { try { if {$x eq "e"} { error bad } ; lappend r ok$x } trap {TCL LOOKUP} {} { lappend r lookup } on error {} { lappend r err } }; return $r }
proc tb_catch1 {l} { set r {}; foreach x $l { set c [catch { if {$x eq "e"} { error z } elseif {$x eq "b"} { break } elseif {$x eq "c"} { continue }; set x } m]; lappend r $c:$m }; return $r }
proc tb_try4 {l} { set r {}; while {[llength $l]} { set l [lassign $l x]; try { if {$x eq "b"} { break }; lappend r $x } finally { lappend r f } }; return $r }
proc tb_try5 {args} { try { llength $args } on ok {v} { return "ok $v" } on error {} { return err } }
# procs whose bytecode depends on the `string` command being the built-in at compile time (report.tcl compiles them while it is hidden)
proc tz_lazy {s} { set n [string length $s]; return $n }
proc tz_trivial {s} { return [string length $s] }
proc tz_lazy2 {s n} { set r {}; for {set i 0} {$i < $n} {incr i} { append r [string toupper $s] }; return [string length $r] }
proc t_leak_loop {n} {
    set acc ""
    for {set i 0} {$i < $n} {incr i} {
        set acc [string length "k$i"]
        set d [dict create]
        dict incr d a
        set v [expr {$i * 3 + 1}]
        append x $i
        if {[string length $x] > 100} { set x "" }
    }
    return $acc
}

# ---- additions for the typed code: overflow in the middle of a loop, doubles, calls between procs, containers
proc t_sumpow {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $i*$i*$i*$i*$i}] }
    return $s
}
proc t_fibloop {n} {
    set a 0
    set b 1
    for {set i 0} {$i < $n} {incr i} { set t [expr {$a + $b}]; set a $b; set b $t }
    return $a
}
proc t_mixed {a b} {
    set x [expr {$a * 2.5 + $b / 4}]
    set y [expr {$x > $b}]
    return [format "%s %s" $x $y]
}
proc t_dblloop {n} {
    set x 0.0
    for {set i 1} {$i <= $n} {incr i} { set x [expr {$x + 1.0 / $i}] }
    return $x
}
proc t_neg {a} { return [expr {0 - $a}] }
proc t_callee {n} { return [expr {$n * 2}] }
proc t_caller {n} { return [expr {[t_callee $n] + 1}] }
proc t_caller2 {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [t_callee $i]}] }
    return $s
}
proc t_callee_str {n} { return "s$n" }
proc t_caller_str {n} { return [format "%s/%s" [t_callee_str $n] [expr {$n + 1}]] }
proc t_sieve_small {n} {
    set f [lrepeat [expr {$n + 1}] 1]
    set c 0
    for {set p 2} {$p <= $n} {incr p} {
        if {[lindex $f $p]} {
            incr c
            for {set i [expr {$p * $p}]} {$i <= $n} {incr i $p} { lset f $i 0 }
        }
    }
    return $c
}
proc t_lindex_oob {l} {
    set s ""
    for {set i -2} {$i < 6} {incr i} { append s [lindex $l $i] | }
    return $s
}
proc t_lset_oob {l i} {
    lset l $i X
    return $l
}
proc t_strbuild2 {n} {
    set s ""
    for {set i 0} {$i < $n} {incr i} { append s $i , "-$i" ; }
    return [format "%d %s" [string length $s] $s]
}
proc t_cat {a b} { return "x${a}y${b}z" }
proc t_ifchain {x} {
    if {$x < 0} { return neg } elseif {$x == 0} { return zero } elseif {$x < 10} { return small }
    return big
}
proc t_countdown {n} {
    set c 0
    while {$n > 0} { incr c; incr n -1 }
    return $c
}
proc t_collatz1 {n} {
    set steps 0
    while {$n != 1} {
        if {$n % 2 == 0} { set n [expr {$n / 2}] } else { set n [expr {3 * $n + 1}] }
        incr steps
    }
    return $steps
}
proc t_gcd {a b} {
    while {$b != 0} { set t [expr {$a % $b}]; set a $b; set b $t }
    return $a
}
proc t_pow2 {n} {
    set r 1
    for {set i 0} {$i < $n} {incr i} { set r [expr {$r * 2}] }
    return $r
}
proc t_rec_fact {n} {
    if {$n <= 1} { return 1 }
    return [expr {$n * [t_rec_fact [expr {$n - 1}]]}]
}
proc t_even {n} { if {$n == 0} { return 1 }; return [t_odd [expr {$n - 1}]] }
proc t_odd {n} { if {$n == 0} { return 0 }; return [t_even [expr {$n - 1}]] }

# ---- int vectors (a list local that holds integers only and never leaves the proc)
proc t_vec_sieve {n} {
    set f [lrepeat [expr {$n + 1}] 1]
    set c 0
    for {set p 2} {$p <= $n} {incr p} {
        if {[lindex $f $p]} {
            incr c
            for {set i [expr {$p * $p}]} {$i <= $n} {incr i $p} { lset f $i 0 }
        }
    }
    return $c
}
proc t_vec_oob {n i} {
    set f [lrepeat $n 7]
    set r [lindex $f $i]
    lset f 0 9
    return "$r|[lindex $f 0]"
}
proc t_vec_lset_oob {n i} {
    set f [lrepeat $n 7]
    lset f $i 3
    return [lindex $f 0]
}
proc t_vec_escape {n} {
    set f [lrepeat $n 4]
    lset f 0 5
    return $f
}
proc t_vec_use {n} {
    set f [lrepeat $n 2]
    lset f 0 8
    set s [llength $f]
    return "$s [join $f ,]"
}
proc t_vec_alias {n} {
    set a [lrepeat $n 0]
    set b $a
    lset a 0 5
    return [list $a $b]
}
proc t_vec_midlset {n x} {
    set f [lrepeat $n 1]
    for {set i 0} {$i < $n} {incr i} {
        lset f $i [expr {$i == 2 ? $x : $i}]
    }
    return [lindex $f 2]:[lindex $f 0]:[lindex $f end]
}
proc t_vec_midlset2 {n x} {
    set f [lrepeat $n 1]
    for {set i 0} {$i < $n} {incr i} {
        lset f $i [expr {$i == 2 ? $x : $i}]
    }
    set s 0
    for {set i 0} {$i < $n} {incr i} { set v [lindex $f $i]; incr s [string length $v] }
    return $s
}
proc t_vec_realloc {n} {
    set s 0
    for {set k 0} {$k < $n} {incr k} {
        set f [lrepeat [expr {$k + 1}] $k]
        lset f 0 [expr {$k * 2}]
        incr s [lindex $f 0]
    }
    return $s
}
proc t_vec_cond {c} {
    if {$c} { set a [lrepeat 3 1] }
    return [lindex $a 0]
}
proc t_vec_two {n} {
    set a [lrepeat $n 1]
    set b [lrepeat $n 2]
    for {set i 0} {$i < $n} {incr i} { lset a $i [expr {[lindex $a $i] + [lindex $b $i]}] }
    return [lindex $a [expr {$n - 1}]]
}
proc t_vec_redef {n} {
    set f [lrepeat $n 7]
    set r1 [lindex $f 0]
    rename lrepeat tbc_lrepeat_saved
    proc lrepeat {n v} { return [list x y z] }
    set g [lrepeat $n 7]
    rename lrepeat {}
    rename tbc_lrepeat_saved lrepeat
    return "$r1 [lindex $g 0] [llength $g]"
}
proc t_vec_neg {n} {
    set f [lrepeat $n 1]
    return [llength $f]
}
proc t_vec_big {n x} {
    set f [lrepeat $n $x]
    return [lindex $f 0]
}
proc t_vec_dbl {n} {
    set f [lrepeat $n 1]
    lset f 1 2.5
    return [lindex $f 1]
}

proc t_list_ops {l} {
    return [list [lindex $l 0] [lindex $l end] [lindex $l end-1] [llength $l] [lindex $l 2] [list $l $l]]
}
proc t_list_len {l} {
    set n [llength $l]
    return [expr {$n * 2}]
}
proc t_vec_imm {n} {
    set f [lrepeat $n 3]
    lset f 0 4
    return [list [lindex $f 0] [lindex $f 1] [lindex $f end] [lindex $f end-1] [llength $f]]
}

# ---- commands that use the frame's variables by name must keep working (such procs stay interpreted)
proc t_frame_eval {n} { set x $n; eval {set y 5}; return [expr {$x + $y}] }
proc t_frame_uplevel {n} { set x $n; return [uplevel 0 {set x}] }
proc t_frame_time {n} { set c 0; time {incr c} 3; return $c }

# ---- int maps (a dict local with integer values that never leaves the proc)
proc t_map_count {n m} {
    set d [dict create]
    set size 0
    for {set i 0} {$i < $n} {incr i} {
        set k "k[expr {($i * 7919) % $m}]"
        if {![dict exists $d $k]} { incr size }
        dict incr d $k
    }
    set total 0
    dict for {k v} $d { set total [expr {$total + $v * [string length $k]}] }
    return [expr {$size * 1000000 + $total}]
}
proc t_map_order {n} {
    set d [dict create]
    for {set i 0} {$i < $n} {incr i} { dict incr d "x[expr {($i * 5) % 7}]" $i; dict incr d y 2 }
    set out {}
    dict for {k v} $d { lappend out $k=$v }
    return $out
}
proc t_map_escape {n} {
    set d [dict create]
    for {set i 0} {$i < $n} {incr i} { dict incr d [expr {$i % 3}] }
    return $d
}
proc t_map_keys {n} {
    set d [dict create]
    for {set i 0} {$i < $n} {incr i} { dict incr d $i; dict incr d 007; dict incr d a }
    return [list [dict size $d] [dict get $d 0] [dict exists $d 007] [dict exists $d 7] [dict exists $d b] [dict keys $d]]
}
proc t_map_alias {n} {
    set d [dict create]
    dict incr d a
    set e $d
    for {set i 0} {$i < $n} {incr i} { dict incr d a }
    return [list $d $e]
}
proc t_map_snapshot {n} {
    set d [dict create]
    for {set i 0} {$i < $n} {incr i} { dict incr d $i }
    set s 0
    dict for {k v} $d { dict incr d $k 10; incr s $v }
    return [list $s $d]
}
proc t_map_overflow {n} {
    set d [dict create]
    for {set i 0} {$i < $n} {incr i} { dict incr d k 4611686018427387904 }
    return [list $d]
}
proc t_map_dkey {x} {
    set d [dict create]
    dict incr d $x
    dict incr d $x
    return [dict get $d $x]
}
proc t_map_nokey {n} {
    set d [dict create]
    return [list [dict exists $d $n] [dict size $d]]
}
proc t_map_empty {n} {
    set d [dict create]
    return [expr {$n > 0 ? $d : "none"}]
}

proc t_lappend {n x} {
    set l {}
    for {set i 0} {$i < $n} {incr i} { lappend l $i }
    lappend l $x
    set m $l
    lappend l z
    return [list $l $m [llength $l]]
}
proc t_lappend_self {x} { set l $x; lappend l $l; return $l }
proc t_lappend_bad {} { set l [string cat a " " \173 b]; lappend l c; return $l }
proc t_dictget {d k} { return [dict get $d $k] }
proc t_dictget_map {n k} {
    set d [dict create]
    for {set i 0} {$i < $n} {incr i} { dict incr d $i 3 }
    return [expr {[dict get $d $k] + 1}]
}

proc t_vec_ret {n} { set f [lrepeat $n 1]; lset f 0 7; return $f }
proc t_vec_ret2 {n} { set f [lrepeat $n 1]; if {$n > 2} { return $f }; return $n }
proc t_map_ret {n} { set d [dict create]; for {set i 0} {$i < $n} {incr i} { dict incr d k$i }; return $d }

# ---- default arguments, args, odd names (the interpreter binds the arguments; the compiled body just sees them)
proc t_defarg {a {b 5} {c "x y"}} { return "$a|$b|$c" }
proc t_args {a args} { return [list $a [llength $args] $args] }
proc t_args_only {args} { return [llength $args] }
proc t_defarg_num {n {step 2}} { set s 0; for {set i 0} {$i < $n} {incr i $step} { incr s $i }; return $s }
proc {odd name} {x} { return [expr {$x + 1}] }
proc t_call_odd {x} { return [{odd name} [expr {$x * 2}]] }
proc t_defarg_call {n} { return [list [t_defarg_num $n] [t_defarg_num $n 3] [t_defarg_num $n 1]] }
namespace eval t::ns {}
proc t::ns::p {x {y 1}} { return [expr {$x + $y}] }
proc t::ns::q {x} { return [t::ns::p [expr {$x * 2}]] }

# ---- exceptions, control flow, return codes, variable linking
proc ta_catch {x} { if {[catch {expr {10 / $x}} r]} { return "err:$r" }; return "ok:$r" }
proc ta_catch_opts {x} { catch {expr {10 / $x}} r o; return [list $r [dict get $o -code] [dict exists $o -errorcode]] }
proc ta_catch_ret {x} { set c [catch {return -code error "boom $x"} r]; return "$c:$r" }
proc ta_catch_break {n} { set s 0; for {set i 0} {$i < $n} {incr i} { set c [catch {if {$i == 3} {break}; incr s}]; if {$c} {break} }; return "$s:$i" }
proc ta_catch_cont {n} { set s 0; for {set i 0} {$i < $n} {incr i} { set c [catch {if {$i % 2} {continue}; incr s}]; incr s 10 }; return "$s:$i" }
proc ta_catch_nested {x} { set r {}; catch { catch { error inner $x } a; lappend r $a; error outer } b; lappend r $b; return $r }
proc ta_try {x} { try { expr {10 / $x} } on error {m} { return "caught $m" } finally { set ::tfin $x } }
proc ta_try_trap {x} { try { if {$x} { error "e$x" "" {MY CODE} }; set v fine } trap {MY CODE} {m o} { set v "trap $m" } on ok {r} { set v "ok $r" } ; return $v }
proc ta_loop_break {n} { for {set i 0} {$i < $n} {incr i} { if {$i == 5} break }; return $i }
proc ta_loop_cont {n} { set s 0; for {set i 0} {$i < $n} {incr i} { if {$i % 2} continue; incr s $i }; return $s }
proc ta_while_break {n} { set i 0; while 1 { if {[incr i] > $n} break }; return $i }
proc ta_nested_break {n} { set c 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { if {$j == 2} break; incr c } }; return $c }
proc ta_return_code {x} { return -code [expr {$x ? "error" : "ok"}] "rc" }
proc ta_inner_return {} { return -level 2 early }
proc ta_return_level {} { ta_inner_return; return after }
proc ta_return_opts {} { return -code error -errorcode {A B} msg }
proc ta_return_plain {x} { if {$x > 2} { return big }; return small }
proc ta_error_info {} { error "oops" "my info" {E CODE} }
proc ta_upvar_set {name val} { upvar 1 $name v; set v $val }
proc ta_upvar_caller {} { set x 1; ta_upvar_set x 42; return $x }
proc ta_upvar0 {} { set a 5; upvar 0 a b; incr b; return "$a$b" }
proc ta_upvar_bad {} { upvar 5 nosuch v; return 1 }
set gtest 0
proc ta_global {} { global gtest; incr gtest; return $gtest }
namespace eval tns { variable v 10 }
proc tns::bump {} { variable v; incr v; return $v }
proc ta_nsupvar {} { namespace upvar ::tns v lv; incr lv; return $lv }
proc ta_break_outside {} { break }
# variable traces and shared values on the direct variable paths (store, incr, array element load/store)
proc tv_log {args} { lappend ::tvlog $args }
proc tv_trace_scalar {} {
    set ::tvlog {}
    set x 1
    trace add variable x {read write unset} tv_log
    set x 2; incr x; incr x 5; set y $x; unset x
    return $::tvlog
}
proc tv_trace_array {} {
    set ::tvlog {}
    array set a {k 1}
    trace add variable a {read write} tv_log
    set a(k) 2; set a(n) 3; incr a(k); set r $a(k); set r2 $a(n)
    return [list $r $r2 $::tvlog]
}
proc tv_trace_wr_veto {} {
    set x 1
    trace add variable x write {apply {{n1 n2 op} { error vetoed }}}
    if {[catch {set x 2} m]} { return "$m $x" }
    return $x
}
proc tv_shared_incr {} { set a 5; set b $a; incr a; incr b 10; set l [list $a $b]; set c $l; lappend l 1; return [list $a $b $l $c] }
proc tv_incr_bad {} { set a abc; incr a }
proc tv_arr_elems {n} {
    for {set i 0} {$i < $n} {incr i} { set w($i) [expr {$i * 2}] }
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr w($i) 3; incr s $w($i) }
    return [list $s [array size w]]
}
proc tv_arr_missing {} { array set a {x 1}; set a(y) $a(x); return [catch {set a(q)} m]$m }
proc tv_upvar_trace_caller {} { set v 1; trace add variable v write tv_log; tv_upvar_set v 9; return [list $v $::tvlog] }

proc ta_rec_imp {n} { global gtest; if {$n < 1} { return 0 }; return [expr {1 + [ta_rec_imp [expr {$n - 1}]]}] }
proc ta_imp_even {n} { global gtest; if {$n == 0} { return 1 }; return [ta_imp_odd [expr {$n - 1}]] }
proc ta_imp_odd {n} { global gtest; if {$n == 0} { return 0 }; return [ta_imp_even [expr {$n - 1}]] }

# ---- foreach
proc tf_sum {l} { set s 0; foreach x $l { incr s $x }; return $s }
proc tf_two {l m} { set r {}; foreach a $l b $m { lappend r $a-$b }; return $r }
proc tf_pairs {l} { set r {}; foreach {a b} $l { lappend r [list $b $a] }; return $r }
proc tf_multi {l m} { set r {}; foreach {a b} $l c $m { lappend r "$a|$b|$c" }; return $r }
proc tf_break {l} { set r {}; foreach x $l { if {$x eq "stop"} break; lappend r $x }; return $r }
proc tf_continue {l} { set r {}; foreach x $l { if {$x eq "skip"} continue; lappend r $x }; return $r }
proc tf_nested {l m} { set r {}; foreach a $l { foreach b $m { if {$b eq $a} continue; lappend r $a$b } }; return $r }
proc tf_nested_break {l m} { set r {}; foreach a $l { foreach b $m { if {$b eq "z"} break; lappend r $a$b } ; lappend r | }; return $r }
proc tf_modify {l} { set r {}; foreach x $l { lappend l extra; lappend r $x }; return [list $r $l] }
proc tf_after {l} { foreach x $l {}; return [expr {[info exists x] ? $x : "none"}] }
proc tf_empty {} { set n 0; foreach x {} { incr n }; return $n }
proc tf_dict {d} { set r {}; foreach {k v} $d { lappend r $k=$v }; return $r }
proc tf_catch {l} { set r {}; foreach x $l { if {[catch {expr {10 / $x}} v]} { lappend r E } else { lappend r $v } }; return $r }
proc tf_return {l} { foreach x $l { if {$x > 2} { return $x } }; return none }
proc tf_err {l} { foreach x $l { if {$x == 0} { error "zero found" } }; return ok }
proc tf_arg {l} { foreach l $l { set last $l }; return [expr {[info exists last] ? $last : {}}] }
proc tf_lit {} { set r {}; foreach x {a b c} y {1 2} { lappend r $x$y }; return $r }
proc tf_str {s} { set n 0; foreach c [split $s ""] { if {$c eq "a"} { incr n } }; return $n }
proc tf_while_in_foreach {l} { set t 0; foreach x $l { set i 0; while {$i < $x} { incr i; incr t } }; return $t }
proc tf_foreach_in_while {n} { set t 0; set i 0; while {$i < $n} { foreach x {1 2 3} { incr t $x }; incr i }; return $t }
proc tf_global {l} { global gtest; foreach x $l { incr gtest $x }; return $gtest }
proc tf_inner_proc {l} { set r {}; foreach x $l { lappend r [t_two $x $x] }; return $r }
proc ta_fold_pow2 {a} { return [expr {$a - (9223372036854775807 / 0.5)}] }
# the folded constant 2**64 prints as 1.844674407370955e+19, which parses to the double below it: the translator must carry the object's value, not
# its text (seed 911 of the class-1 fuzz; found again when a ?: in the translator turned the value into text)
proc ta_fold_pow2c {a b} { return [expr {(((($a / -5) <= (3 * $a)) - (9223372036854775807 / 0.5)) + (((4611686018427387904 + $b) + ($b <= 3)) - $b))}] }
proc ta_fold_pow2b {a} { return [expr {$a + (4611686018427387904 * 4.0)}] }

# ---- batch B: operators, strings, lists, arrays, variables by name, switch
proc tb_neg {a} { return [expr {-$a}] }
proc tb_pos {a} { return [expr {+$a}] }
proc tb_not {a} { return [expr {!$a}] }
proc tb_bnot {a} { return [expr {~$a}] }
proc tb_band {a b} { return [expr {$a & $b}] }
proc tb_bor {a b} { return [expr {$a | $b}] }
proc tb_bxor {a b} { return [expr {$a ^ $b}] }
proc tb_shl {a b} { return [expr {$a << $b}] }
proc tb_shr {a b} { return [expr {$a >> $b}] }
proc tb_pow {a b} { return [expr {$a ** $b}] }
proc tb_in {a l} { return [expr {$a in $l}] }
proc tb_ni {a l} { return [expr {$a ni $l}] }
proc tb_seq {a b} { return [list [expr {$a eq $b}] [expr {$a ne $b}] [string compare $a $b]] }
proc tb_sindex {s i} { return [string index $s $i] }
proc tb_sfirst {a b} { return [list [string first $a $b] [string last $a $b]] }
proc tb_srange {s a b} { return [string range $s $a $b] }
proc tb_srange_imm {s} { return [list [string range $s 1 3] [string range $s 2 end] [string range $s 0 end-1] [string range $s end-2 end]] }
proc tb_sreplace {s a b n} { return [string replace $s $a $b $n] }
proc tb_scase {s} { return [list [string toupper $s] [string tolower $s] [string totitle $s]] }
proc tb_strim {s c} { return [list [string trim $s $c] [string trimleft $s $c] [string trimright $s $c] [string trim $s]] }
proc tb_smatch {p s} { return [list [string match $p $s] [string match -nocase $p $s]] }
proc tb_smap {a b s} { return [string map [list $a $b] $s] }
proc tb_sclass {s} { return [list [string is alpha $s] [string is digit $s] [string is space $s] [string is upper $s] [string is xdigit $s] [string is alnum $s]] }
proc tb_re {s} { return [list [regexp {a.c} $s] [regexp -nocase {A.C} $s] [regexp {^\d+$} $s]] }
proc tb_re_bad {s} { return [regexp {(} $s] }
proc tb_lrange_imm {l} { return [list [lrange $l 1 3] [lrange $l 1 end] [lrange $l 0 0]] }
proc tb_lindex_multi {l i j} { return [lindex $l $i $j] }
proc tb_lset_flat {l i j v} { lset l $i $j $v; return $l }
proc tb_concat {a b c} { return [concat $a $b $c] }
proc tb_lexpand {a b} { return [list {*}$a x {*}$b] }
proc tb_arr {k v} {
    set a($k) $v; set r [list $a($k)]
    incr a(n) 2; lappend r $a(n)
    append a($k) z; lappend r $a($k)
    lappend a(l) 1 2; lappend r $a(l)
    lappend r [info exists a($k)] [info exists a(nope)] [array exists a] [array exists nosuch]
    unset a(n); lappend r [info exists a(n)]
    lappend r [lsort [array names a]]
    return $r
}
proc tb_arr_err {k} { set a(x) 1; return $a($k) }
proc tb_arr_notarr {k} { set a 5; return [set a($k)] }
proc tb_arr_incr_err {k} { set a(x) abc; incr a(x); return $a(x) }
proc tb_arr_unset_err {k} { set a(x) 1; unset a($k); return [array size a] }
proc tb_named {n v} {
    set $n $v; set r [list [set $n]]
    incr $n 3; lappend r [set $n]
    append $n q; lappend r [set $n]
    lappend $n w; lappend r [set $n]
    lappend r [info exists $n] [info exists nosuch_$n]
    unset $n; lappend r [info exists $n]
    return $r
}
proc tb_named_arr {n k v} {
    set ${n}($k) $v; set r [list [set ${n}($k)]]
    incr ${n}($k); lappend r [set ${n}($k)]
    append ${n}($k) e; lappend r [set ${n}($k)]
    lappend r [info exists ${n}($k)] [array exists $n]
    unset ${n}($k); lappend r [info exists ${n}($k)]
    return $r
}
proc tb_named_local {} { set x 5; set n x; incr $n; set $n [expr {[set $n] * 2}]; return [list $x [set $n]] }
proc tb_named_err {n} { return [set $n] }
proc tb_switch {s} { switch -- $s { a { return 1 } b - c { return 2 } "x y" { return 3 } default { return 0 } } }
proc tb_switch_glob {s} { switch -glob -- $s { a* { return 1 } *b { return 2 } default { return 0 } } }
proc tb_switch_re {s} { switch -regexp -- $s { ^a { return 1 } b$ { return 2 } default { return 0 } } }
proc tb_switch_nodefault {s} { set r none; switch -- $s { a { set r A } b { set r B } }; return $r }
proc tb_info_level {} { return [list [info level] [info level 0]] }
proc tb_info_level_err {n} { return [info level $n] }
proc tb_ns_current {} { return [namespace current] }
proc tb_exist_local {a} { if {$a} { set x 1 }; return [info exists x] }
proc tb_lappend_multi {l a b} { lappend l $a $b; lappend l; return $l }
proc tb_lappend_multi_new {a b} { lappend nl $a $b; return $nl }
proc tb_lappend_multi_arr {k a b} { lappend arr($k) $a $b; lappend arr($k) $b $a; return $arr($k) }
proc tb_lappend_multi_named {n a b} { lappend $n $a $b; return [set $n] }
proc tb_lappend_multi_named_arr {n k a b} { lappend ${n}($k) $a $b; return [set ${n}($k)] }
proc tb_lappend_bad {a} { set l "\{x"; lappend l $a $a; return $l }

# ---- batch C: expansion, dict updates, array set, expr strings, numeric types, clock, command lookup
proc tc_expand {a b} { return [list {*}$a x {*}$b y] }
proc tc_expand_nested {a b} { return [list {*}[list {*}$a x] {*}$b] }
proc tc_expand_call {l} { return [string cat {*}$l] }
proc tc_expand_empty {e} { return [{*}$e] }
proc tc_expand_err {l} { return [lindex {*}$l] }
proc tc_expand_bad {a} { return [list {*}$a] }
proc tc_expand_break {a} { set r {}; while {1} { lappend r [list {*}$a [break]]; break }; return $r }
proc tc_expand_catch {a} { return [catch {list {*}$a [error x]} m] }
proc tc_expand_loop {l} { set r {}; foreach x $l { lappend r [string cat {*}$x z] }; return $r }
proc tc_expand_cont {l} { set r {}; foreach x $l { if {$x eq "c"} continue; lappend r [list {*}$x [expr {$x eq "b" ? 1 : 2}]] }; return $r }
proc tc_dict {d k v} { dict set d $k $v; dict set d n a b $v; dict append d $k x; dict lappend d l $v $v; dict unset d n a b; return [list $d [dict size $d]] }
proc tc_dict_new {k v} { dict set nd $k $v; dict lappend nl $k $v; dict append na $k $v; return [list $nd $nl $na] }
proc tc_dict_bad {k} { set d "\{a"; dict set d $k 1; return $d }
proc tc_dict_unset_miss {k} { set d {a 1}; dict unset d $k; return $d }
proc tc_dict_lappend_bad {k} { set d [list $k "\{x"]; dict lappend d $k y; return $d }
proc tc_arrmake {} { array set arr {}; return [list [array exists arr] [array size arr]] }
proc tc_arrmake_scalar {} { set arr 5; array set arr {a 1}; return $arr }
proc tc_arrmake_named {n} { array set $n {a 1 b 2}; return [lsort [array names $n]] }
proc tc_exprs {e} { set x 5; return [expr $e] }
proc tc_numtype {a} { return [list [string is integer -strict $a] [string is wideinteger -strict $a] [string is double -strict $a] [string is integer $a]] }
proc tc_clock {} { set t [clock seconds]; set m [clock milliseconds]; set u [clock microseconds]; set c [clock clicks]; return [list [string is integer -strict $t] [expr {abs($m - $t * 1000) < 5000}] [expr {abs($u - $m * 1000) < 5000000}] [string is integer -strict $c]] }
proc tc_which {n} { return [list [namespace which -command $n] [namespace origin $n]] }
proc tc_bool {a b} { set r {}; if {$a} { lappend r A }; if {!$a} { lappend r B }; lappend r [expr {$a ? 1 : 2}] [expr {$a && $b}] [expr {$a || $b}]; while {$a} { lappend r W; break }; return $r }

# ---- loops that only the poll can interrupt
proc td_spin {n} { set i 0; while {1} { incr i; if {$i > $n} { break } }; return $i }
proc td_spin_g {n} { set i 0; set l {}; while {1} { incr i; lappend l $i; if {$i > $n} { break } }; return [llength $l] }
proc td_foreach {l} { set n 0; foreach x $l { incr n }; return $n }
proc td_inf {} { set i 0; while {1} { incr i } }
proc td_inf2 {n} { set i 0; set l {}; while {1} { incr i; lappend l x; set l {} } }
proc td_inf3 {} { while {1} { string length x } }
proc td_inf4 {l} { while {1} { foreach x $l { set y $x } } }

# ---- batch D: dict update/with, key paths, evalStk, coroutine name
proc te_dupdate {d} { dict update d a x b y { set x 1; unset y; set z 2 }; return $d }
proc te_dupdate_err {d} { dict update d a x { error boom }; return $d }
proc te_dupdate_break {d} { foreach i {1 2} { dict update d a x { break } }; return $d }
proc te_dwith {d} { dict with d { set a 5; unset -nocomplain b }; return $d }
proc te_dwith_path {d k} { dict with d $k { set a 6 }; return $d }
proc te_dwith_ret {d} { dict with d { return $a } }
proc te_dpath {d k1 k2 k3} { return [list [dict exists $d $k1 $k2 $k3] [dict get $d $k1 $k2 $k3]] }
proc te_dpath2 {d k1 k2} { return [list [dict exists $d $k1 $k2] [dict get $d $k1 $k2]] }
proc te_evalstk {s} { set r [catch $s v]; return [list $r $v] }
proc te_evalstk_loop {s} { set r {}; foreach i {1 2 3} { lappend r [catch $s v] $v }; return $r }
proc te_evalstk_brk {s} { set n 0; while {1} { incr n; if {$n > 3} { break }; catch $s v }; return $n }
proc te_coro {} { return [info coroutine] }

# ---- coroutines: translated procs between a coroutine and its yield
proc tg_yielder {x} { set r [yield $x]; return "got $r" }
proc tg_outer {x} { return [tg_yielder [expr {$x + 1}]] }
proc tg_outer2 {x} { set s {}; foreach i {1 2 3} { lappend s [tg_yielder [expr {$i * $x}]] }; return $s }
proc tg_outer3 {x} { if {$x > 0} { return [tg_outer3 [expr {$x - 1}]] }; return [tg_yielder 100] }
proc tg_start {} { coroutine tgc_in tg_outer 7; return [list [tgc_in a] ] }
proc tg_gen {} { yield 1; yield 2; return done }
proc tg_consume {} { set r {}; coroutine tgg tg_gen; lappend r [tgg]; lappend r [tgg]; return $r }

# ---- command frames (TIP 280)
proc th_frame {} {
    set x 1
    set f [info frame]
    set g [info frame 0]
    return [list $f [dict get $g type] [dict get $g line]]
}
proc th_frame2 {a} {
    set r {}
    foreach i {1 2} {
        lappend r [dict get [info frame -1] line]
        lappend r [dict get [info frame 0] line]
    }
    return $r
}
proc th_frame_cmd {} { set d [info frame -1]; return [list [dict get $d type] [dict get $d cmd]] }
proc th_frame_proc {} { set d [info frame 0]; return [list [dict get $d proc] [dict get $d level]] }
proc th_uplevel {} { return [uplevel 1 {info frame}] }
proc th_eval {} { return [eval {info frame}] }
proc th_eval_line {} {
    set a 1
    eval {
        set b [info frame 0]
    }
    return [dict get $b line]
}
proc th_err_line {} { set x 1; catch {error boom} m o; return [dict get $o -errorline] }
proc th_err_line2 {} {
    set x 1
    set y 2
    catch {
        set z 3
        error boom
    } m o
    return [dict get $o -errorline]
}
proc th_info_level {} { return [list [info level] [info level 0] [info level -1]] }
proc th_dbg1 {} { set x 1; set f [info frame]; set g [info frame 0]; return [list $f $g] }
proc th_dbg2 {} { set f [info frame]; return [info frame 0] }
proc th_dbg3 {} { return [info frame 0] }
proc th_dbg4 {} { set x [expr {1 + 2}]; return [info frame 0] }

# ---- tailcall
proc ti_tc2 {x} { return "t2:$x" }
proc ti_tc1 {x} { tailcall ti_tc2 $x }
proc ti_tc_loop {n} { if {$n > 0} { tailcall ti_tc_loop [expr {$n - 1}] }; return done }
proc ti_tc_catch {x} { set r [catch {tailcall ti_tc2 $x} v]; return [list $r $v] }
proc ti_tc_noarg {} { tailcall }
proc ti_tc_ns {} { namespace eval tin { proc here {} { tailcall ti_tc2 [namespace current] } }; return [tin::here] }
proc ti_tc_after {x} { tailcall ti_tc2 $x; return notreached }
proc ti_tc_lambda {x} { apply {{y} { tailcall ti_tc2 $y }} $x }

# ---- strings with NUL and other characters outside ASCII in the body (the interpreter keeps NUL as C0 80)
proc tk_nul {s} { return [list [split $s \0] [string map [list \0 X "é" E] $s] [string length "a\0b"] [string first \0 $s] [string index "a\0b" 1] [string is control [string index "a\0b" 1]]] }
proc tk_nul2 {s} { append s "\0z€😀"; return [list $s [string length $s] [string range $s end-3 end]] }
proc tk_uni {s} { return [list [string toupper "éßı"] [string length "😀"] [split "€é" ""] [expr {$s eq "é"}]] }

# ---- variables in the frame: arrays and links (upvar, namespace upvar, variable); typed code works on them in the frame itself
proc tf_sieve {n} {
    for {set i 0} {$i <= $n} {incr i} { set s($i) 1 }
    for {set i 2} {$i * $i <= $n} {incr i} {
        if {$s($i)} { for {set j [expr {$i * $i}]} {$j <= $n} {incr j $i} { set s($j) 0 } }
    }
    set c 0
    for {set i 2} {$i <= $n} {incr i} { incr c $s($i) }
    return $c
}
proc tf_hist {n} {
    for {set i 0} {$i < $n} {incr i} { incr h([expr {$i % 17}]) }
    set t 0
    for {set k 0} {$k < 17} {incr k} { incr t [expr {$h($k) * $k}] }
    return [list $t [array size h]]
}
proc tf_fibm {n} {
    set f(0) 0; set f(1) 1
    for {set i 2} {$i <= $n} {incr i} { set f($i) [expr {($f([expr {$i - 1}]) + $f([expr {$i - 2}])) % 1000003}] }
    return $f($n)
}
proc tf_grid {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set a($i,$j) [expr {$i * $j}] } }
    set t 0
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { incr t $a($j,$i) } }
    return $t
}
# integer keys of all sizes and the names they make: "5" and "05" are different elements
proc tf_keys {n} {
    for {set i -3} {$i < $n} {incr i} { set a($i) [expr {$i * 2}] }
    set t 0
    for {set i -3} {$i < $n} {incr i} { incr t $a($i) }
    set a(-9223372036854775808) 1
    set a(9223372036854775807) 2
    set k 5; set a($k) x; set a(05) y; set s 05; set a($s) z
    return [list $t [lsort -dictionary [array names a]] [array size a] $a(5) $a(05) $a(-9223372036854775808) $a(9223372036854775807)]
}
proc tf_keyforms {k} {
    set a(5) x; set a(05) y; set a(5.0) z; set a(a b) w; set a() e
    return [list [info exists a($k)] $a($k)]
}
proc tf_missing {k} { set a(1) 1; return $a($k) }
proc tf_notarray {k} { set a 1; return $a($k) }
proc tf_notarray_set {k} { set a 1; set a($k) 2; return $a }
proc tf_incr_el {k n} {
    set h(a) 5; set h(w) 9223372036854775806; set h(s) abc; set h(f) 1.5; set h(x) 0x10; set h(b) 99999999999999999999; set h(e) {}
    incr h($k) $n
    return [lsort [array get h]]
}
proc tf_incr_el_imm {k} {
    set h(a) 5; set h(w) 9223372036854775807; set h(s) abc
    incr h($k)
    return [lsort [array get h]]
}
proc tf_set_types {v} {
    set a(1) $v; set a(2) 7; set a(3) 2.5; set a(4) abc
    return [list $a(1) $a(2) $a(3) $a(4) [expr {$a(2) + 1}] [expr {$a(3) * 2}]]
}
proc tf_shared_el {} {
    set x 5
    set a(1) $x; set a(2) $x
    incr a(1)
    incr a(2) 10
    return [list $x $a(1) $a(2)]
}
proc tf_shared_up {name} {
    upvar 1 $name v
    set y $v
    incr v 100
    return [list $y $v]
}
proc tf_exists {k} {
    set a(1) 1
    set b {}
    return [list [info exists a($k)] [info exists a(1)] [info exists a(zz)]]
}
proc tf_arrays_and_cmds {n} {
    for {set i 0} {$i < $n} {incr i} { set a($i) [expr {$i * $i}] }
    set t 0
    for {set i 0} {$i < $n} {incr i} { incr t $a($i) }
    return [list $t [lsort -integer [array names a]] [array exists a] [array size a]]
}
proc tf_unset_mid {n} {
    for {set i 0} {$i < $n} {incr i} { set a($i) $i }
    unset a(1)
    set t 0
    for {set i 0} {$i < $n} {incr i} { if {[info exists a($i)]} { incr t $a($i) } }
    return $t
}
# links
proc tf_ups_inc {name n} {
    upvar 1 $name x
    for {set i 0} {$i < $n} {incr i} { incr x $i }
    return $x
}
proc tf_ups_incimm {name n} {
    upvar 1 $name x
    for {set i 0} {$i < $n} {incr i} { incr x }
    return $x
}
proc tf_ups_set {name v} { upvar 1 $name x; set x $v; return $x }
proc tf_ups_arr {name n} {
    upvar 1 $name a
    for {set i 0} {$i < $n} {incr i} { set a($i) [expr {$i + 1}] }
    set t 0
    for {set i 0} {$i < $n} {incr i} { incr t $a($i) }
    return $t
}
proc tf_ups_level {lvl name n} { upvar $lvl $name x; for {set i 0} {$i < $n} {incr i} { incr x }; return $x }
proc tf_ups_same {n} { set y 0; upvar 0 y x; for {set i 0} {$i < $n} {incr i} { incr x }; return [list $x $y] }
proc tf_ups_twice {n1 n2} { set a 1; set b 2; upvar 1 $n1 x; upvar 1 $n2 y; incr x; incr y 5; return [list $x $y] }
proc tf_ups_user {n} { set cnt 3; tf_ups_inc cnt $n; set arr(1) 7; tf_ups_arr arr 4; return [list $cnt [lsort [array get arr]]] }
proc tf_ups_rec {name n} { upvar 1 $name x; incr x; if {$n > 0} { tf_ups_rec x [expr {$n - 1}] }; return $x }
namespace eval tfns { variable v 10; variable w; variable arr; set arr(1) 1 }
proc tfns::bumpv {n} { variable v; for {set i 0} {$i < $n} {incr i} { incr v }; return $v }
proc tfns::bumparr {n} { variable arr; for {set i 0} {$i < $n} {incr i} { incr arr($i) }; return [lsort [array get arr]] }
proc tfns::setw {x} { variable w; set w $x; return $w }
proc tfns::readw {} { variable w; return $w }
proc tf_nsup {n} { namespace upvar ::tfns v lv; for {set i 0} {$i < $n} {incr i} { incr lv }; return $lv }
proc tf_nsup_missing {} { namespace upvar ::nosuchns v lv; return $lv }
proc tf_global_hist {n} { for {set i 0} {$i < $n} {incr i} { incr ::tfg([expr {$i % 5}]) }; return [lsort [array get ::tfg]] }
# an error after the proc has changed variables in the frame: the changes happen once, the error is the interpreter's
proc tf_resume {name x} {
    upvar 1 $name a
    incr a(n)
    set a(last) $x
    return [lindex $x 0]
}
proc tf_resume2 {name x} {
    upvar 1 $name c
    incr c 10
    set l [string index $x 100]
    return [expr {$c + $x}]
}
proc tf_resume3 {name x} {
    upvar 1 $name c
    incr c
    return [expr {$c / $x}]
}
proc tf_two_up {n1 n2} { upvar 1 $n1 a $n2 b; set t 0; for {set i 0} {$i < 5} {incr i} { incr a $i; incr b [expr {$a % 3}] }; return [list $a $b] }
proc tf_cond_var {x} {
    if {$x > 0} { set j 5; set k($x) $j }
    if {$x > 2} { for {set i 0} {$i < 3} {incr i} { incr j } }
    if {[info exists j]} { return [list $j [array size k]] }
    return none
}
proc tf_cond_var2 {x} {
    if {$x > 0} { set j 5 }
    set a(1) 1
    if {$x > 1} { return [expr {$j + 1}] }
    return [info exists j]
}
proc tf_calls_pure {n} {
    for {set i 0} {$i < $n} {incr i} { set a($i) [t_rec_sum [expr {$i % 20}]] }
    return $a([expr {$n - 1}])
}
proc tf_double_el {n} {
    for {set i 0} {$i < $n} {incr i} { set d($i) [expr {$i * 0.5}] }
    set t 0.0
    for {set i 0} {$i < $n} {incr i} { set t [expr {$t + $d($i)}] }
    return $t
}
proc tf_str_el {n} {
    for {set i 0} {$i < $n} {incr i} { set s($i) "v$i" }
    set r {}
    for {set i 0} {$i < $n} {incr i} { append r $s($i) , }
    return $r
}
# reference counts on the paths that work on variables in the frame: a leak of one object per iteration shows as memory growth
proc tf_leak_frame {n} {
    for {set i 0} {$i < $n} {incr i} {
        set a($i) $i
        incr a($i)
        incr a([expr {$i % 7}]) 2
        set b [expr {$a($i) + 1}]
        set a(k$i) $b
        set s "x$i"
        set a($s) 5
        if {[info exists a($i)]} { incr a($i) }
        set v $a($s)
    }
    return $b
}
proc tf_leak_up {name n} {
    upvar 1 $name x
    for {set i 0} {$i < $n} {incr i} { incr x $i; set x [expr {$x + 1}]; set y $x }
    return $x
}
proc tf_leak_up2 {n} { set c 0; for {set i 0} {$i < $n} {incr i} { tf_leak_up c 3 }; return $c }

# ---- calls from typed code: a callee that is not attached yet, omitted default arguments, callees that fall back to boxed code, callees that need a frame
proc tq_sq {x} { expr {$x * $x} }
proc tq_add {a {b 10} {c 2.5}} { expr {$a + $b + $c} }
proc tq_add_i {a {b 10} {c -3}} { expr {$a + $b + $c} }
proc tq_dflt_str {a {b abc}} { return $a$b }
proc tq_dflt_odd {a {b 0x10} {c 1e3} {d 007}} { return [list $a $b $c $d] }
proc tq_arr {k} { set t($k) $k; incr t($k) 5; return $t($k) }
proc tq_glob {k} { global tq_counter; incr tq_counter $k; return $tq_counter }
proc tq_up {name} { upvar 1 $name x; incr x; return $x }
proc tq_uplevel {} { uplevel 1 {set tq_seen 1} }
proc tq_err {x} { if {$x > 3} { error "too big: $x" }; return $x }
proc tq_big {x} { return [expr {$x * 4611686018427387904}] }
proc tq_str {x} { if {$x % 2} { return "odd" }; return $x }
proc tq_dbl {x} { if {$x % 3 == 0} { return [expr {$x / 2.0}] }; return $x }
proc tq_call_loop {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [tq_sq $i] }; return $s }
proc tq_call_defaults {n} {
    set s 0.0
    for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [tq_add $i] + [tq_add $i 1] + [tq_add $i 1 2.0]}] }
    return $s
}
proc tq_call_defaults_i {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s [tq_add_i $i]; incr s [tq_add_i $i 5]; incr s [tq_add_i $i 5 7] }
    return $s
}
proc tq_call_dflt_str {n} { set r {}; for {set i 0} {$i < $n} {incr i} { append r [tq_dflt_str $i] , }; return $r }
proc tq_call_dflt_odd {n} { set r {}; for {set i 0} {$i < $n} {incr i} { lappend r [tq_dflt_odd $i] }; return $r }
proc tq_call_frame {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s [tq_arr $i]; incr s [tq_glob 1] }
    return [list $s $::tq_counter]
}
proc tq_call_up {n} { set c 0; for {set i 0} {$i < $n} {incr i} { tq_up c }; return $c }
proc tq_call_uplevel {n} { set tq_seen 0; for {set i 0} {$i < $n} {incr i} { tq_uplevel }; return [info exists tq_seen] }
proc tq_call_err {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [tq_err $i] }; return $s }
proc tq_call_err_frame {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [tq_err $i]; incr s [tq_glob 1] }; return [list $s $::tq_counter] }
proc tq_call_big {n} { set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [tq_big $i]}] }; return $s }
proc tq_call_mixed {n} { set r {}; for {set i 0} {$i < $n} {incr i} { lappend r [tq_str $i] [tq_dbl $i] }; return $r }
proc tq_call_sum_mixed {n} { set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [tq_dbl $i]}] }; return $s }
proc tq_call_missing {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [tq_nosuch $i] }; return $s }

# ---- math functions (tcl::mathfunc::*) in typed code: one proc per function, entered with integer, double and object arguments (tests/hints.txt)
foreach f {sin cos tan asin acos atan sinh cosh tanh exp log log10 sqrt floor ceil double int wide round abs bool entier isqrt} {
    proc tm_$f {x} "expr {${f}(\$x)}"
}
foreach f {pow atan2 fmod hypot} {
    proc tm2_$f {x y} "expr {${f}(\$x, \$y)}"
}
proc tm_mix {x} { expr {sqrt($x * $x + 1.0) + abs($x) + int($x) * 2 + round($x) - floor($x) + ceil($x)} }
proc tm_loop {n} {
    set s 0.0
    for {set i 1} {$i < $n} {incr i} {
        set s [expr {$s + sqrt($i) + double($i % 7) + floor($i / 3.0) + abs($i - 50) + round($i * 0.5) + int($i * 1.5)}]
    }
    return $s
}
proc tm_loop_d {x n} {
    set s $x
    for {set i 1} {$i < $n} {incr i} {
        set s [expr {sin($s) + cos($i) + exp(-$i * 0.01) + log($i) + pow($s, 2) + atan2($s, $i) + hypot($s, $i) + fmod($i, 3.0) + abs($s) + sqrt(abs($s)) + floor($s) + ceil($s) + round($s / 1e10)}]
    }
    return $s
}
proc tm_int_loop {n} {
    set s 0
    for {set i -50} {$i < $n} {incr i} { incr s [expr {int($i * 0.37) + round($i * 0.5) + abs($i) + wide($i / 3.0)}] }
    return $s
}
proc tm_not_math {x} { expr {max($x, 3) + min($x, 3)} }

# ---- foreach in typed code
proc tfe_sum {l} { set s 0; foreach x $l { incr s $x }; return $s }
proc tfe_pairs {l} { set s 0; foreach {a b} $l { incr s [expr {$a * $b}] }; return $s }
proc tfe_two {l m} { set s 0; foreach x $l y $m { incr s [expr {$x + $y}] }; return $s }
proc tfe_three {l m} { set r {}; foreach {a b} $l c $m { lappend r "$a/$b/$c" }; return $r }
proc tfe_nested {n} {
    set s 0
    set l {1 2 3}
    for {set i 0} {$i < $n} {incr i} { foreach x $l { foreach y $l { incr s [expr {$x * $y + $i}] } } }
    return $s
}
proc tfe_modify {n} { set l {1 2 3}; set s 0; foreach x $l { lappend l 9; incr s $x }; return [list $s $l] }
proc tfe_shared {n} { set l [list 1 2 3]; set k $l; set s 0; foreach x $l { lset l 0 99; incr s $x }; return [list $s $l $k] }
proc tfe_break {l} { set s 0; foreach x $l { if {$x > 5} break; incr s $x }; return $s }
proc tfe_continue {l} { set s 0; foreach x $l { if {$x % 2} continue; incr s $x }; return $s }
proc tfe_after {l} { foreach x $l {}; return [expr {[info exists x] ? $x : -1}] }
proc tfe_float {l} { set s 0.0; foreach x $l { set s [expr {$s + sqrt($x)}] }; return $s }
proc tfe_calls {n} {
    set l {}
    for {set i 0} {$i < $n} {incr i} { lappend l $i }
    set s 0
    foreach x $l { incr s [tq_sq $x] }
    return $s
}
proc tfe_arr {l} { foreach x $l { incr cnt($x) }; return [lsort [array get cnt]] }
proc tfe_up {name l} { upvar 1 $name v; foreach v $l { incr tfe_n }; return [list $v [info exists tfe_n]] }
proc tfe_global {l} { global tfe_last; foreach tfe_last $l {}; return $tfe_last }
proc tfe_err {l} { set s 0; foreach x $l { incr s [expr {10 / $x}] }; return $s }
proc tfe_return {l} { foreach x $l { if {$x == 3} { return found } }; return none }
proc tfe_notlist {x} { foreach a $x { }; return done }
proc tfe_str {l} { set r ""; foreach w $l { append r [string length $w] , [string toupper $w] ; }; return $r }
proc tfe_big {n} {
    set l {}
    for {set i 0} {$i < 1000} {incr i} { lappend l $i }
    set s 0
    for {set k 0} {$k < $n} {incr k} { foreach x $l { incr s $x } }
    return $s
}

# ---- catch in typed code: the body runs typed, an error hands over to the boxed code at that instruction, which dispatches to the handler
proc tcc_basic {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { if {[catch {expr {10 / ($i % 3)}} r]} { incr s 100 } else { incr s $r } }
    return $s
}
proc tcc_vars {n} { catch { set a $n; set b [expr {$a * 2}]; set c [expr {$b / ($n - 3)}] } m; return [list $a $b [info exists c] $m] }
proc tcc_nested {n} { catch { catch { error inner } m1; set x [expr {$n / 0}] } m2; return [list $m1 $m2 [info exists x]] }
proc tcc_codes {n} {
    set r {}
    lappend r [catch { return $n } v] $v
    lappend r [catch { expr {$n + 1} } v] $v
    lappend r [catch { error "e$n" } v o] $v [dict get $o -code]
    lappend r [catch { break } v] [catch { continue } v] [catch { return -code 7 x } v]
    return $r
}
proc tcc_loop {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        catch { incr s [expr {100 / ($i - 5)}] }
        incr s $i
    }
    return $s
}
proc tcc_overflow {n} { set s 0; for {set i 0} {$i < $n} {incr i} { catch { set big [expr {9223372036854775807 + $i}]; incr s } }; return [list $s [info exists big]] }
proc tcc_opts {n} { catch { expr {$n / 0} } m o; return [list $m [dict get $o -errorcode]] }
proc tcc_callee {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { if {[catch {tq_err $i} v]} { incr s 1000 } else { incr s $v } }
    return $s
}
proc tcc_undef {n} { catch { expr {$nosuch + 1} } m; return $m }
proc tcc_after {n} { set a 1; catch { set a [expr {$n / 0}] }; set b [expr {$a + 5}]; for {set i 0} {$i < 3} {incr i} { incr b $i }; return [list $a $b] }
proc tcc_arr {n} { catch { set t(1) 5; set t(2) [expr {$t(1) / ($n - 1)}] } m; return [list $m [lsort [array get t]]] }
proc tcc_strict {n} { catch { string index abc $n; lindex {a b} [expr {$n / ($n - 2)}] } m; return $m }

# ---- switch in typed code (jump tables): integer and string keys, keys written in other forms, fall-through bodies, default
proc tsw_int {n} {
    set s 0
    for {set i -3} {$i < $n} {incr i} {
        switch -- $i {
            -2 { incr s 1000 }
            0 { incr s 1 }
            1 - 2 { incr s 20 }
            05 { incr s 500000 }
            +3 { incr s 7000 }
            -0 { incr s 90000 }
            5 { incr s 300 }
            9223372036854775807 { incr s 5 }
            default { incr s 4000000 }
        }
    }
    return $s
}
proc tsw_mod {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { switch -- [expr {$i % 4}] { 0 { incr s 1 } 1 { incr s 2 } 2 { incr s 3 } default { incr s 4 } } }
    return $s
}
proc tsw_str {l} {
    set s 0
    foreach w $l { switch -- $w { a { incr s 1 } b - c { incr s 10 } {} { incr s 100 } "a b" { incr s 1000 } default { incr s 10000 } } }
    return $s
}
proc tsw_val {x} { switch -- $x { 1 { return one } 01 { return zero-one } 1.0 { return float } abc { return text } default { return other } } }
proc tsw_nodefault {x} { set r start; switch -- $x { 1 { set r one } 2 { set r two } }; return $r }
proc tsw_nested {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        switch -- [expr {$i % 3}] {
            0 { switch -- [expr {$i % 2}] { 0 { incr s 1 } default { incr s 2 } } }
            1 { incr s 10 }
            default { incr s 100 }
        }
    }
    return $s
}
proc tsw_dbl {x} { switch -- [expr {$x * 1.0}] { 1.0 { return one } 2.5 { return twoandhalf } default { return other } } }
proc tsw_err {x} { switch -- $x { 1 { return [expr {1 / 0}] } default { return $x } } }

# ---- smaller instructions in typed code: incr of a local held as an object, llength of a number, string map, list concatenation
proc tbx_incr_b {l} { set r {}; foreach x $l { incr x; incr x 5; lappend r $x }; return $r }
proc tbx_incr_by {l} { set r {}; foreach x $l { foreach y $l { set z $x; incr z $y; lappend r $z } }; return $r }
proc tbx_incr_shared {l} { set v [lindex $l 0]; set w $v; incr v; incr v [lindex $l 1]; return [list $v $w] }
proc tbx_llen {x n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s [llength $i]; incr s [llength [expr {$i * 0.5}]]; incr s [llength abc] }
    return [list $s [llength $x]]
}
proc tbx_map {l} { set r {}; foreach w $l { lappend r [string map {a 1 b 22} $w] }; return $r }
proc tbx_concat {a b} { return [list {*}$a {*}$b] }
proc tbx_concat_loop {n} { set r {}; for {set i 0} {$i < $n} {incr i} { set r [list {*}$r $i {*}[list $i $i]] }; return $r }

# a proc without variables in the frame that calls one with effects, then fails: the effect must happen once
proc tfx_eff_bump {} { global tfx_g; incr tfx_g; return $tfx_g }
proc tfx_eff_caller {s} {
    set a [tfx_eff_bump]
    set r [string index $s end-x]
    return [list $a $r]
}

# ---- arrays that are compiled locals and are only read and written element by element (kept natively by typed code)
proc tr_basic {n} {
    for {set i 0} {$i < $n} {incr i} { set a($i) [expr {$i * 3}] }
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $a($i) }
    return $s
}
proc tr_missing_elem {k} { set a(1) 5; return $a($k) }
proc tr_missing_array {k} { return $a($k) }
proc tr_incr_new {k} { incr a($k) 4; incr a($k); return $a($k) }
proc tr_incr_text {v} { set a(x) $v; incr a(x) 2; return $a(x) }
proc tr_incr_var {k d} { set a($k) 10; incr a($k) $d; return $a($k) }
proc tr_incr_overflow {} { set a(1) 9223372036854775800; incr a(1) 10; return $a(1) }
proc tr_order {n} {
    for {set i 0} {$i < $n} {incr i} { set a([expr {($i * 7) % 23}]) $i }
    set a(zeta) 1; set a(alpha) 2; set a() 3; set a(a,b) 4
    return [array names a]
}
proc tr_order_get {n} {
    for {set i 0} {$i < $n} {incr i} { set a([expr {($i * 5) % 31}]) [expr {$i * $i}] }
    return [array get a]
}
proc tr_shared {x} {
    set a(1) $x; set a(2) $x
    incr a(1)
    return [list $a(1) $a(2) $x]
}
proc tr_overwrite {} { set a(k) 1; set a(k) abc; set a(k) 2.5; set a(k) {x y}; return $a(k) }
proc tr_exists {k} { set a(1) 1; return [list [info exists a($k)] [info exists a(2)]] }
proc tr_keys {} {
    set a() e; set a(a,b) c; set a(ünï) u; set a(0123456789012345678901234567890123456789) long
    set a(0123456789012345678901234567890123456788) long2
    return [list $a() $a(a,b) $a(ünï) $a(0123456789012345678901234567890123456789) $a(0123456789012345678901234567890123456788)]
}
proc tr_catch {k} {
    set a(1) 1
    set rc [catch {set x $a($k)} m]
    set a($k) 7
    return [list $rc $m $a($k) [array size a]]
}
proc tr_trace {} {
    set ::trlog {}
    set a(1) 5
    trace add variable a write tr_tracecb
    set a(1) 6; set a(2) 7
    trace remove variable a write tr_tracecb
    return [list $::trlog [lsort [array names a]]]
}
proc tr_tracecb {args} { lappend ::trlog $args }
proc tr_unset {} { set a(1) 1; set a(2) 2; unset a(1); return [array names a] }
proc tr_scalar_clash {} { set a(1) 1; return [info exists a] }
proc tr_grow {n} {
    for {set i 0} {$i < $n} {incr i} { set a(k$i) $i }
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $a(k$i) }
    return [list $s [array size a]]
}
proc tr_rec {n} { set a(0) $n; if {$n > 0} { set a(1) [tr_rec [expr {$n - 1}]] } else { set a(1) 0 }; return [expr {$a(0) + $a(1)}] }
proc tr_pair {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set m($i,$j) [expr {$i * $j}] } }
    set t 0
    for {set i 0} {$i < $n} {incr i} { incr t $m($i,$i) }
    return $t
}
proc tr_double {x} { set a(0) [expr {$x * 1.5}]; set a(1) [expr {$x + 1}]; return [list $a(0) $a(1)] }
proc tr_callee {x} { set t($x) $x; return $t($x) }
proc tr_caller {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [tr_callee $i] }; return $s }
proc tr_deopt_late {x} { set a(1) 1; set a(2) $x; set r [string index abc $x]; return [list $r [lsort [array names a]]] }
proc tr_err_after {x} { set a(1) 1; set b [expr {$x + 1}]; set a(2) $b; return [array get a] }

# `info exists` on an element that is not there must not leave an entry behind: the order in which the array lists its elements shows it
proc tr_exists_order {n a} {
    for {set i 0} {$i < $n} {incr i} {
        incr m(-1)
        set m([expr {$i * 3 - $a}]) 1
        incr m(5) $i
        if {[info exists m($i)]} { }
    }
    return [array names m]
}
proc tr_exists_order2 {n a} {
    for {set i 0} {$i < $n} {incr i} {
        incr m(-1)
        set m([expr {$i * 3 - $a}]) 1
        incr m(5) $i
        if {[info exists m($i)]} { incr s }
    }
    return [array get m]
}

# a proc that cannot yield calls one that is replaced, inside a coroutine, by one that does
proc ty_leaf {x} { expr {$x + 1} }
proc ty_mid {x} { return [expr {[ty_leaf $x] * 2}] }

# a built-in that a proc was compiled against is replaced: by a proc that changes the caller's variable, in the global namespace and in the proc's own
proc tb_rev {l} { set x 1; set r [lreverse $l]; return [list $r $x] }
namespace eval tbns { proc rev2 {l} { set x 1; set r [lreverse $l]; return [list $r $x] } }
proc tb_ins {l} { set x 1; set r [linsert $l 0 z]; return [list $r $x] }

# ---- procs that yield: the boxed code suspends the coroutine through the interpreter's callbacks
proc ty_gen {n} { for {set i 0} {$i < $n} {incr i} { yield [expr {$i * $i}] }; return done }
proc ty_echo {} { set r [yield start]; while {$r ne "stop"} { set r [yield "got $r"] }; return bye }
proc ty_work {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [expr {$i * $i % 7}] }; return $s }
proc ty_genw {n} { for {set i 0} {$i < $n} {incr i} { yield [ty_work 30] }; return done }
proc ty_yerr {} { yield 1; error "after the yield" }
proc ty_ycatch {} { set r {}; for {set i 0} {$i < 3} {incr i} { if {[catch {yield $i} v]} { lappend r E:$v } else { lappend r $v } }; return $r }
proc ty_ylist {l} { foreach x $l { yield $x }; return [llength $l] }
proc ty_yfe2 {l} { set s 0; foreach x $l { set s [expr {$s + [yield $x]}] }; return $s }
proc ty_yvars {} { set a 5; set b abc; set c [list 1 2]; yield; incr a; lappend c $a; yield [list $a $b $c]; return [list $a $b $c] }
proc ty_yto {args} { set r [yieldto list {*}$args]; return [list got $r] }
proc ty_ytocmd {} { yieldto string length hello }
proc ty_ylevel {} { set l0 [info level]; yield $l0; return [list $l0 [info level] [info frame]] }
proc ty_yret {} { yield 1; return -code error -errorcode {A B} "boom" }
proc ty_ytail {} { yield 1; tailcall ty_work 10 }
proc ty_ynested {} { set r {}; lappend r [yield a]; lappend r [ty_yinner]; return $r }
proc ty_yinner {} { return [yield b] }
proc ty_yarr {n} { for {set i 0} {$i < $n} {incr i} { set a($i) [yield $i] }; return [array get a] }
proc ty_ydict {} { set d [dict create a 1]; yield [dict get $d a]; dict set d b 2; yield [dict size $d]; return $d }
proc ty_ydictfor {} { set d {a 1 b 2}; dict for {k v} $d { yield $k }; return ok }
proc ty_yexpand {} { return [list {*}[yield x] z] }
proc ty_ytwice {} { set a [yield 1]; set b [yield 2]; return [expr {$a + $b}] }
proc ty_ycoro {} { yield [info coroutine]; return [info coroutine] }

# ---- procs that yield and then compute in a loop of their own (typed code is entered again after the yield)
proc ty2_heavy {n k} {
    set acc 0
    for {set i 0} {$i < $n} {incr i} {
        for {set j 0} {$j < $k} {incr j} { set acc [expr {($acc * 31 + $j * $i) % 1000003}] }
        yield $acc
    }
    return $acc
}
proc ty2_dbl {n} {
    set s 0.5
    for {set i 1} {$i <= $n} {incr i} {
        for {set j 1} {$j <= 4} {incr j} { set s [expr {$s + sqrt($i * $j) / 3.0}] }
        yield $s
    }
    return [expr {$s * 2}]
}
proc ty2_fe {l} {
    set t 0
    foreach x $l {
        for {set j 0} {$j < 5} {incr j} { incr t [expr {$j * 2}] }
        set got [yield $x]
        for {set j 0} {$j < 3} {incr j} { incr t 1 }
        lappend res $got
    }
    return [list $t $res]
}
proc ty2_flag {n} {
    if {$n > 2} { set late [expr {$n * 2}] }
    set s 0
    yield start
    for {set i 0} {$i < $n} {incr i} { incr s $i }
    if {[info exists late]} { incr s $late }
    return $s
}
proc ty2_nonint {n} {
    set acc 1
    yield first
    set v acc
    set $v abc
    for {set i 0} {$i < $n} {incr i} { catch {set acc [expr {$acc + 1}]} m }
    return [list $acc $m]
}
proc ty2_unset {n} {
    set acc 1
    yield first
    set v acc
    unset $v
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $i }
    return [list $s [info exists acc]]
}
proc ty2_ret {n} {
    set s 0
    yield start
    for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $i * $i}] }
    return $s
}
proc ty2_retd {n} {
    set s 0.0
    yield start
    for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $i * 0.5}] }
    return $s
}
proc ty2_args {a b} {
    incr a 5
    set b [expr {$b * 2}]
    yield [list $a $b]
    for {set i 0} {$i < 4} {incr i} { incr a $b }
    return [list $a $b]
}
proc ty2_lit {n} {
    set r [list lit [yield L1] more]
    for {set i 0} {$i < $n} {incr i} { lappend r $i }
    return $r
}
proc ty2_list {n} {
    set l {}
    for {set i 0} {$i < $n} {incr i} { lappend l [expr {$i * 3}] }
    yield [llength $l]
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s [lindex $l $i] }
    return $s
}
proc ty2_arr {n} {
    for {set i 0} {$i < $n} {incr i} { set a($i) [expr {$i * i_sq($i)}] }
    yield [array size a]
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $a($i) }
    return $s
}
proc i_sq {x} { expr {$x * $x} }
proc ty2_catch {n} {
    set s 0
    yield start
    for {set i 0} {$i < $n} {incr i} { if {[catch {incr s [expr {10 / ($i - 2)}]} m]} { incr s 100 } }
    return $s
}
proc ty2_twice {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $i }
    yield $s
    for {set i 0} {$i < $n} {incr i} { incr s [expr {$i * 2}] }
    yield $s
    for {set i 0} {$i < $n} {incr i} { incr s 3 }
    return $s
}
proc ty2_while {n} {
    set s 0; set i 0
    yield go
    while 1 { incr i; if {$i > $n} break; incr s $i }
    return $s
}
proc ty2_errloop {n} {
    set s 0
    yield go
    for {set i 0} {$i < $n} {incr i} { incr s [expr {$i * 2}] }
    error "after the loop: $s"
}
proc ty2_inner_yield {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 3} {incr j} { incr s [expr {$i * $j}]; if {$j == 1} { yield $s } } }
    return $s
}
proc ty2_yto {n} {
    set s 0
    yieldto list a b
    for {set i 0} {$i < $n} {incr i} { incr s $i }
    return $s
}

# built-ins replaced through `interp alias`, `namespace import` and `interp hide`, and procs that use built-ins nobody has replaced
namespace eval tbal { proc rev {l} { set x 1; set r [lreverse $l]; return [list $r $x] } }
namespace eval tbim { proc rev {l} { set x 1; set r [lreverse $l]; return [list $r $x] } }
proc tb_self {l} {
    set a [lreverse $l]
    rename lreverse tb_self_orig
    proc lreverse {l} { return REPLACED }
    set b [lreverse $l]
    list $a $b
}
proc tb_self2 {n} {
    set x $n
    set a [lreverse {1 2}]
    rename lreverse tb_self2_orig
    proc lreverse {l} { uplevel 1 {set x 77}; return R }
    set b [lreverse {1 2}]
    list $a $b $x
}
proc tb_hide {l} { set x 1; set r [lreverse $l]; return [list $r $x] }
proc tb_fmt {l} { return [format "%d:%s" [llength $l] [join $l ,]] }
proc tb_spl {s} { set r [split $s ,]; return [list [llength $r] [puts_free $r]] }
proc puts_free {r} { return [lindex $r 0] }

# integers written other than canonically (hex, octal, binary, a leading space) used as operands of integer operations
proc tl_lit {x} {
    list [expr {$x & 0xFF}] [expr {$x ^ 0xFFFFFFFF}] [expr {$x | 010}] [expr {$x + 0x10}] [expr {$x - -0x10}] [expr {$x * 0b101}] [expr {$x < 0o17}] [expr {$x == " 5"}] [expr {$x >> 0x2}] [expr {$x % 0x7}]
}
proc tl_lit_loop {n} {
    set acc 0xFFFFFFFF
    for {set i 0} {$i < $n} {incr i} { set acc [expr {(($acc ^ $i) & 0xFF) + ($acc >> 8 & 0xFFFFFF)}] }
    return $acc
}
proc tl_lit_big {x} { return [expr {$x & 0xFFFFFFFFFFFFFFFFFF}] }

# binary scan of one number format with * into a local
foreach tbs_t {c cu s su S Su i iu I Iu} {
    proc tbs_$tbs_t {d} "set x old; set n \[binary scan \$d ${tbs_t}* x\]; list \$n \$x"
    proc tbs_sum_$tbs_t {d} "binary scan \$d ${tbs_t}* v; set s 0; foreach e \$v { incr s \$e }; return \$s"
}
proc tbs_use {d} { binary scan $d c* nums; set s 0; foreach n $nums { set s [expr {($s ^ $n) & 0xFF}] }; return [list $s [llength $nums]] }
proc tbs_twice {d} { binary scan $d S* a; binary scan $d s* a; return $a }
proc tbs_arr {d} { array set a {}; binary scan $d c* a; return $a }
proc tbs_elem {d} { binary scan $d c* a(1); return [array get a] }
proc tbs_lit {} { binary scan "\x01\xff\x80" cu* x; return $x }
proc tbs_noarg {d} { binary scan $d c* }
proc tbs_fmt {d f} { binary scan $d $f x; return $x }
proc tl_lit_fold {a b} { return [expr {($b / (9223372036854775807 + 2147483648)) - ($a > (0.5 - 2))}] }
proc tl_lit_big2 {x} { return [list [expr {$x + 0xFFFFFFFFFFFFFFFFF}] [expr {$x & 0x7FFFFFFFFFFFFFFF}] [expr {$x - -0x8000000000000000}]] }

# typed code handing over before a loop (a bignum, an out-of-range value) and the boxed code entering typed code again at the loop head
proc os_big {n} {
    set big [expr {9223372036854775807 + $n}]
    set m [expr {$big >> 3}]
    set s 0
    for {set i 0} {$i < 100} {incr i} { incr s [expr {($i ^ $n) & 0xFF}] }
    return [list $m $s]
}
proc os_giveup {n} {
    set v 0
    set big [expr {9223372036854775807 + $n}]
    set v [expr {$big * 2}]
    set s 0
    for {set i 0} {$i < 10} {incr i} { set s [expr {$s + $v % 7 + $i}] }
    return [list $v $s]
}
proc os_mid {n} {
    set s 0
    for {set i 0} {$i < 50} {incr i} {
        if {$i == 20} { set s [expr {$s + 9223372036854775807 + $n}] ; set s [expr {$s - 9223372036854775807 - $n}] }
        incr s [expr {$i * 3 + $n}]
    }
    return $s
}
proc os_nested {n} {
    set big [expr {9223372036854775807 + $n}]
    set t 0
    for {set i 0} {$i < 20} {incr i} {
        for {set j 0} {$j < 20} {incr j} { incr t [expr {($i * $j) ^ $n}] }
    }
    return [list [expr {$big - 9223372036854775807}] $t]
}
proc os_foreach {n} {
    set big [expr {9223372036854775807 + $n}]
    set l {}
    for {set i 0} {$i < 30} {incr i} { lappend l [expr {$i * $i}] }
    set s 0
    foreach x $l { incr s [expr {$x & 0xFF}] }
    foreach {a b} $l { incr s [expr {$a - $b}] }
    return [list [expr {$big > 0}] $s]
}
proc os_while {n} {
    set big [expr {9223372036854775807 + $n}]
    set i 0; set s 0
    while {$i < 1000} {
        incr i
        if {$i % 7 == 0} continue
        if {$i > 500} break
        incr s [expr {$i ^ $n}]
    }
    return [list [expr {$big != 0}] $i $s]
}
proc os_error {n} {
    set big [expr {9223372036854775807 + $n}]
    set s 0
    for {set i 5} {$i > -5} {incr i -1} { incr s [expr {100 / $i}] }
    return $s
}
proc os_catch {n} {
    set big [expr {9223372036854775807 + $n}]
    set s 0
    for {set i 5} {$i > -5} {incr i -1} { if {[catch {incr s [expr {100 / $i}]} m]} { incr s 1000 } }
    return [list $s [expr {$big > 0}]]
}
proc os_return {n} {
    set big [expr {9223372036854775807 + $n}]
    for {set i 0} {$i < 1000} {incr i} { if {($i * $n) % 97 == 11} { return [list $i [expr {$big > 0}]] } }
    return none
}
proc os_dbl {n} {
    set big [expr {9223372036854775807 + $n}]
    set x 0.5
    for {set i 0} {$i < 20} {incr i} { set x [expr {$x * 1.5 + $i}] }
    return [list $x [expr {$big > 0}]]
}
proc os_args {a b} {
    set big [expr {9223372036854775807 + $a}]
    set s $b
    for {set i 0} {$i < 20} {incr i} { set s [expr {$s + $i * $a}] }
    return [list $s $big]
}
proc ty_same {n} { set y 0; upvar 0 y x; yield 1; for {set i 0} {$i < $n} {incr i} { incr x }; return [list $x $y] }

# array elements whose key is built from integers and literals (a($i,$j)): typed code holds such a key as text in a buffer
proc mk_load {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set a($i,$j) [expr {$i * 10 + $j}] } }
    set s 0
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { incr s [expr {$a($i,$j) * $a($j,$i)}] } }
    return [list $s [lsort [array names a]]]
}
proc mk_incr {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set c($i,$j) 1; incr c($i,$j) 3; incr c($i,$j) $i; incr c($j,$i) -1 } }
    return [lsort [array get c]]
}
proc mk_exist {n} {
    set e 0
    for {set i 0} {$i < $n} {incr i} { set a($i,$i) $i }
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { if {[info exists a($i,$j)]} { incr e } } }
    return $e
}
proc mk_neg {n} {
    set a(-5,9223372036854775807) x
    set a(-9223372036854775808,0) y
    set r {}
    foreach i [list -5 $n -9223372036854775808] { foreach j {9223372036854775807 0 1} { if {[info exists a($i,$j)]} { lappend r $a($i,$j) } else { lappend r - } } }
    return $r
}
proc mk_three {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { for {set k 0} {$k < $n} {incr k} { set a($i,$j,$k) [expr {$i + $j + $k}] } } }
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $a($i,$i,$i) }
    return [list $s [llength [array names a]]]
}
proc mk_lit {n} {
    for {set i 0} {$i < $n} {incr i} { set a(x$i) $i; set a(y${i}z) [expr {$i * 2}]; set a(:$i:) 1 }
    return [lsort [array get a]]
}
proc mk_deopt {n} {
    for {set i 0} {$i < $n} {incr i} { set a($i,1) [expr {9223372036854775807 + $i}]; set b($i,2) [expr {$i + 1}] }
    return [list [lsort [array get a]] [lsort [array get b]]]
}
proc mk_text {n s} {
    for {set i 0} {$i < $n} {incr i} { set a($s,$i) $i; set a($i,$s) [expr {$i * 2}] }
    return [lsort [array get a]]
}
proc mk_error {n} {
    set a(1,1) 5
    for {set i 0} {$i < $n} {incr i} { set s $a($i,$i) }
    return $s
}

# state reached through names held in variables (`upvar #0 $name st`, `variable $name`), then a loop that uses numbers read from the array: typed code goes on at the loop head;
# values that are not integers make the check at the store fail
proc dn_up {name n} {
    upvar #0 $name st
    set A $st(A); set B $st(B)
    for {set i 0} {$i < $n} {incr i} {
        set A [expr {($A + $B * $i) & 0xFFFF}]
        set B [expr {$B ^ $A}]
    }
    set st(A) $A; set st(B) $B
    return [list $A $B]
}
namespace eval dnns {
    proc f {token n} {
        variable $token
        upvar 0 $token st
        set A $st(A); set B $st(B); set s 0
        foreach {x y} {1 2 3 4 5 6 7 8} { set s [expr {$s + $x * $A + $y * $B}] }
        for {set i 0} {$i < $n} {incr i} { set A [expr {($A * 3 + $i) % 1000003}]; incr s $A }
        set st(A) $A
        return [list $s $A [array get st]]
    }
}
proc dn_list {l n} {
    set A [lindex $l 0]; set B [lindex $l 1]
    for {set i 0} {$i < $n} {incr i} { set A [expr {$A + $B + $i}]; set B [expr {$B - 1}] }
    return [list $A $B]
}

# calls of built-ins that need no frame, made through their C procedures when nothing the interpreter's dispatch would do can matter
proc pj_join {l} { set r {}; for {set i 0} {$i < 3} {incr i} { append r [join $l ,] ; append r [llength [split $r ,]] }; return $r }
proc pj_str {s} { set n 0; for {set i 0} {$i < 4} {incr i} { incr n [string first o $s]; append s [string range $s 0 1]; incr n [string length [string trim " $s "]] }; return [list $n $s [string toupper $s] [string match *o* $s]] }
proc pj_fmt {n} { set r {}; for {set i 0} {$i < $n} {incr i} { lappend r [format %03d $i] [lreplace {a b c} 1 1 $i] [lsearch -exact {a b c} c] }; return $r }

# string first / last / index / range: the one-byte-character fast path and everything that is left to the command
proc sf_first {n h} { string first $n $h }
proc sf_last {n h} { string last $n $h }
proc sf_index {s i} { string index $s $i }
proc sf_range {s a b} { string range $s $a $b }
proc sf_lit {s} { list [string range $s 1 3] [string range $s 0 0] [string range $s 2 1] [string range $s -2 2] [string range $s 1 end] [string range $s end-1 end] [string range $s 3 99] [string index $s 0] [string index $s 2] [string index $s 99] [string index $s -1] [string index $s end] [string first l $s] [string last l $s] [string first ll $s] [string first {} $s] }
proc sf_loop {s} {
    set n [string length $s]; set r {}; set pos 0
    for {set i 0} {$i < $n} {incr i} { lappend r [string index $s $i] }
    while {[set p [string first o $s $pos]] >= 0} { lappend r $p; set pos [expr {$p + 1}] }
    for {set i 0} {$i < $n} {incr i} { lappend r [string range $s $i [expr {$i + 1}]] [string first [string index $s $i] $s] [string last [string index $s $i] $s] }
    return $r
}

# == and != against the empty string (the idiom `if {$x == {}}`)
proc em_eq {x} { list [expr {$x == {}}] [expr {$x != ""}] [expr {{} == $x}] [expr {"" != $x}] }
proc em_loop {l} { set n 0; foreach v $l { if {$v == {}} { continue }; if {$v != ""} { incr n } }; return $n }
proc em_num {n} { set c 0; for {set i 0} {$i < $n} {incr i} { if {$i == {}} { incr c 100 }; if {$i != ""} { incr c } }; return $c }
proc em_dbl {x} { set d [expr {$x * 1.5}]; list [expr {$d == ""}] [expr {$d != {}}] }

# string match, the executor's instruction: plain strings, string objects, byte arrays, -nocase, patterns with classes and escapes
proc sm_match {p s} { list [string match $p $s] [string match -nocase $p $s] [string match *o* $s] [string match {[a-c]*} $s] [string match {a\*b} $s] }
proc sm_loop {l} { set n 0; foreach s $l { if {[string match *a* $s]} { incr n }; if {[string match -nocase A* $s]} { incr n 10 } }; return $n }

# regexp as an instruction (no variables, no options but -nocase): matches, no match, an invalid pattern, patterns with classes and anchors
proc rx_test {p s} { list [regexp $p $s] [regexp -nocase $p $s] [regexp -- {^[0-9]+$} $s] [regexp {a.c} $s] }
proc rx_loop {l} { set n 0; foreach s $l { if {[regexp {^a} $s]} { incr n }; if {[regexp -nocase {B+} $s]} { incr n 10 } }; return $n }

# numbers that are integers or doubles at run time (the tagged kind W of procs that use floating-point numbers)
proc wf_add {a b} { expr {$a + $b} }
proc wf_sum {l} { set sum 0; set sumsq 0.0; foreach v $l { set sum [expr {$sum + $v}]; set sumsq [expr {$sumsq + $v * $v}] }; list $sum $sumsq }
proc wf_mean {l} { set s 0; set n 0; foreach v $l { set s [expr {$s + $v}]; incr n }; if {$n == 0} { return 0 }; expr {$s / double($n)} }
proc wf_cmp {a b} { list [expr {$a < $b}] [expr {$a == $b}] [expr {$a + $b * 0.5}] [expr {-$a}] [expr {!$a}] [expr {$a / $b}] [expr {$a - $b}] [expr {$a * $b}] [expr {$a >= $b}] [expr {$a != $b}] }
proc wf_mod {a b} { list [expr {$a % $b}] [expr {$a + 0.0}] }
proc wf_loop {n} { set x 1; set y 0.5; for {set i 0} {$i < $n} {incr i} { set x [expr {$x * 1.5 + $i}]; set y [expr {$y - $x / 3}]; if {$x > 1e6} { break } }; list $x $y }
proc wf_pass {l} { set t 0; foreach v $l { set t [wf_add $t $v] }; return $t }
proc wf_ret {x} { set r 0; if {$x > 0} { set r [expr {$x * 0.5}] }; return $r }
proc wf_incr {n} { set c 0; set f 0.5; for {set i 0} {$i < $n} {incr i} { incr c; set f [expr {$f + $c}] }; list $c $f }
proc wf_cond {l} { set k 0; set m 0.0; foreach v $l { if {$v > 2} { incr k }; if {$v * 1.0 != $v} { set m [expr {$m + $v}] } }; list $k $m }
proc wf_neg {l} { set r {}; foreach v $l { lappend r [expr {-$v}] [expr {+$v}] [expr {$v - 0.0}] }; return $r }
proc wf_store {n} { for {set i 0} {$i < $n} {incr i} { set a($i) [expr {$i * 0.5}]; set b $a($i); set c [expr {$b + 1}] }; list [array size a] [expr {$n ? $c : 0}] }
proc wf_keep {x} { set v $x; set w [expr {$v + 0.5}]; list $v $w }
proc wm_funcs {l} { set r {}; foreach v $l { set x [expr {$v * 1.0 + 0.0}]; lappend r [expr {sqrt(abs($x))}] [expr {double($v)}] [expr {sin($v)}] [expr {floor($v)}] [expr {ceil($x)}] [expr {pow($v, 2)}] [expr {atan2($v, 1)}] [expr {abs($v)}] [expr {int($v)}] [expr {round($v)}] }; return $r }
proc wm_acc {l} { set s 0; set q 0.0; foreach v $l { set s [expr {$s + $v}]; set q [expr {$q + sqrt($v * $v)}] }; list $s $q [expr {sqrt($s)}] [expr {double($s)}] }

# floating-point arithmetic on values that arrive as objects, in procs that show no sign of floating-point numbers (the second, tagged-number version, used after the first double)
proc wa_sum {l} { set s 0; foreach v $l { set s [expr {$s + $v}] }; return $s }
proc wa_mean {l} { set s 0; set n 0; foreach v $l { set s [expr {$s + $v}]; incr n }; if {$n == 0} { return 0 }; return [expr {$s / $n}] }
proc wa_dot {a b} { set s 0; foreach x $a y $b { set s [expr {$s + $x * $y}] }; return $s }
proc wa_scale {l k} { set r {}; foreach v $l { lappend r [expr {$v * $k - 1}] }; return $r }
proc wa_max {l} { set m [lindex $l 0]; foreach v $l { if {$v > $m} { set m $v } }; return $m }
proc wa_poly {x} { set r 0; foreach c {3 -2 5} { set r [expr {$r * $x + $c}] }; return $r }
proc wa_twice {l} { list [wa_sum $l] [wa_sum $l] }
# dense native arrays: keys that are canonical integers made in ascending order without a gap are held in a vector (decisions 34), anything else turns the array into the
# table; the elements, their text and the errors must be what the interpreter's arrays give
proc da_asc {n base} { for {set i 0} {$i < $n} {incr i} { set a([expr {$base + $i}]) [expr {$i * 2}] }; set s 0; for {set i 0} {$i < $n} {incr i} { incr s $a([expr {$base + $i}]) }; return $s }
proc da_fill {n} { for {set i 0} {$i <= $n} {incr i} { set p($i) 1 }; for {set i 2} {$i * $i <= $n} {incr i} { if {$p($i)} { for {set j [expr {$i * $i}]} {$j <= $n} {incr j $i} { set p($j) 0 } } }; set c 0; for {set i 2} {$i <= $n} {incr i} { if {$p($i)} { incr c } }; return $c }
proc da_gap {n} { for {set i 0} {$i < $n} {incr i 2} { set a($i) $i }; set s 0; for {set i 0} {$i < $n} {incr i 2} { incr s $a($i) }; return $s }
proc da_desc {n} { for {set i $n} {$i > 0} {incr i -1} { set a($i) [expr {$i * $i}] }; set s 0; for {set i 1} {$i <= $n} {incr i} { incr s $a($i) }; return $s }
proc da_str {} { set a(0) 5; set a(1) abc; set a(2) 0x10; set a(3) 007; set a(4) 1.50; set a(5) {x y}; set a(6) 100000000000000000000; return [list $a(0) $a(1) $a(2) $a(3) $a(4) $a(5) $a(6)] }
proc da_strlate {n} { for {set i 0} {$i < $n} {incr i} { set a($i) $i }; set a($n) late; set a(1) [expr {$a(1) + 1}]; return [list $a(0) $a(1) $a($n)] }
proc da_neg {} { set a(-1) 1; set a(0) 2; set a(1) 3; return [list $a(-1) $a(0) $a(1)] }
proc da_big {} { set a(4294967296) 1; set a(2147483647) 2; set a(2147483648) 3; return [list $a(4294967296) $a(2147483647) $a(2147483648)] }
proc da_edge {n} { for {set i 0} {$i < $n} {incr i} { set a($i) $i }; set a(01) x; set a(+3) y; set a( 4) z; return [list $a(0) $a(1) $a(01) $a(+3) $a( 4)] }
proc da_missing {n} { for {set i 0} {$i < $n} {incr i} { set a($i) $i }; return $a(5) }
proc da_missing0 {} { set a(0) 1; set a(2) 2; return $a(1) }
proc da_exists {n k} { for {set i 0} {$i < $n} {incr i} { set a($i) $i }; list [info exists a($k)] [info exists a(0)] [info exists a([expr {$n - 1}])] [info exists a($n)] }
proc da_incr {n} { for {set i 0} {$i < $n} {incr i} { incr h([expr {$i % 7}]) }; set s 0; for {set k 0} {$k < 7} {incr k} { append s ,$h($k) }; return $s }
proc da_incr2 {n} { for {set i 0} {$i < $n} {incr i} { incr h([expr {($i * 3) % 7}]) [expr {$i + 1}] }; set s 0; for {set k 0} {$k < 7} {incr k} { append s ,$h($k) }; return $s }
proc da_incrstr {} { set a(0) 1; set a(1) abc; incr a(0) 5; return [list $a(0) [catch {incr a(1)} m] $m] }
proc da_overflow {} { set a(0) 9223372036854775807; set a(1) 1; incr a(0); return $a(0) }
proc da_base1 {n} { for {set i 1} {$i <= $n} {incr i} { set a($i) [expr {$i % 3}] }; set s 0; for {set i 1} {$i <= $n} {incr i} { incr s $a($i) }; return $s }
proc da_mixed {} { set a(0) 1; set a(1) 2; set a(x) 3; set a(2) 4; return [list $a(0) $a(1) $a(x) $a(2)] }
proc da_dbl {n} { for {set i 0} {$i < $n} {incr i} { set a($i) [expr {$i / 4.0}] }; set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $a($i)}] }; return $s }
proc da_two {n m} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $m} {incr j} { set a($i,$j) [expr {$i * 10 + $j}] } }; set s 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $m} {incr j} { incr s $a($i,$j) } }; return $s }
proc da_two1 {n m} { for {set i 1} {$i <= $n} {incr i} { for {set j 1} {$j <= $m} {incr j} { set a($i,$j) [expr {$i - $j}] } }; set s 0; for {set i 1} {$i <= $n} {incr i} { for {set j 1} {$j <= $m} {incr j} { incr s [expr {$a($i,$j) * 2}] } }; return $s }
proc da_col {n m} { for {set j 0} {$j < $m} {incr j} { for {set i 0} {$i < $n} {incr i} { set a($i,$j) [expr {$i + $j}] } }; set s 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $m} {incr j} { incr s $a($i,$j) } }; return $s }
proc da_ragged {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j <= $i} {incr j} { set a($i,$j) [expr {$i * $j}] } }; set s 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j <= $i} {incr j} { incr s $a($i,$j) } }; return $s }
proc da_twogap {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 3} {incr j} { if {$j != 1 || $i != 1} { set a($i,$j) [expr {$i + $j}] } } }; return [list $a(0,0) $a(1,0) $a(2,2)] }
proc da_twomissing {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 3} {incr j} { set a($i,$j) 1 } }; return $a(1,3) }
proc da_twoexists {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 3} {incr j} { set a($i,$j) 1 } }; list [info exists a(1,2)] [info exists a(1,3)] [info exists a(3,0)] [info exists a(0,0)] [info exists a(2,-1)] }
proc da_twoincr {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 4} {incr j} { incr c($i,$j) [expr {$i + 1}] } }; set s 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 4} {incr j} { incr s $c($i,$j) } }; return $s }
proc da_twostr {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 2} {incr j} { set a($i,$j) "v$i$j" } }; return [list $a(0,0) $a(1,1) $a([expr {$n - 1}],1)] }
proc da_twomix {} { set a(0,0) 1; set a(0,1) 2; set a(1,0) 3; set a(x) 4; set a(1,1) 5; return [list $a(0,0) $a(0,1) $a(1,0) $a(x) $a(1,1)] }
proc da_twokeys {} { set i 1; set j 2; set a($i,$j) 1; set a($i, $j) 2; set a(1,02) 3; set a($i,$j,$i) 4; return [list $a(1,2) $a(1, 2) $a(1,02) $a(1,2,1)] }
proc da_twodim {} { set a(0,0) 1; set a(1) 2; return [list $a(0,0) $a(1)] }
proc da_matmul {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set a($i,$j) [expr {$i + $j}]; set b($i,$j) [expr {$i - $j}] } }
    set t 0
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set s 0; for {set k 0} {$k < $n} {incr k} { incr s [expr {$a($i,$k) * $b($k,$j)}] }; incr t $s } }
    return $t
}
proc da_lcs {x y} {
    set n [string length $x]; set m [string length $y]
    for {set i 0} {$i <= $n} {incr i} { for {set j 0} {$j <= $m} {incr j} { set d($i,$j) 0 } }
    for {set i 1} {$i <= $n} {incr i} { for {set j 1} {$j <= $m} {incr j} {
        if {[string index $x [expr {$i - 1}]] eq [string index $y [expr {$j - 1}]]} { set d($i,$j) [expr {$d([expr {$i - 1}],[expr {$j - 1}]) + 1}] } else { set u $d([expr {$i - 1}],$j); set l $d($i,[expr {$j - 1}]); set d($i,$j) [expr {$u > $l ? $u : $l}] } } }
    return $d($n,$m)
}
# dense arrays of doubles and of numbers of either kind (element kinds D and W): the unboxed values come back as the numbers they were, with the text the interpreter gives them
proc da_dbl {n} { for {set i 0} {$i < $n} {incr i} { set a($i) [expr {$i * 0.25}] }; set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $a($i)}] }; return [list $s $a(0) [expr {$n > 1 ? $a(1) : 0}] $a([expr {$n - 1}])] }
proc da_dmix {n} { for {set i 0} {$i < $n} {incr i} { if {$i % 2} { set a($i) [expr {$i * 1.5}] } else { set a($i) $i } }; set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $a($i)}] }; return [list $s $a(0) [expr {$n > 1 ? $a(1) : 0}] [expr {$n > 2 ? $a(2) : 0}]] }
proc da_dinf {} { set a(0) [expr {1e308 * 10}]; set a(1) [expr {-1e308 * 10}]; set a(2) [expr {-0.0}]; set a(3) [expr {0.1 + 0.2}]; set a(4) [expr {1e22 * 1.0}]; set a(5) [expr {1.0 / 3.0}]; return [list $a(0) $a(1) $a(2) $a(3) $a(4) $a(5)] }
proc da_dlit {} { set a(0) 0.5; set a(1) 1e3; set a(2) 0.50; set a(3) 2.0; return [list $a(0) $a(1) $a(2) $a(3)] }
proc da_dover {} { set a(0) 1; set a(0) [expr {2.5 + 0.0}]; set a(1) [expr {3 * 1.0}]; set a(1) 4; return [list $a(0) $a(1) [expr {$a(0) + $a(1)}]] }
proc da_dstr {} { set a(0) [expr {1.5 + 0.0}]; set a(1) abc; set a(2) [expr {2 * 0.5}]; return [list $a(0) $a(1) $a(2)] }
proc da_dincr {} { set a(0) [expr {1.5 + 0.0}]; return [list $a(0) [catch {incr a(0)} m] $m] }
proc da_dtwo {n m} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $m} {incr j} { set a($i,$j) [expr {$i / 2.0 + $j}] } }; set s 0.0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $m} {incr j} { set s [expr {$s + $a($i,$j) * 2}] } }; return $s }
proc da_dmul {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set a($i,$j) [expr {($i + $j) * 0.5}]; set b($i,$j) [expr {($i - $j) / 4.0}] } }
    set t 0.0
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set s 0.0; for {set k 0} {$k < $n} {incr k} { set s [expr {$s + $a($i,$k) * $b($k,$j)}] }; set t [expr {$t + $s}] } }
    return $t
}
proc da_dnbody {n} {
    for {set i 0} {$i < 4} {incr i} { set x($i) [expr {$i * 1.0}]; set v($i) [expr {0.5 - $i * 0.25}] }
    for {set s 0} {$s < $n} {incr s} { for {set i 0} {$i < 4} {incr i} { set x($i) [expr {$x($i) + 0.01 * $v($i)}]; set v($i) [expr {$v($i) - 0.02 * $x($i)}] } }
    return [list $x(0) $x(1) $x(2) $x(3) $v(0)]
}
# a key `$i,$j` kept as two integers while the value of the store is computed with branches and calls between the key and the store
proc da_kbranch {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set a($i,$j) [expr {$i > $j ? [string length x$i] : $j}] } }; set s 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { incr s $a($i,$j) } }; return $s }
proc da_kboth {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 3} {incr j} { incr c($i,$j) [expr {($i + $j) % 2 ? 1 : 2}] } }; set s 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 3} {incr j} { incr s $c($i,$j) } }; return $s }
proc da_kif {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 3} {incr j} { if {$i == 0 || [info exists a([expr {$i - 1}],$j)]} { set a($i,$j) [expr {$i + $j}] } } }; return [list [info exists a(0,0)] [info exists a(1,2)] [info exists a($n,0)]] }
proc da_kloop {n} { set a(0,0) 0; for {set i 0} {$i < $n} {incr i} { set a($i,0) [expr {$i * 2}]; while {[info exists a($i,[expr {$i % 3}])] && $i > 100} { break } }; return $a([expr {$n - 1}],0) }
proc da_kcall {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 2} {incr j} { set a($i,$j) [da_asc 5 $j] } }; set s 0; for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 2} {incr j} { incr s $a($i,$j) } }; return $s }
proc da_kerr {n} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < 2} {incr j} { set a($i,$j) [expr {$i / ($j - 1)}] } }; return $a(0,0) }
# unordered dense arrays (integer keys in any order) and the order a hand-over writes the elements into the frame in: `array names` shows the interpreter's order
proc da_ord_asc {n} { for {set i 0} {$i < $n} {incr i} { set a($i) $i }; return [array names a] }
proc da_ord_desc {n} { for {set i $n} {$i >= 0} {incr i -1} { set a($i) $i }; return [array names a] }
proc da_ord_hist {n m} { for {set i 0} {$i < $n} {incr i} { incr h([expr {($i * 7) % $m}]) }; return [array names h] }
proc da_ord_perm {n} { set x 12345; for {set i 0} {$i < $n} {incr i} { set x [expr {($x * 1103515245 + 12345) % 2147483648}]; set a([expr {$x % ($n * 2)}]) $i }; return [array names a] }
proc da_ord_sparse {} { set a(0) 1; set a(1) 2; set a(1000000) 3; set a(2) 4; set a(70) 5; set a(4095) 6; set a(4096) 7; return [array names a] }
proc da_ord_late {n} { for {set i 0} {$i < $n} {incr i} { set a($i) $i }; set a(x) 1; set a(0) 5; set a($n) 6; return [array names a] }
proc da_ord_two {n m} { for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $m} {incr j} { set a($i,$j) [expr {$i * $j}] } }; return [array names a] }
proc da_ord_col {n m} { for {set j 0} {$j < $m} {incr j} { for {set i 0} {$i < $n} {incr i} { set a($i,$j) [expr {$i * $j}] } }; return [array names a] }
proc da_ord_get {n} { for {set i $n} {$i > 0} {incr i -2} { set a($i) [expr {$i * 2}] }; return [array get a] }
proc da_unord {n} { set x 77; for {set i 0} {$i < $n} {incr i} { set x [expr {($x * 31 + 7) % 101}]; set a($x) $i }; set s 0; for {set k 0} {$k < 101} {incr k} { if {[info exists a($k)]} { incr s $a($k) } }; return $s }
proc da_hole {n} { for {set i 0} {$i < $n} {incr i} { set a([expr {$i * 2}]) $i }; return [list [info exists a(0)] [info exists a(1)] [info exists a([expr {$n * 2 - 2}])] [catch {set a(1)} m] $m] }
proc da_holeinc {n} { for {set i 0} {$i < $n} {incr i} { set a([expr {$i * 2}]) $i }; incr a(1) 5; incr a(0) 3; return [list $a(0) $a(1) [info exists a(3)]] }
proc da_unordmix {n} { for {set i $n} {$i >= 0} {incr i -1} { if {$i % 3 == 0} { set a($i) [expr {$i * 0.5}] } elseif {$i % 3 == 1} { set a($i) $i } else { set a($i) "s$i" } }; set o {}; for {set i 0} {$i <= $n} {incr i} { lappend o $a($i) }; return $o }
proc da_unorddbl {n} { for {set i $n} {$i >= 0} {incr i -1} { set a($i) [expr {$i * 0.25}] }; set s 0.0; for {set i 0} {$i <= $n} {incr i} { set s [expr {$s + $a($i)}] }; return $s }
# lists of integers built with lappend and read with lindex, llength, lset and foreach are held as native vectors (decision 36); every other use of the list keeps it a Tcl list
proc ls_sum {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l [expr {$i * 3 % 7}] }; set s 0; for {set i 0} {$i < $n} {incr i} { incr s [lindex $l $i] }; return [list $s [llength $l]] }
proc ls_for {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l [expr {$i * 7 % 11}] }; set s 0; foreach v $l { if {$v > 5} { incr s $v } }; return $s }
proc ls_ret {n} { set l {}; for {set i -2} {$i < $n} {incr i} { lappend l $i }; return $l }
proc ls_big {} { set l {}; lappend l 9223372036854775807; lappend l -9223372036854775808; lappend l 0; return $l }
proc ls_break {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; set s 0; foreach v $l { if {$v == 5} break; if {$v % 2} continue; incr s $v }; return [list $s $v] }
proc ls_mod {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; set c 0; foreach v $l { if {$c < 3} { lappend l [expr {$v + 100}] }; incr c }; return [list $c [llength $l] $l] }
proc ls_nest {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; set s 0; foreach a $l { foreach b $l { incr s [expr {$a * $b}] } }; return $s }
proc ls_empty {} { set l {}; set c 0; foreach v $l { incr c }; return [list $c [llength $l] [catch {set v} m] $m] }
proc ls_after {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; foreach v $l { }; return $v }
proc ls_idx {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l [expr {$i * $i}] }; return [list [lindex $l end] [lindex $l 0] [lindex $l 100] [lindex $l -1] [lindex $l end-1] [llength $l]] }
proc ls_lset {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; lset l 0 99; lset l end 77; return $l }
proc ls_lseterr {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; lset l $n 5; return $l }
proc ls_reset {n} { set l {}; set t 0; for {set i 0} {$i < $n} {incr i} { set l {}; for {set j 0} {$j <= $i} {incr j} { lappend l $j }; incr t [llength $l] }; return $t }
proc ls_mixed {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; lappend l abc; lappend l 1.5; return $l }
proc ls_pass {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; return [join $l ,] }
proc ls_res {n} { set l {}; set x [lappend l 1]; for {set i 0} {$i < $n} {incr i} { lappend l $i }; return [list $x $l] }
proc ls_hexlit {} { set l {}; lappend l 0x10; lappend l 007; lappend l 1e3; return $l }
proc ls_two {n} { set a {}; set b {}; for {set i 0} {$i < $n} {incr i} { lappend a $i; lappend b [expr {$n - $i}] }; set s 0; for {set i 0} {$i < $n} {incr i} { incr s [expr {[lindex $a $i] * [lindex $b $i]}] }; return $s }
proc ls_copy {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; set m $l; lappend l 5; return [list [llength $l] [llength $m]] }
proc ls_var {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; foreach v $l { set v [expr {$v * 2}]; incr s $v }; return [list [llength $l] $s] }
# comparisons of objects that are not integers (text, lists, doubles, bignums, empty) stay in typed code and take the interpreter's rule: numbers as numbers, anything else as strings
proc cm_lit {x} { if {$x == "plain"} { return 1 }; if {$x != "left"} { return 2 }; return 3 }
proc cm_order {x} { list [expr {$x < "m"}] [expr {$x >= "abc"}] [expr {"b" > $x}] }
proc cm_pair {a b} { if {[lindex $a 0] == $a && [lindex $b 0] == $b} { return [string equal $a $b] }; return -1 }
proc cm_cnt {l key} { set n 0; foreach v $l { if {$v == $key} { incr n } }; return $n }
proc cm_neq {l key} { set n 0; foreach v $l { if {$v != $key} { incr n } }; return $n }
proc cm_min {l} { set m [lindex $l 0]; foreach v $l { if {$v < $m} { set m $v } }; return $m }
proc cm_eqrec {a b} { if {[llength $a] != [llength $b]} { return 0 }; if {[lindex $a 0] == $a && [lindex $b 0] == $b} { return [string equal $a $b] }; foreach i $a j $b { if {![cm_eqrec $i $j]} { return 0 } }; return 1 }
proc cm_mixed {x n} { list [expr {$x == $n}] [expr {$n < $x}] [expr {$x != 2.5}] [expr {$x <= 0x10}] }

# binary format is a built-in that neither reaches the frame nor runs a script: a proc that uses it needs no frame of its own when called from compiled code
proc pb_pack {a b} { return [binary format SIa4 [expr {$a & 0x7fff}] $b abcd] }
proc pb_loop {n} { set t 0; for {set i 0} {$i < $n} {incr i} { incr t [string length [pb_pack $i [expr {$i * 7}]]] }; return $t }
proc pb_fmt {f a} { return [binary format $f $a] }
proc pb_two {f a b} { return [binary format $f $a $b] }
proc pb_lit {} { return [binary format cu3 {1 255 256}] }
proc pb_all {} { return [list [binary format cSsIiWwfd 1 2 3 4 5 6 7 1.5 2.5] [binary format a5A5 ab cd] [binary format b8B8 10110000 10110000] [binary format h3H3 abc abc] [binary format x3a1X2 z] [binary format a*@6 abc] [binary format c* {1 2 3}]] }
proc pb_chain {n} { set r {}; for {set i 0} {$i < $n} {incr i} { append r [pb_pack $i $n] }; return [string length $r] }
proc pb_err {f} { binary format $f 1 }
proc pb_catch {f a} { set r [catch {binary format $f $a} m]; return [list $r $m] }
proc pb_scan {n} { set x [pb_pack $n 5]; binary scan $x S a; return $a }
proc pe_map {s} { return [string map {a A} $s] }
proc pe_mapn {n} { set t 0; for {set i 0} {$i < $n} {incr i} { incr t [string length [pe_map abca]] }; return $t }
proc pe_first {s} { return [string first o $s] }
proc pe_firstn {n} { set t 0; for {set i 0} {$i < $n} {incr i} { incr t [pe_first hello] }; return $t }
proc pe_dsize {d} { return [dict size $d] }
proc pe_dsizen {n} { set t 0; for {set i 0} {$i < $n} {incr i} { incr t [pe_dsize {a 1 b 2}] }; return $t }
