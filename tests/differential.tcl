# Differential test: run every call of the list below with the interpreter alone, load the translated module, define the procs again (they pick up their
# compiled bodies) and run the calls again; results, return codes, error codes (and, with TBC_ERRINFO=1, error info) must be equal.  Then check that
# nothing leaks.  Run it with tests/harness.c's shell (tests/run.sh builds it).
#
# Environment: TBC_EAGER=1 attach compiled bodies when procs are defined instead of at their first call; TBC_NOLEAK=1 stop after the comparison;
# TBC_SMALL=1 leave out calls that loop long (valgrind); TBC_NOASYNC=1 leave out calls that need a second thread; TBC_ERRINFO=1 compare error info;
# TBC_TRACE=1 print each call before it runs; TBC_COV_DETAIL=1 print coverage counters (needs a module compiled with -DTBC_COV);
# TBC_LEAK_ITERS=n iterations of the memory-growth loops.
source [file join [file dirname [info script]] procs.tcl]
set values {0 1 -1 2 7 -7 3 -3 9223372036854775807 -9223372036854775808 4611686018427387904 1.5 -2.5 0.0 3.0 1e3 010 0x1F " 5" abc {} 100000000000000000000 -0.0 true no 1e400 Inf -Inf NaN 1e308 1e-320 1e-300}
set calls {}
foreach a $values { foreach b $values { lappend calls [list t_arith $a $b] [list t_cmp $a $b] } }
# NaN excluded: Tcl_GetBooleanFromObj answers differently for a value that was earlier parsed as a number (same in both builds)
foreach a $values { if {$a ne "NaN"} { lappend calls [list t_truth $a] [list t_while_cond $a] } }
foreach a {0 5 -3 abc 1.5 0x10 9223372036854775807} { foreach b {0 1 -1 9223372036854775807 x 2.5} { lappend calls [list t_incr $a $b] } }
lappend calls {t_unset} {t_unset_incr}
foreach {a b} {1 2 abc def {} {} 1.5 x} { lappend calls [list t_append $a $b] [list t_strcat $a $b] }
lappend calls {t_append_shared abc} {t_append_shared {}}
set lists [list {a b c} {} {a} {1 2 3 4} "\{a b\} c" "a \{b"]
foreach l $lists { foreach i {0 1 2 5 -1 end end-1 abc 1.5 {0 0}} { lappend calls [list t_lindex $l $i] [list t_lset $l $i Z] } }
lappend calls {t_lset_shared {a b c}}
foreach {d k} {{a 1 b 2} a {a 1 b 2} c {} x {a 1} a {a x} a {a} a {a 1 b} b "a 9223372036854775807" a} { lappend calls [list t_dict $d $k] }
lappend calls {t_dict_empty q} {t_dict_empty {}}
foreach {s y} {4 1 4 3 250 17 0 0 0 1 3 abc} { lappend calls [list t_double $s $y] }
foreach n {0 1 5 50} { lappend calls [list t_rec_err $n] [list t_rec_sum $n] }
set bigvals {0 1 -1 5 63 64 65 100 -5 4294967295 9223372036854775807 -9223372036854775808 9223372036854775808 -9223372036854775809 18446744073709551616 -18446744073709551616 340282366920938463463374607431768211456 -340282366920938463463374607431768211457 1.5 abc {} 2147483648 -2147483649 4294967296 {0x7fffffffffffffff} 0xffffffffffffffffff}
foreach a $bigvals { foreach b $bigvals { lappend calls [list t_bigops $a $b] } }
lappend calls {t_noargs} {t_noargs 1} {t_two 1} {t_two 1 2 3} {t_two} {t_call_missing} {t_result_obj_reuse 5} {t_result_obj_reuse abc}
foreach n {0 1 100 1000} { lappend calls [list t_loop_accum $n] }
lappend calls {t_loop_accum 2.5}


