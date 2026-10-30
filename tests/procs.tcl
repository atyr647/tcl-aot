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