# recursion limit: the compiled code must fail at the same depth as the interpreter, whatever the nesting around the call
proc dw0 {p n} { $p $n }
proc dw1 {p n} { dw0 $p $n }
proc maxok {p wrap} {
    set lo 1; set hi 3000
    while {$hi - $lo > 1} { set m [expr {($lo + $hi) / 2}]; if {[catch {{*}$wrap $p $m}]} { set hi $m } else { set lo $m } }
    return $lo
}
# the typed (pure) chains reproduce the limit exactly; a body entered from the interpreter costs one level at the very edge (docs/decisions.md, decision 1):
# the second run reports how far the limit is from the interpreter's, which must be 0 for pure chains and 0 or -1 for the others (reported as ok)
set ::phase A
proc maxok_rel {p wrap} {
    set m [maxok $p $wrap]
    if {$::phase eq "A"} { set ::depthref($p,$wrap) $m; return ok }
    set d [expr {$m - $::depthref($p,$wrap)}]; return [expr {$d == 0 || $d == -1 ? "ok" : $d}]
}
# (a forced hand-over, see tests/run.sh, enters a body from the interpreter in the middle of a chain: the edge is then the one of the other procs)
set depthcmd [expr {[info exists ::env(TBC_FORCE_RATE)] ? "maxok_rel" : "maxok"}]
foreach p {t_rec_sum t_even} { foreach wrap {{} eval dw0 dw1 {uplevel #0}} { lappend calls [list $depthcmd $p $wrap] } }
foreach p {ta_rec_imp ta_imp_even} { foreach wrap {{} eval dw0 dw1 {uplevel #0}} { lappend calls [list maxok_rel $p $wrap] } }
# foreach
foreach l {{} {1} {1 2 3} {1 2 3 4 5 6 7} {a b c} "1 {2 3} 4" {1 x 3} "\{a b" {5 0 2} {1 2 3 4}} {
    foreach m {{} {x} {1 2} {a b c d e}} {
        lappend calls [list tf_two $l $m] [list tf_multi $l $m]
        lappend calls [list tf_nested $l $m] [list tf_nested_break $l $m]
    }
    lappend calls [list tf_sum $l] [list tf_pairs $l] [list tf_break $l] [list tf_continue $l] [list tf_modify $l] [list tf_after $l] [list tf_dict $l] [list tf_catch $l] [list tf_return $l]
    lappend calls [list tf_err $l] [list tf_arg $l] [list tf_global $l] [list tf_inner_proc $l]
}
lappend calls [list tf_break {a stop b}] [list tf_break {stop}] [list tf_continue {skip skip x}] [list tf_continue {a skip b}]
lappend calls {tf_empty} {tf_lit} [list tf_str banana] [list tf_str {}] [list tf_while_in_foreach {1 2 3 0 4}] [list tf_foreach_in_while 5]
lappend calls {tf_sum {1 2 3} extra} {tf_sum}
foreach a {0 1 1.5 -3 abc} { lappend calls [list ta_fold_pow2 $a] [list ta_fold_pow2b $a] }
# batch B
set bvals {0 1 -1 5 -7 3.5 -2.5 abc {} 0x10 9223372036854775807 -9223372036854775808 100000000000000000000 2 64 63 1e3 true false}
foreach a $bvals {
    lappend calls [list tb_neg $a] [list tb_pos $a] [list tb_not $a] [list tb_bnot $a]
    foreach b $bvals {
        lappend calls [list tb_band $a $b] [list tb_bor $a $b] [list tb_bxor $a $b] [list tb_shl $a $b] [list tb_shr $a $b] [list tb_pow $a $b] [list tb_seq $a $b]
    }
}
foreach l {{} {a b c} {1 2.0 3} "a {b c} d" "\{a"} { foreach a {a 1 2 {b c} {} 2.0} { lappend calls [list tb_in $a $l] [list tb_ni $a $l] }
    lappend calls [list tb_lrange_imm $l] [list tb_lexpand $l $l] [list tb_lexpand a $l] [list tb_concat $l a $l]
    foreach i {0 1 2 end -1 x} { foreach j {0 1 end 5} { lappend calls [list tb_lindex_multi $l $i $j] [list tb_lset_flat $l $i $j V] } } }
foreach s {abc ABC aBc "" a "hello world" "12345" "ab 12" "été" "x\u0000y"} {
    foreach i {0 1 2 end end-1 -1 99 x 1.5 {}} { lappend calls [list tb_sindex $s $i] }
    lappend calls [list tb_srange_imm $s] [list tb_scase $s] [list tb_sclass $s] [list tb_re $s] [list tb_re_bad $s]
    foreach c {a {} " " "bc"} { lappend calls [list tb_strim $s $c] [list tb_sfirst $c $s] }
    foreach p {a* *b? ?B* {} * "\[a-c\]*"} { lappend calls [list tb_smatch $p $s] }
    foreach {x y} {a Z b {} {} q} { lappend calls [list tb_smap $x $y $s] }
    foreach {a b} {0 1 1 end 2 99 -3 1 x 1} { lappend calls [list tb_srange $s $a $b] [list tb_sreplace $s $a $b XY] }
    lappend calls [list tb_switch $s] [list tb_switch_glob $s] [list tb_switch_re $s] [list tb_switch_nodefault $s]
}
lappend calls {tb_switch "x y"} {tb_switch b} {tb_switch c} {tb_switch_nodefault b}
foreach {k v} {a 1 b hello {} {} x y} { lappend calls [list tb_arr $k $v] [list tb_arr_err $k] [list tb_arr_notarr $k] [list tb_arr_incr_err $k] [list tb_arr_unset_err $k] }
foreach {n v} {x 5 y abc z {} w 1.5 {} 3} { lappend calls [list tb_named $n $v] [list tb_named_arr $n k $v] [list tb_named_err $n] }
lappend calls {tb_named_local} {tb_info_level} {tb_info_level_err 0} {tb_info_level_err 1} {tb_info_level_err -1} {tb_info_level_err 99} {tb_info_level_err x} {tb_ns_current} {tb_exist_local 0} {tb_exist_local 1}
lappend calls {namespace eval tns { tb_ns_current }} {namespace eval tns { tb_info_level }}

foreach {a b} {1 2 x {y z} {} {} "\{" a} { lappend calls [list tb_lappend_multi {p q} $a $b] [list tb_lappend_multi {} $a $b] [list tb_lappend_multi_new $a $b] [list tb_lappend_multi_arr k $a $b] [list tb_lappend_multi_named v $a $b] [list tb_lappend_multi_named_arr arrx k $a $b] [list tb_lappend_bad $a] [list tb_lappend_multi "\{x" $a $b] }
# batch C
foreach {a b} {{} {} {1 2} {3} "a {b c}" {d} "\{x" {y} {x y z} {}} {
    lappend calls [list tc_expand $a $b] [list tc_expand_nested $a $b] [list tc_expand_bad $a] [list tc_expand_break $a] [list tc_expand_catch $a]
}
lappend calls [list tc_expand_call {a b c}] [list tc_expand_call {}] [list tc_expand_call "\{a"] [list tc_expand_empty {}] [list tc_expand_empty {list a b}] [list tc_expand_empty {nosuchcmd 1}] [list tc_expand_empty "\{"]
lappend calls [list tc_expand_err {{a b c} 1}] [list tc_expand_err {{a b c} x}] [list tc_expand_err {}] [list tc_expand_loop {a b {c d}}] [list tc_expand_loop {{} {x y}}] [list tc_expand_cont {a b c d}]
foreach {d k v} {{} a 1 {a 2} a 3 {a 1 b 2} c {x y} {l 5} l 6 {a "\{"} a 1} { lappend calls [list tc_dict $d $k $v] }
foreach {k v} {a 1 {} {} x "y z"} { lappend calls [list tc_dict_new $k $v] [list tc_dict_bad $k] [list tc_dict_unset_miss $k] [list tc_dict_lappend_bad $k] }
lappend calls {tc_arrmake} {tc_arrmake_scalar} {tc_arrmake_named xx} {tc_arrmake_named {}} {tc_arrmake_named a(b)}
foreach e {1+1 1/0 abc {$x*2} {$x + $nosuch} {} { 3 } {1 +} {[list 1 2]} {"a" eq "a"} {$x ? 1 : 2} {int(2.5)} {rand() < 2} {} } { lappend calls [list tc_exprs $e] }
foreach a {0 1 -1 123 1.5 abc {} 0x10 4294967296 4294967295 2147483648 9223372036854775807 9223372036854775808 100000000000000000000 -9223372036854775808 1e3 " 5"} { lappend calls [list tc_numtype $a] [list tc_bool $a 1] [list tc_bool $a 0] }
lappend calls {tc_clock}
foreach n {set ::set nosuch string ::tcl::string::length tc_which ::tc_which {} namespace::nosuch} { lappend calls [list tc_which $n] }
lappend calls {interp alias {} myalias {} set; tc_which myalias} {catch {rename tc_cmdmoved2 {}}; proc tc_cmdmoved {} {}; rename tc_cmdmoved tc_cmdmoved2; tc_which tc_cmdmoved2}

# the poll in loops: an async handler, a time limit and a cancel must be able to stop a loop that never ends
foreach n {0 5 100000} { lappend calls [list td_spin $n] [list td_spin_g $n] [list td_foreach [lrepeat $n x]] }
# (an asynchronous handler is marked from another thread, which a wasm guest does not have: TBC_NOASYNC=1 leaves these four out there)
if {![info exists ::env(TBC_NOASYNC)]} {
lappend calls {tbcasync 50; set rc [catch {td_inf} m]; list $rc $m}
lappend calls {tbcasync 50; set rc [catch {td_inf2 5} m]; list $rc $m}
lappend calls {tbcasync 50; set rc [catch {td_inf3} m]; list $rc $m}
lappend calls {tbcasync 50; set rc [catch {td_inf4 {1 2 3}} m]; list $rc $m}
}


# batch D
foreach d {{} {a 1} {a 1 b 2} {a 1 b 2 c 3} {a {b {c 1}} b 7} "a \{x" {a {b 1}}} {
    lappend calls [list te_dupdate $d] [list te_dupdate_err $d] [list te_dupdate_break $d] [list te_dwith $d] [list te_dwith_ret $d] [list te_dwith_path $d a] [list te_dwith_path $d x]
    foreach {k1 k2 k3} {a b c a b x x y z} { lappend calls [list te_dpath $d $k1 $k2 $k3] [list te_dpath2 $d $k1 $k2] }
}
foreach sc {{set x 1} {error oops} {return 5} {break} {continue} {expr 1+} {nosuchcmd} {} {list a b} {incr nosuchvar}} { lappend calls [list te_evalstk $sc] [list te_evalstk_loop $sc] [list te_evalstk_brk $sc] }
lappend calls {te_coro} {coroutine tcor te_coro; tcor} {coroutine tcor2 apply {{} { yield [te_coro]; return [te_coro] }}; list [tcor2]}

# coroutines
lappend calls {catch {rename tgc1 {}}; set a [coroutine tgc1 tg_outer 1]; set b [tgc1 hello]; list $a $b [info commands tgc1]}
lappend calls {catch {rename tgc2 {}}; set a [coroutine tgc2 tg_outer2 3]; set b [tgc2 x]; set c [tgc2 y]; set d [tgc2 z]; list $a $b $c $d}
lappend calls {catch {rename tgc3 {}}; set a [coroutine tgc3 tg_outer3 5]; set b [tgc3 w]; list $a $b}
lappend calls {tg_start} {tg_consume}
lappend calls {tg_yielder 1} {catch {tg_outer 1} m; set m}

# command frames
lappend calls {th_frame} {th_frame2 1} {th_frame_cmd} {th_frame_proc} {th_uplevel} {th_eval} {th_eval_line} {th_err_line} {th_err_line2} {th_info_level} {proc th_wrap {} { th_frame_cmd }; th_wrap} {proc th_wrap2 {} { return [list [th_frame] [th_eval_line]] }; th_wrap2}

# the same inside a coroutine (where compiled procs hand over to the interpreter)
foreach p {th_frame th_frame2 th_frame_cmd th_frame_proc th_uplevel th_eval th_eval_line th_err_line th_err_line2 th_info_level th_dbg1 th_dbg4} {
    lappend calls "catch {rename thc {}}; coroutine thc apply {{p args} { yield \[$p {*}\$args\]; return done }} $p 1; "
    lappend calls "catch {rename thc {}}; set r \[coroutine thc $p\]; catch {rename thc {}}; set r"
}

# procs that cannot yield run compiled inside a coroutine; the results, errors and error info must be the interpreter's
foreach spec {
    {tr_basic 7} {tr_order 9} {tr_grow 20} {tr_pair 5} {tr_rec 6} {tr_catch 1} {tr_catch x} {tr_missing_elem 3} {tr_incr_text abc} {tr_exists_order 11 4294967296}
    {tf_sum {1 2 3}} {tf_after {1 2}} {tf_err {1 0}} {tfe_calls 10} {tfe_err {1 0 2}} {tq_sq 12} {t_rec_sum 50} {t_rec_sum 100000} {tfx_eff abc}
} {
    lappend calls "catch {rename tcy {}}; coroutine tcy apply {{p args} { yield \[catch {\$p {*}\$args} m\]; return \$m }} $spec; set a \[tcy\]; catch {rename tcy {}}; set a"
    lappend calls "catch {rename tcy {}}; set r \[catch {coroutine tcy {*}{$spec}} m\]; catch {rename tcy {}}; list \$r \$m"
    lappend calls "catch {rename tcy {}}; coroutine tcy apply {{p args} { yield 1; set r \[catch {\$p {*}\$args} m\]; list \$r \$m }} $spec; tcy; set a \[tcy\]; catch {rename tcy {}}; set a"
}
lappend calls {catch {rename tcy {}}; set a [coroutine tcy apply {{} { yield [ty_mid 1]; return end }}]; set b [tcy]; catch {rename tcy {}}; list $a $b}
lappend calls {rename ty_leaf ty_leaf_orig; proc ty_leaf {x} { yield $x; return 5 }; catch {rename tcy {}}; set a [coroutine tcy apply {{} { yield [ty_mid 1]; return end }}]; set b [tcy]; set c [catch {tcy} m]; catch {rename tcy {}}; rename ty_leaf {}; rename ty_leaf_orig ty_leaf; list $a $b $c $m}
lappend calls {catch {rename tcy {}}; set a [coroutine tcy apply {{} { yield [ty_mid 1]; return end }}]; catch {rename tcy {}}; set a}
# built-ins replaced after the procs were compiled against them
lappend calls {tb_rev {1 2 3}} {tbns::rev2 {1 2 3}} {tb_ins {a b}}
lappend calls {rename linsert linsert_orig; proc linsert {l i v} { uplevel 1 {set x 66}; return LI }; set a [tb_ins {a b}]; rename linsert {}; rename linsert_orig linsert; set a}
lappend calls {tb_ins {a b}}
lappend calls {namespace eval tbns { proc lreverse {l} { uplevel 1 {set x 55}; return NS } }; set a [tbns::rev2 {1 2}]; set b [tb_rev {1 2}]; namespace eval tbns { rename lreverse {} }; list $a $b}
lappend calls {tbns::rev2 {1 2}} {tb_rev {1 2}}
lappend calls {rename lreverse lrv_orig; proc lreverse {l} { uplevel 1 {set x 77}; return RL }; set a [list [tb_rev {1 2}] [tbns::rev2 {1 2}]]; rename lreverse {}; rename lrv_orig lreverse; set a}
lappend calls {tb_rev {1 2}} {tbns::rev2 {1 2}}
# procs that yield, run as coroutines: every value that goes in and out, errors, deletion while suspended
proc tco {name body} { catch {rename $name {}}; set r [uplevel 1 $body]; catch {rename $name {}}; return $r }
foreach n {0 1 3} { lappend calls [list tco tyc "set r \[coroutine tyc ty_gen $n\]; while {\[llength \[info commands tyc\]\]} { lappend r \[tyc\] }; set r"] }
lappend calls {tco tyc {set r [coroutine tyc ty_echo]; lappend r [tyc a] [tyc b c] [tyc stop]; set r}}
lappend calls {tco tyc {set r [coroutine tyc ty_genw 3]; lappend r [tyc] [tyc] [tyc]; set r}}
lappend calls {tco tyc {set r [coroutine tyc ty_yerr]; lappend r [catch {tyc} m] $m [info commands tyc]}}
lappend calls {tco tyc {set r [coroutine tyc ty_ycatch]; lappend r [tyc x] [tyc y] [tyc z]}}
lappend calls {tco tyc {set r [coroutine tyc ty_ylist {a b c}]; lappend r [tyc] [tyc] [tyc]}}
lappend calls {tco tyc {set r [coroutine tyc ty_yfe2 {1 2 3}]; lappend r [tyc 10] [tyc 20] [tyc 30]}}
lappend calls {tco tyc {set r [coroutine tyc ty_yvars]; lappend r [tyc] [tyc]}}
lappend calls {tco tyc {set r [coroutine tyc ty_yto 1 2]; lappend r [tyc a b]}}
lappend calls {tco tyc {coroutine tyc ty_ytocmd}}
lappend calls {tco tyc {set r [coroutine tyc ty_ylevel]; lappend r [tyc]}}
lappend calls {tco tyc {set r [coroutine tyc ty_yret]; lappend r [catch {tyc} m o] $m [dict get $o -errorcode]}}
lappend calls {tco tyc {set r [coroutine tyc ty_ytail]; lappend r [tyc]}}
lappend calls {tco tyc {set r [coroutine tyc ty_ynested]; lappend r [tyc 1] [tyc 2]}}
lappend calls {tco tyc {set r [coroutine tyc ty_yarr 2]; lappend r [tyc u] [tyc v]}}
lappend calls {tco tyc {set r [coroutine tyc ty_ydict]; lappend r [tyc] [tyc]}}
lappend calls {tco tyc {set r [coroutine tyc ty_ydictfor]; lappend r [tyc] [tyc]}}
lappend calls {tco tyc {set r [coroutine tyc ty_yexpand]; lappend r [tyc {p q}]}}
lappend calls {tco tyc {set r [coroutine tyc ty_ytwice]; lappend r [tyc 3] [tyc 4]}}
lappend calls {tco tyc {set r [coroutine tyc ty_ycoro]; lappend r [tyc]}}
lappend calls {tco tyc {coroutine tyc ty_gen 3; tyc; rename tyc {}; info commands tyc}}
lappend calls {tco tyc {coroutine tyc ty_gen 3; tyc; set r [catch {tyc 1 2} m]; list $r $m}}
lappend calls {catch {ty_gen 2} m; set m}
lappend calls {catch {ty_yfe2 {1 2}} m; set m}
lappend calls {tco tyc {coroutine tyc ty_gen 2; coroutine tyd ty_gen 2; set r [list [tyc] [tyd] [tyc] [tyd]]; catch {rename tyd {}}; set r}}
lappend calls {tco tyc {coroutine tyc apply {{} { set r {}; coroutine tyd ty_gen 2; lappend r [tyd] [tyd]; yield $r; return end }}}}
lappend calls {tco tyc {coroutine tyc apply {{} { yield [ty_work 20]; yield [ty_gen 1]; return end }}}}
# the same with typed code entered again after the yield
foreach {n k} {0 3 1 1 3 7 6 20} { lappend calls "tco tyc {set r \[coroutine tyc ty2_heavy $n $k\]; while {\[llength \[info commands tyc\]\]} { lappend r \[tyc\] }; set r}" }
foreach n {0 1 3 5} { lappend calls "tco tyc {set r \[coroutine tyc ty2_dbl $n\]; while {\[llength \[info commands tyc\]\]} { lappend r \[tyc\] }; set r}" }
foreach l {{} {1} {1 2 3} {a b}} { lappend calls "tco tyc {set r \[coroutine tyc ty2_fe {$l}\]; set i 0; while {\[llength \[info commands tyc\]\]} { lappend r \[tyc v\[incr i\]\] }; set r}" }
foreach n {0 1 2 3 5} {
    foreach p {ty2_flag ty2_nonint ty2_unset ty2_ret ty2_retd ty2_catch ty2_while ty2_errloop ty2_list ty2_arr ty2_yto ty2_twice} {
        lappend calls "tco tyc {set r \[coroutine tyc $p $n\]; set i 0; while {\[llength \[info commands tyc\]\]} { if {\[catch {tyc w\[incr i\]} m\]} { lappend r E:\$m } else { lappend r \$m } }; set r}"
    }
}
foreach n {0 2 4} { lappend calls "tco tyc {set r \[coroutine tyc ty2_inner_yield $n\]; while {\[llength \[info commands tyc\]\]} { lappend r \[tyc\] }; set r}" }
foreach n {0 2} { lappend calls "tco tyc {set r \[coroutine tyc ty2_lit $n\]; lappend r \[tyc X\]}" }
foreach {a b} {1 2 -3 4 9223372036854775800 5 abc 2 1 abc} { lappend calls "tco tyc {set r \[catch {coroutine tyc ty2_args $a $b} m\]; if {\$r == 0} { lappend r \$m; lappend r \[catch {tyc} m2\] \$m2 }; set r}" }
# built-ins replaced by an alias in the proc's namespace, by an import, by hiding; and procs using built-ins that only Tcl's own namespaces have a command of the same name
lappend calls {tbal::rev {1 2 3}} {tbim::rev {1 2 3}} {tb_hide {1 2 3}} {tb_fmt {a b c}} {tb_spl a,b,c}
lappend calls {proc ::tb_alias_target {l} { uplevel 1 {set x 44}; return AL }; interp alias {} ::tbal::lreverse {} ::tb_alias_target; set a [tbal::rev {1 2}]; interp alias {} ::tbal::lreverse {}; list $a [tbal::rev {1 2}]}
lappend calls {namespace eval tbexp { proc lreverse {l} { uplevel 1 {set x 33}; return IM }; namespace export lreverse }; namespace eval tbim { namespace import ::tbexp::lreverse }; set a [tbim::rev {1 2}]; namespace eval tbim { namespace forget ::tbexp::lreverse }; list $a [tbim::rev {1 2}]}
lappend calls {interp hide {} lreverse; set a [catch {tb_hide {1 2}} m]; interp expose {} lreverse; list $a $m [tb_hide {1 2}]}
lappend calls {set r [tb_self {1 2}]; rename lreverse {}; rename tb_self_orig lreverse; set r}
lappend calls {set r [tb_self2 5]; rename lreverse {}; rename tb_self2_orig lreverse; set r}
lappend calls {tb_hide {1 2}} {tbal::rev {1 2}} {tbim::rev {1 2}} {tb_fmt {x y}} {tb_spl x,y}
# integer literals written non-canonically
foreach x {0 1 -1 5 255 256 -256 4294967295 9223372036854775807 -9223372036854775808 1.5 abc {} 0x10 " 5"} { lappend calls [list tl_lit $x] [list tl_lit_big $x] }
foreach n {0 1 10 1000} { lappend calls [list tl_lit_loop $n] }
foreach a {-2 -1 0 1 2.5} { foreach b {0 5 9007199254740993 -9007199254740993} { lappend calls [list tl_lit_fold $a $b] } }
foreach x {0 1 -1 255 9223372036854775807 -9223372036854775808} { lappend calls [list tl_lit_big2 $x] }
# binary scan with a number format and *: lengths that are not a multiple of the size, bytes of every sign, characters above 255, values that are not strings of bytes
set bsd [list {} a ab abc abcd abcde abcdefgh "\x00\x01\x7f\x80\xff" "\xff\xff\xff\xff" "\x80\x00\x00\x00" "\x00\x00\x00\x80" "\xfe\xdc\xba\x98\x76\x54\x32\x10\x01" "é€x" 1234 {a b} 1.5]
foreach tbs_t {c cu s su S Su i iu I Iu} { foreach d $bsd { lappend calls [list tbs_$tbs_t $d] [list tbs_sum_$tbs_t $d] } }
foreach d $bsd { lappend calls [list tbs_use $d] [list tbs_twice $d] [list tbs_arr $d] [list tbs_elem $d] [list tbs_noarg $d] [list tbs_fmt $d c*] [list tbs_fmt $d i2] [list tbs_fmt $d I*] }
lappend calls {tbs_lit}
# typed code handing over before a loop, and the boxed code entering typed code again at the loop head
foreach n {0 1 -1 5 7 255 100000 9223372036854775807 -9223372036854775808 abc 1.5 {}} { foreach p {os_big os_giveup os_mid os_nested os_foreach os_while os_error os_catch os_return os_dbl} { lappend calls [list $p $n] } }
foreach {a b} {0 0 1 5 -3 7 9223372036854775807 1 abc 1 1 abc 1.5 2} { lappend calls [list os_args $a $b] }
foreach n {0 1 5 300} { lappend calls "tco tyc {list \[coroutine tyc ty_same $n\] \[tyc\]}" }
# tailcall
foreach x {1 abc {}} { lappend calls [list ti_tc1 $x] [list ti_tc_catch $x] [list ti_tc_after $x] [list ti_tc_lambda $x] }
lappend calls {ti_tc_loop 0} {ti_tc_loop 50} {ti_tc_loop 100000} {ti_tc_noarg} {ti_tc_ns} {ti_tc1} {ti_tc1 1 2}

# NUL and non-ASCII characters in literals
foreach s [list {} "a\0b" "\0" "x\0\0y" "é" "a b"] { lappend calls [list tk_nul $s] [list tk_nul2 $s] [list tk_uni $s] }

# ---- typed-code additions
proc dbl {v} { expr {double($v)} }
foreach n {0 1 7 100 3000 6000 10000 30000} { lappend calls [list t_sumpow $n] }
foreach n {0 1 2 10 50 92 93 94 100 200} { lappend calls [list t_fibloop $n] }
foreach {a b} {1 2 -7 3 100 7 9223372036854775807 4 2.5 3 x 1 {} 2} { lappend calls [list t_mixed $a $b] }
foreach n {0 1 5 1000} { lappend calls [list t_dblloop $n] }
foreach n {0 1 -1 5 9223372036854775807 -9223372036854775808} { lappend calls [list t_neg $n] "t_neg \[dbl $n\]" }
foreach n {0 1 5 -3 4611686018427387904 abc} { lappend calls [list t_caller $n] [list t_caller2 [expr {[string is integer $n] && abs($n) < 100000 ? $n : 3}]] [list t_caller_str $n] }
lappend calls {t_caller 1 2} {t_caller2}
foreach n {0 1 2 10 100 1000} { lappend calls [list t_sieve_small $n] }
foreach l $lists { lappend calls [list t_lindex_oob $l] }
foreach i {0 1 2 3 -1 end abc 1.5 {}} { lappend calls [list t_lset_oob {a b c} $i] [list t_lset_oob {} $i] [list t_lset_oob {a b c} $i] }
foreach n {0 1 5 120} { lappend calls [list t_strbuild2 $n] }
foreach {a b} {1 2 abc def {} {} 1.5 -3 9223372036854775807 0} { lappend calls [list t_cat $a $b] }
foreach x {-5 0 5 10 100 abc 1.5 {} 9223372036854775807} { lappend calls [list t_ifchain $x] }
foreach n {0 1 5 1000 -3 abc 2.5} { lappend calls [list t_countdown $n] }
foreach n {1 2 3 6 7 27 97 871 100000 1000000 abc} { lappend calls [list t_collatz1 $n] }
foreach {a b} {12 18 17 5 0 5 5 0 -12 18 12 -18 9223372036854775807 3 abc 4 100000000000000000000 6} { lappend calls [list t_gcd $a $b] }
foreach n {0 1 10 62 63 64 65 100 1000} { lappend calls [list t_pow2 $n] }
foreach n {0 1 5 20 21 22 25 30 100} { lappend calls [list t_rec_fact $n] }
foreach n {0 1 2 10 101 400} { lappend calls [list t_even $n] }
foreach n {900} { lappend calls [list t_rec_sum $n] [list t_rec_fact $n] [list t_even $n] }
# past the limit: same message, code and chain length (the topmost line of the chain names the callee's first command instead of the call: docs/decisions.md, decision 1)
foreach p {t_rec_sum t_rec_fact t_even} { lappend calls "catch {$p 1500} r o; list \$r \[dict get \$o -errorcode\] \[llength \[split \[dict get \$o -errorinfo\] \\n\]\]" }
# arguments that are doubles with no string form (so the double-typed variants are used) and mixed
set dvals {1.5 -2.5 0.0 3.0 -0.0 1e3 1e308 1e-320 1e-300 Inf -Inf NaN 0.1 100000000000.5}
foreach a $dvals { foreach b $dvals { lappend calls "t_arith \[dbl $a\] \[dbl $b\]" "t_cmp \[dbl $a\] \[dbl $b\]" } }
foreach a $dvals { foreach b {0 1 -1 7 9223372036854775807 9007199254740993 -9007199254740993} { lappend calls "t_arith \[dbl $a\] $b" "t_arith $b \[dbl $a\]" "t_cmp \[dbl $a\] $b" "t_cmp $b \[dbl $a\]" "t_mixed \[dbl $a\] $b" } }
foreach a $dvals { lappend calls "t_double \[dbl $a\] \[dbl 4\]" "t_neg \[dbl $a\]" }
# redefinition and renaming of a callee while a translated caller is in use
lappend calls {t_caller 5}
lappend calls {proc t_callee {n} { return [expr {$n * 3}] }; t_caller 5}
lappend calls {t_caller2 10}
lappend calls {catch {rename t_callee_moved {}}; rename t_callee t_callee_moved; proc t_callee {n} { return [expr {$n * 5}] }; list [t_caller 5] [t_callee_moved 5]}
lappend calls {rename t_callee {}; catch {t_caller 5} r; set r}
lappend calls {proc t_callee {n} { return [expr {$n * 7}] }; t_caller 5}


# int vectors
foreach n {0 1 2 10 100 1000} { lappend calls [list t_vec_sieve $n] }
foreach {n i} {3 4294967295 3 4294967296 3 -4294967295 3 -4294967296 3 2147483648 3 -2147483648 3 9223372036854775807 3 0 3 2 3 3 3 -1 3 100 3 end 3 abc 3 1.5 3 end-1 0 0 1 0 5 4} { lappend calls [list t_vec_oob $n $i] [list t_vec_lset_oob $n $i] }
foreach n {0 1 3} { lappend calls [list t_vec_escape $n] [list t_vec_use $n] [list t_vec_alias $n] }
foreach n {3 5} { foreach x {7 abc 2.5 {} 9223372036854775807 0x10} { lappend calls [list t_vec_midlset $n $x] [list t_vec_midlset2 $n $x] } }
foreach n {1 3 10 50} { lappend calls [list t_vec_realloc $n] [list t_vec_two $n] [list t_vec_redef $n] }
lappend calls {t_vec_cond 1} {t_vec_cond 0} {t_vec_neg -1} {t_vec_neg 0} {t_vec_neg abc} {t_vec_neg 2.5} {t_vec_dbl 3} {t_vec_dbl 1}
lappend calls {t_vec_big 5 abc} {t_vec_big 5 7} {t_vec_big 3 2.5}
lappend calls {t_vec_redef 2}
foreach l $lists { foreach i {4294967295 4294967296 -4294967295 -4294967296 2147483648 9223372036854775807} { lappend calls [list t_lindex $l $i] [list t_lset $l $i Z] } }
foreach n {0 1 2 3 4} { lappend calls [list t_vec_imm $n] }
foreach l $lists { lappend calls [list t_list_ops $l] [list t_list_len $l] }
lappend calls {t_list_ops {a {b}}} {t_list_len abc} {t_list_ops 5} {t_list_ops {1 2 3 4 5}}


# frame-variable access, int maps
foreach n {0 3} { lappend calls [list t_frame_eval $n] [list t_frame_uplevel $n] [list t_frame_time $n] }
foreach {n m} {0 5 1 5 10 3 100 7 1000 1000 5000 13 30 1} { lappend calls [list t_map_count $n $m] }
foreach n {0 1 5 20 100} { lappend calls [list t_map_order $n] [list t_map_escape $n] [list t_map_keys $n] [list t_map_alias $n] [list t_map_snapshot $n] [list t_map_nokey $n] [list t_map_empty $n] }
foreach n {0 1 2 3 4 5} { lappend calls [list t_map_overflow $n] }
foreach x {a 5 007 1.5 {} {a b} 9223372036854775807 -3} { lappend calls [list t_map_dkey $x] }


foreach {n x} {0 a 3 {b c} 5 {} 2 {x y} 1 9223372036854775807} { lappend calls [list t_lappend $n $x] }
foreach x [list a {b c} {} 5 "a \173b"] { lappend calls [list t_lappend_self $x] }
lappend calls {t_lappend_bad}
foreach {d k} {{a 1 b 2} a {a 1 b 2} c {} x {a 1} a {a {x y}} a {a 1 b} b {1 2 3 4} 3 "a 1 b 2" "b"} { lappend calls [list t_dictget $d $k] }
foreach {n k} {5 0 5 4 5 5 0 0 5 abc 5 {} 5 004} { lappend calls [list t_dictget_map $n $k] }

foreach n {0 1 2 3 5} { lappend calls [list t_vec_ret $n] [list t_vec_ret2 $n] [list t_map_ret $n] }

# lrepeat redefined while translated procs that use it as an int vector are running
lappend calls {t_vec_sieve 10}
lappend calls {rename lrepeat tbc_lr_saved; proc lrepeat {n v} {return [list 5 6 7]}; set rc [catch {list [t_vec_two 3] [t_vec_sieve 3] [t_vec_escape 3] [t_vec_use 2]} r]; rename lrepeat {}; rename tbc_lr_saved lrepeat; list $rc $r}
lappend calls {t_vec_sieve 10}
lappend calls {t_vec_two 4}


# default arguments, args, odd names, namespaces
foreach c {{t_defarg 1} {t_defarg 1 2} {t_defarg 1 2 3} {t_defarg 1 2 3 4} {t_defarg} {t_args 1} {t_args 1 2 3 4} {t_args} {t_args_only} {t_args_only a b c}
    {t_defarg_num 10} {t_defarg_num 10 3} {t_defarg_num 10 0 1} {t_call_odd 3} {t_call_odd abc} {t_defarg_call 20} {t_defarg_call 7}
    {t::ns::p 1} {t::ns::p 1 2} {t::ns::q 4} {t::ns::q abc} {t::ns::p}} { lappend calls $c }


# exceptions, control flow, return codes, variable linking
foreach c {{ta_catch 0} {ta_catch 5} {ta_catch abc} {ta_catch_opts 0} {ta_catch_opts 2} {ta_catch_ret 7} {ta_catch_break 2} {ta_catch_break 9} {ta_catch_cont 5}
    {ta_catch_nested 1} {ta_try 0} {ta_try 5} {ta_try_trap 0} {ta_try_trap 1} {ta_loop_break 3} {ta_loop_break 20} {ta_loop_cont 11} {ta_while_break 6}
    {ta_nested_break 5} {ta_return_code 0} {ta_return_code 1} {ta_return_level} {ta_return_opts} {ta_return_plain 1} {ta_return_plain 9} {ta_error_info}
    {ta_fold_pow2c 0 2.0} {ta_fold_pow2c 1e15 2147483647} {ta_fold_pow2c 2.0 4611686018427387904} {ta_fold_pow2c abc 1} {tl_lmap1 {1 2 3}} {tl_lmap1 {}} {tl_lmap1 {a}} {tl_lmap2 {1 2 3 4 1}} {tl_lmap3 {1 2 3} {a b}} {tl_lmap3 {} {a}} {tl_lmap4 {a b stop c}} {tl_lmap4 {}} {tl_lmap5 {{1 2} {3} {}}} {tl_lmap6 {1 2 3}} {tl_lmap6 {1 -2 3}} {tl_lmap7} {tl_arrset_in_loop {{a 1 b 2} {c 3} {}}} {tl_arrset_in_loop {{a 1 b}}} {tl_arrset_odd {a 1 b 2}} {tl_arrset_odd {a 1 b}} {tl_dictfor_in_loop {a 1 b x c 3} {d x} {e 5}} {tl_dictfor_in_loop} {tl_dictfor_break {a 1 b x c 3} {d 4}} {tl_dictfor_ret {a 1} {b x}} {tl_dictfor_ret {a 1}} {tl_dictfor_err {a 1 b x}} {tl_dictfor_err {a 1}} {tl_dictfor_catch {a 1 b x} {c 2}} {tw_caller 5} {tw_caller abc} {tw_caller 1.5} {{tw_odd?} 7} {{tw_star*} 2} {{tw with space} 3} {tb_try1 {a b c d e}} {tb_try1 {}} {tb_try1 {a}} {tb_try2 {a b}} {tb_try2 {a r b}} {tb_try3 {a e}} {tb_catch1 {a e b c}} {tb_catch1 {a c e}} {tb_try4 {a b c}} {tb_try4 {a c}} {tb_try5 1 2} {tb_try5} {t_leak_g 12345 1000} {t_leak_g abc 50} {t_leak_g 0x10 7} {tv_trace_scalar} {tv_trace_array} {tv_trace_wr_veto} {tv_shared_incr} {tv_incr_bad} {tv_arr_elems 0} {tv_arr_elems 7} {tv_arr_missing} {tv_upvar_trace_caller} {ta_upvar_caller} {ta_upvar0} {ta_upvar_bad} {ta_global} {ta_global} {tns::bump} {tns::bump} {ta_nsupvar} {ta_break_outside}
    {catch {ta_error_info} r o; list $r [dict get $o -errorcode] [dict get $o -errorinfo]}} { lappend calls $c }

# variables in the frame: arrays, links.  The calls of this block run at global level (which is what `upvar 1` then means) from a known state.
proc tfx_reset {} { foreach v {tfv tfw tfa tfg tfc tflog} { catch {unset ::$v} }; catch {unset ::tfns::w}; array unset ::tfns::arr; set ::tfns::arr(1) 1; set ::tfns::v 10 }
proc tfx_call {script} { tfx_reset; uplevel #0 $script }
set tfstart [llength $calls]
proc tf_tr {args} { lappend ::tflog $args }
proc tf_tr_err {args} { error "trace says no: $args" }
foreach n {0 1 2 10 50 300} { lappend calls [list tf_sieve $n] [list tf_hist $n] [list tf_fibm $n] [list tf_grid [expr {$n % 12}]] [list tf_keys [expr {$n % 40}]] [list tf_arrays_and_cmds $n] [list tf_unset_mid $n] [list tf_calls_pure $n] [list tf_double_el $n] [list tf_str_el $n] }
foreach k {5 05 5.0 {a b} {} 6 abc 1e3 -5 0x5 { 5}} { lappend calls [list tf_keyforms $k] [list tf_missing $k] [list tf_notarray $k] [list tf_notarray_set $k] }
foreach k {a w s f x b n e} { foreach n {0 1 -1 2 9223372036854775807 -9223372036854775808 abc 1.5 0x10 {} 99999999999999999999} { lappend calls [list tf_incr_el $k $n] } }
foreach k {a w s n x} { lappend calls [list tf_incr_el_imm $k] }
foreach v {0 5 -1 abc 1.5 {} 0x10 99999999999999999999 {a b}} { lappend calls [list tf_set_types $v] }
foreach k {1 2 3 zz 01} { lappend calls [list tf_exists $k] }
lappend calls {tf_shared_el}
lappend calls {uplevel #0 {set ::tfv 5; list [tf_shared_up tfv] $::tfv}}
lappend calls {uplevel #0 {set ::tfv 0x10; list [tf_shared_up tfv] $::tfv}}
lappend calls {uplevel #0 {set ::tfv abc; list [catch {tf_shared_up tfv} m] $m $::tfv}}
lappend calls {uplevel #0 {set ::tfv 1.5; list [catch {tf_shared_up tfv} m] $m $::tfv}}
lappend calls {uplevel #0 {unset -nocomplain ::tfv; list [catch {tf_shared_up tfv} m] $m [info exists ::tfv]}}
foreach n {0 1 5 100} {
    lappend calls "set ::tfv 5; list \[tf_ups_inc tfv $n\] \$::tfv" "set ::tfv 5; list \[tf_ups_incimm tfv $n\] \$::tfv"
    lappend calls "unset -nocomplain ::tfa; list \[tf_ups_arr tfa $n\] \[lsort \[array get ::tfa\]\]"
    lappend calls "set ::tfv 7; list \[tf_ups_level 1 tfv $n\] \$::tfv \[tf_ups_level #0 tfv $n\] \$::tfv"
    lappend calls "list \[tf_ups_same $n\]" "list \[tf_ups_user $n\]" "list \[tf_nsup $n\] \$::tfns::v" "list \[tfns::bumpv $n\]" "list \[tfns::bumparr $n\]"
    lappend calls "unset -nocomplain ::tfg; list \[tf_global_hist $n\]"
}
lappend calls {unset -nocomplain ::tfv; list [catch {tf_ups_inc tfv 3} m] $m [info exists ::tfv]}
lappend calls {unset -nocomplain ::tfv; list [catch {tf_ups_incimm tfv 3} m] $m [info exists ::tfv]}
lappend calls {unset -nocomplain ::tfv; list [catch {tf_ups_set tfv 3} m] $m [info exists ::tfv] [tf_ups_set tfv 4] $::tfv}
lappend calls {set ::tfv abc; list [catch {tf_ups_inc tfv 3} m] $m $::tfv}
lappend calls {set ::tfv 1.5; list [catch {tf_ups_incimm tfv 3} m] $m $::tfv}
lappend calls {set ::tfv 9223372036854775800; list [catch {tf_ups_inc tfv 100} m] $m $::tfv}
lappend calls {set ::tfv 9223372036854775800; list [catch {tf_ups_incimm tfv 100} m] $m $::tfv}
lappend calls {set ::tfv(1) 5; list [catch {tf_ups_inc tfv 3} m] $m [array get ::tfv]}
lappend calls {unset -nocomplain ::tfv; set ::tfv(1) 5; list [catch {tf_ups_inc tfv(1) 3} m] $m [array get ::tfv]}
lappend calls {list [catch {tf_ups_level 9 tfv 1} m] $m}
lappend calls {list [catch {tf_ups_level abc tfv 1} m] $m}
lappend calls {catch {unset {a(b}}; list [catch {tf_ups_level 1 {a(b} 1} m] $m}
lappend calls {catch {unset {}}; list [catch {tf_ups_level 1 {} 1} m] $m}
lappend calls {set ::tfv 3; list [catch {tf_ups_twice tfv tfv} m] $m $::tfv}
lappend calls {set ::tfv 3; set ::tfw 4; list [catch {tf_ups_twice tfv tfw} m] $m $::tfv $::tfw}
lappend calls {set ::tfv 3; set ::tfw 4; list [tf_two_up tfv tfw] $::tfv $::tfw}
lappend calls {set ::tfv 3; list [tf_two_up tfv tfv] $::tfv}
lappend calls {set ::tfv 2; list [tf_ups_rec tfv 5] $::tfv}
lappend calls {list [catch {tf_nsup_missing} m] $m}
lappend calls {list [catch {tfns::readw} m] $m [tfns::setw 5] [tfns::readw]}
proc tfx_r1 {x} { set rc [catch {tf_resume tfa $x} m]; list $rc $m [lsort [array get ::tfa]] }
proc tfx_r1b {x} { set ::tfa(n) 5; set rc [catch {tf_resume tfa $x} m]; list $rc $m [lsort [array get ::tfa]] }
proc tfx_r2 {x} { set ::tfc 1; set rc [catch {tf_resume2 tfc $x} m]; list $rc $m $::tfc }
proc tfx_r3 {x} { set ::tfc 1; set rc [catch {tf_resume3 tfc $x} m]; list $rc $m $::tfc }
set tfxs [list 0 1 abc {a b} {{}} 5 {{ab}} \{ {a \{b} {\{a} {a\\} \" {a b \{} 1.5 {} 0x10]
foreach x $tfxs {
    lappend calls "tfx_r1 [list $x]" "tfx_r1b [list $x]" "tfx_r2 [list $x]" "tfx_r3 [list $x]"
}
foreach x {-1 0 1 2 3 5 9} { lappend calls [list tf_cond_var $x] [list tf_cond_var2 $x] }
foreach x {abc {} 12 {a b}} { lappend calls [list tfx_eff $x] }
foreach n {0 1 5 40 300} { lappend calls [list tr_basic $n] [list tr_order $n] [list tr_order_get $n] [list tr_grow $n] [list tr_pair [expr {$n % 12}]] [list tr_caller $n] }
foreach k {1 2 x {} 07 -1} { lappend calls [list tr_missing_elem $k] [list tr_missing_array $k] [list tr_incr_new $k] [list tr_exists $k] [list tr_catch $k] }
foreach v {1 -3 abc {} 0x10 1.5 { 7 } 9223372036854775807 12345678901234567890} { lappend calls [list tr_incr_text $v] [list tr_shared $v] [list tr_deopt_late $v] [list tr_err_after $v] [list tr_double $v] }
foreach k {1 x} { foreach d {1 -5 0 abc 3.0 9223372036854775807} { lappend calls [list tr_incr_var $k $d] } }
foreach a {0 4294967296 -7} { foreach n {3 11 40} { lappend calls [list tr_exists_order $n $a] [list tr_exists_order2 $n $a] } }
lappend calls tr_incr_overflow tr_overwrite tr_keys tr_trace tr_unset tr_scalar_clash {tr_rec 6}
proc tfx_eff {s} { set ::tfx_g 0; set rc [catch {tfx_eff_caller $s} m]; list $rc $m $::tfx_g }
# traces on the variables typed code works on
lappend calls {set ::tflog {}; set ::tfv 1; trace add variable ::tfv write tf_tr; set r [tf_ups_incimm tfv 3]; trace remove variable ::tfv write tf_tr; list $r $::tflog}
lappend calls {set ::tflog {}; set ::tfv 1; trace add variable ::tfv read tf_tr; set r [tf_ups_incimm tfv 3]; trace remove variable ::tfv read tf_tr; list $r $::tflog}
lappend calls {set ::tflog {}; set ::tfv 1; trace add variable ::tfv unset tf_tr; set r [tf_ups_incimm tfv 3]; unset ::tfv; trace remove variable ::tfv unset tf_tr; list $r $::tflog}
lappend calls {set ::tflog {}; set ::tfv 1; trace add variable ::tfv write tf_tr_err; set rc [catch {tf_ups_incimm tfv 3} m]; trace remove variable ::tfv write tf_tr_err; list $rc $m $::tfv $::tflog}
lappend calls {set ::tflog {}; unset -nocomplain ::tfa; set ::tfa(0) 0; trace add variable ::tfa write tf_tr; set r [tf_ups_arr tfa 3]; trace remove variable ::tfa write tf_tr; list $r $::tflog}
lappend calls {set ::tflog {}; unset -nocomplain ::tfa; set ::tfa(0) 0; trace add variable ::tfa read tf_tr; set r [tf_ups_arr tfa 3]; trace remove variable ::tfa read tf_tr; list $r $::tflog}
lappend calls {set ::tflog {}; unset -nocomplain ::tfa; set ::tfa(1) 0; trace add variable ::tfa(1) write tf_tr; set r [tf_ups_arr tfa 3]; trace remove variable ::tfa(1) write tf_tr; list $r $::tflog}
lappend calls {set ::tflog {}; unset -nocomplain ::tfa; set ::tfa(1) 0; trace add variable ::tfa(1) read tf_tr; set r [tf_ups_arr tfa 3]; trace remove variable ::tfa(1) read tf_tr; list $r $::tflog}
lappend calls {set ::tflog {}; unset -nocomplain ::tfa; trace add variable ::tfa write tf_tr; set r [tf_ups_arr tfa 3]; trace remove variable ::tfa write tf_tr; list $r $::tflog}
lappend calls {set ::tflog {}; unset -nocomplain ::tfa; trace add variable ::tfa write tf_tr_err; set rc [catch {tf_ups_arr tfa 3} m]; trace remove variable ::tfa write tf_tr_err; list $rc $m [array exists ::tfa] $::tflog}
lappend calls {set ::tflog {}; unset -nocomplain ::tfg; trace add variable ::tfg write tf_tr; set r [tf_global_hist 4]; trace remove variable ::tfg write tf_tr; list $r $::tflog}
lappend calls {unset -nocomplain ::tfa; set ::tfa 5; list [catch {tf_ups_arr tfa 3} m] $m $::tfa}
lappend calls {unset -nocomplain ::tfa; array set ::tfa {0 a 1 b}; set s [array startsearch ::tfa]; set r [catch {tf_ups_arr tfa 3} m]; list $r $m [catch {array nextelement ::tfa $s} m2] $m2}
lappend calls {unset -nocomplain ::tfg; set ::tfg 5; list [catch {tf_global_hist 3} m] $m}
lappend calls {unset -nocomplain ::tfg; list [tf_global_hist 12] [tf_global_hist 12]}

set calls [concat [lrange $calls 0 [expr {$tfstart - 1}]] [lmap c [lrange $calls $tfstart end] {list tfx_call $c}]]

# calls from typed code
foreach n {0 1 2 5 100} {
    foreach p {tq_call_loop tq_call_defaults tq_call_defaults_i tq_call_dflt_str tq_call_dflt_odd tq_call_big tq_call_mixed tq_call_sum_mixed tq_call_missing tq_call_up tq_call_uplevel} { lappend calls [list $p $n] }
}
foreach n {0 1 4 5 9} { lappend calls [list tq_call_err $n] }
foreach n {0 3 50} { lappend calls "set ::tq_counter 0; tq_call_frame $n" "set ::tq_counter 0; catch {tq_call_err_frame $n} m; list \$m \$::tq_counter" }
# the callee redefined, renamed, deleted between and during calls
lappend calls {tq_call_loop 6} {proc tq_sq {x} { expr {$x + 1} }; tq_call_loop 6} {tq_call_loop 6} {proc tq_sq {x} { expr {$x * $x} }; tq_call_loop 6}
lappend calls {rename tq_sq tq_sq_gone; set r [catch {tq_call_loop 3} m]; rename tq_sq_gone tq_sq; list $r $m [tq_call_loop 4]}
lappend calls {rename tq_sq {}; set r [catch {tq_call_loop 3} m]; proc tq_sq {x} { expr {$x * $x} }; list $r $m [tq_call_loop 4]}
lappend calls {proc tq_add {a {b 10} {c 2.5}} { expr {$a * 100 + $b + $c} }; set r [tq_call_defaults 4]; proc tq_add {a {b 10} {c 2.5}} { expr {$a + $b + $c} }; list $r [tq_call_defaults 4]}
lappend calls {proc tq_add_i {a {b 99} {c -3}} { expr {$a + $b + $c} }; set r [tq_call_defaults_i 4]; proc tq_add_i {a {b 10} {c -3}} { expr {$a + $b + $c} }; list $r [tq_call_defaults_i 4]}
lappend calls {proc tq_arr {k} { return [expr {$k * 7}] }; set r [tq_call_frame 3]; proc tq_arr {k} { set t($k) $k; incr t($k) 5; return $t($k) }; list $r}

# math functions in typed code: every function on integers, doubles, numbers kept as text, bignums, values that make a domain or range error
set mvals {0 1 -1 2 3 7 -7 100 4611686018427387904 9223372036854775807 -9223372036854775808 9223372036854775808 0.5 -0.5 1.5 -1.5 2.5 -2.5 0.0 -0.0 1e300 -1e300 1e-300
    1e19 9.223372036854775807e18 -9.223372036854775808e18 1e400 -1e400 0x10 " 7" 1e3 007 abc {} 100000000000000000000 1.0 3.0 0.1 -0.0000001 709 710 -745 -746 36 -2147483648 2147483648}
foreach f {sin cos tan asin acos atan sinh cosh tanh exp log log10 sqrt floor ceil double int wide round abs bool entier isqrt} {
    foreach v $mvals { lappend calls [list tm_$f $v] }
}
foreach f {pow atan2 fmod hypot} {
    foreach a {0 1 -1 2 0.5 -0.5 -8 1e300 1e-300 9223372036854775807 0x10 abc 1.5 -0.0} { foreach b {0 1 -1 2 0.5 -0.5 0.3333333333333333 -2 1e300 -1e300 1e-300 3 abc 0x10 1.5 -0.0} { lappend calls [list tm2_$f $a $b] } }
}
# (arguments made by expr have no string form, so the procs are entered with a double: the typed variants for D)
set dvals {0.5 -0.5 1.5 -1.5 2.5 -2.5 0.0 -0.0 1e300 -1e300 1e-300 1e19 9.223372036854775807e18 -9.223372036854775808e18 0.1 -0.0000001 709.0 710.0 -745.0 -746.0 36.0 3.0 1e15 9007199254740993.0}
foreach f {sin cos tan asin acos atan sinh cosh tanh exp log log10 sqrt floor ceil double int wide round abs bool entier isqrt} {
    foreach v $dvals { lappend calls "tm_$f \[expr {double($v)}\]" }
}
foreach f {pow atan2 fmod hypot} {
    foreach a {0.5 -0.5 2.0 -8.0 1e300 0.0} { foreach b {0.5 -0.5 2.0 0.3333333333333333 -1e300 0.0 3.0} { lappend calls "tm2_$f \[expr {double($a)}\] \[expr {double($b)}\]" "tm2_$f $a \[expr {double($b)}\]" } }
}
foreach v $mvals { lappend calls [list tm_mix $v] [list tm_not_math $v] }
foreach n {0 1 2 10 100 1000} { lappend calls [list tm_loop $n] [list tm_loop_d 0.5 $n] [list tm_loop_d -3 $n] [list tm_int_loop $n] }
lappend calls {tm_loop_d abc 5} {tm_loop_d 1e300 50}
# the math functions redefined: typed code stops computing them itself (this block comes last: the flag is not set again)
lappend calls {tm_sqrt 16} {rename ::tcl::mathfunc::sqrt ::tcl::mathfunc::sqrt_orig; proc ::tcl::mathfunc::sqrt {x} {return [expr {$x + 100}]}; list [tm_sqrt 16] [tm_loop 5] [tm_mix 3]}
lappend calls {rename ::tcl::mathfunc::sqrt {}; rename ::tcl::mathfunc::sqrt_orig ::tcl::mathfunc::sqrt; list [tm_sqrt 16] [tm_loop 5] [tm_mix 3]}
lappend calls {namespace eval ::mfns {proc tcl::mathfunc::floor {x} {return -1}}; set r [list [tm_floor 2.5] [tm_loop 4]]; namespace delete ::mfns; set r}

# foreach in typed code
set flists [list {} {1} {1 2 3} {1 2 3 4 5 6 7 8} {1 2 x} {6 1 7} {1 {2 3} 4} " 5 6" 0x10 {3} {1 2 3 4 3 5} \{ {a b} {-1 0 1 2} {1.5 2.5} {9223372036854775807 1}]
foreach l $flists {
    foreach p {tfe_sum tfe_pairs tfe_break tfe_continue tfe_after tfe_float tfe_arr tfe_err tfe_return tfe_notlist tfe_str} { lappend calls [list $p $l] }
    lappend calls "catch {unset ::tfe_last}; [list tfe_global $l]"
    lappend calls [list tfe_two $l {10 20}] [list tfe_two {1 2 3} $l] [list tfe_three $l {a b c}] [list tfe_three {x y z w} $l] [list tfe_up tfv $l]
}
foreach n {0 1 3 20} { lappend calls [list tfe_nested $n] [list tfe_modify $n] [list tfe_shared $n] [list tfe_calls $n] [list tfe_big $n] }

# catch in typed code
foreach n {0 1 2 3 4 5 6 10} {
    foreach p {tcc_basic tcc_vars tcc_nested tcc_codes tcc_loop tcc_overflow tcc_opts tcc_callee tcc_undef tcc_after tcc_arr tcc_strict} { lappend calls [list $p $n] }
}
lappend calls {tcc_loop 1.5} {tcc_vars x}

# switch in typed code
foreach n {0 1 2 3 6 7 11} { lappend calls [list tsw_int $n] [list tsw_mod $n] [list tsw_nested $n] }
foreach l [list {} a {a b c} {a {a b} {} d b} {c c c} {x}] { lappend calls [list tsw_str $l] }
foreach x {1 01 1.0 abc 2 0x1 -1 {} " 1" 1e0 +1} { lappend calls [list tsw_val $x] [list tsw_nodefault $x] [list tsw_dbl $x] [list tsw_err $x] }

# small instructions in typed code
foreach l [list {} 5 {1 2 3} {9223372036854775806 1 2} {9223372036854775807 1} {a 1} {0x10 1 -3} {1.5 2} " 7 8" {1 {2 3}} \{] {
    foreach p {tbx_incr_b tbx_incr_by tbx_incr_shared tbx_map} { lappend calls [list $p $l] }
    lappend calls [list tbx_llen $l 4] [list tbx_concat $l {x y}] [list tbx_concat {p q} $l]
}
foreach n {0 1 5} { lappend calls [list tbx_concat_loop $n] }

# TBC_SMALL=1: leave out the calls that loop long (for runs under valgrind)
if {[info exists ::env(TBC_SMALL)]} { set calls [lmap c $calls { if {[regexp {(^|[ \{])(1000|3000|6000|10000|30000|100000|1000000|900|1500)($|[ \}])} $c]} { continue }; set c }] }
proc runall {} {
    global calls
    set out {}
    foreach c $calls {
        if {[info exists ::env(TBC_TRACE)]} { puts stderr "CALL $c" }
        # a fresh copy: a script run twice from the same object would be compiled once, and compiling resets the interpreter's errorLine
        set rc [catch [string reverse [string reverse $c]] r opts]
        if {[info exists ::env(TBC_ELTRACE)]} { puts stderr "EL $::phase [errline] $c" }
        set ei {}
        if {[info exists ::env(TBC_ERRINFO)] && $rc == 1} { foreach k {-errorinfo -errorline} { if {[dict exists $opts $k]} { lappend ei [dict get $opts $k] } } }
        lappend out [list $c $rc $r [expr {$rc == 1 && [dict exists $opts -errorcode] ? [dict get $opts -errorcode] : "-"}] {*}$ei]
    }
    return $out
}
proc covreport {} {
if {[llength [info commands tbc_coverage]]} {
        array set cov [tbc_coverage]
        set ent [lsort [lmap {k v} [array get cov] {expr {[string match V:* $k] ? "$k=$v" : [continue]}}]]
        set deopt 0; set dpts 0; set cstub 0
        foreach {k v} [array get cov] { if {[string match D:* $k]} { incr dpts; incr deopt $v } elseif {[string match C:* $k]} { incr cstub $v } }
        puts "coverage: [llength $ent] variants entered; $dpts distinct deopt points taken ($deopt deopts in total); $cstub post-call stubs taken"
        if {[info exists ::env(TBC_COV_DETAIL)]} { puts [join $ent \n]; foreach k [lsort [array names cov]] { if {![string match V:* $k]} { puts "$k=$cov($k)" } } }
    }
}
set A [runall]
set ::phase B
load {} Testprocs
# hook mode: the program defines its procs again, after the compiled module is registered; they pick up their compiled bodies
source [file join [file dirname [info script]] procs.tcl]
puts "attached: [llength [tbc::attached]] of [llength [info commands t_*]]"
set B [runall]
puts "attached after the calls: [llength [tbc::attached]]"
# procs that must run compiled (a refused proc would run interpreted and match trivially): the constructs that were once refused
set mustAttach {::tl_lmap1 ::tl_lmap2 ::tl_lmap3 ::tl_lmap4 ::tl_lmap5 ::tl_lmap6 ::tl_lmap7 ::tl_arrset_in_loop ::tl_arrset_odd ::tl_dictfor_in_loop
    ::tl_dictfor_break ::tl_dictfor_ret ::tl_dictfor_err ::tl_dictfor_catch {::tw_odd?} {::tw_star*} {::tw_br[a]} {::tw with space} {::tw"quote} {::tw\back} {::tw;semi} ::tw_caller ::tb_try1 ::tb_try2 ::tb_try3 ::tb_catch1 ::tb_try4 ::tb_try5}
foreach p $mustAttach { if {$p ni [tbc::attached]} { puts "NOT COMPILED: $p"; incr ::notCompiled } }
if {[info exists ::notCompiled]} { puts "$::notCompiled procs that must run compiled do not" ; exit 1 }
set bad 0
foreach a $A b $B {
    if {$a ne $b} {
        incr bad
        if {$bad <= 25} { puts "MISMATCH\n  interpreted: $a\n  translated:  $b" }
    }
}
puts "[llength $A] calls compared, $bad mismatches"
if {[info exists ::env(TBC_NOLEAK)]} { covreport }
if {[info exists ::env(TBC_NOLEAK)]} { exit [expr {$bad ? 1 : 0}] }

# leak check over the whole call list: repeat the translated run (without the redefinition scripts at its end); a missing release in any
# deoptimisation, error or call path would make the live-allocation count grow by a fixed amount per round
proc live {} { if {[llength [info commands memory]]} { regexp {current packets allocated\s+(\d+)} [memory info] -> n; return $n } else { return - } }
set calls [lrange $calls 0 end-6]
runall; set l1 [live]; runall; set l2 [live]; runall; set l3 [live]; runall; set l4 [live]
puts "live allocations after repeated full runs: $l1 $l2 $l3 $l4"

# reference-count stress: a leak of one object per iteration would show as memory growth
proc rss {} { set f [open /proc/self/status]; set t [read $f]; close $f; regexp {VmRSS:\s+(\d+)} $t -> kb; return $kb }
set iters [expr {[info exists ::env(TBC_LEAK_ITERS)] ? $::env(TBC_LEAK_ITERS) : 3000000}]
t_leak_loop 1000
set r0 [rss]; set a0 [live]
t_leak_loop $iters
set r1 [rss]; set a1 [live]
puts "t_leak_loop $iters iterations: RSS grew [expr {$r1 - $r0}] KB; live allocations before/after: $a0 / $a1"
# the same for the frame-based generator: one leaked object per iteration is 48 bytes, so 300000 iterations grow the process by more than 14 MB
set giters 300000
t_leak_g 12345 1000
set r0 [rss]
t_leak_g 12345 $giters
set r1 [rss]
set gl [expr {$r1 - $r0}]
puts "t_leak_g $giters iterations: RSS grew $gl KB"
if {$gl > 2048} { puts "LEAK in the frame-based generator: RSS grew $gl KB"; incr bad }
# and for typed code on variables in the frame (arrays, links)
tf_leak_frame 100; tf_leak_up2 100
set r0 [rss]
for {set k 0} {$k < 3000} {incr k} { tf_leak_frame 100 }
tf_leak_up2 200000
set r1 [rss]
set fl [expr {$r1 - $r0}]
puts "tf_leak_frame/tf_leak_up: RSS grew $fl KB"
if {$fl > 2048} { puts "LEAK in typed code on frame variables: RSS grew $fl KB"; incr bad }
covreport
exit [expr {$bad ? 1 : 0}]
