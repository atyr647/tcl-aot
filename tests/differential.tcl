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
# array elements with keys built from integers and literals
foreach n {0 1 3 6} { foreach p {mk_load mk_incr mk_exist mk_neg mk_three mk_lit mk_deopt mk_error} { lappend calls [list $p $n] } }
foreach {n s} {0 x 3 abc 3 {} 2 a,b 2 9223372036854775807} { lappend calls [list mk_text $n $s] }
foreach n {1.5 -1} { foreach p {mk_load mk_incr mk_exist mk_three mk_lit mk_deopt} { lappend calls [list $p $n] } }
# state reached through names in variables, and numbers read from arrays and lists
foreach {a b} {5 9 0 0 -7 3 1.5 2 abc 1 {} 4 99999999999999999999 1 0x10 010 9223372036854775807 1} {
    lappend calls "array set ::dnx {A $a B $b}; dn_up ::dnx 20" "array set ::dnx {A $a B $b}; dn_up ::dnx 0" "namespace eval dnns {array set t1 {A $a B $b}}; dnns::f t1 10" "dn_list {$a $b} 15"
}
lappend calls {dn_up nosuchvar 3} {dnns::f nosuchvar 3} {dn_list {} 3} {dn_list {1} 3}
# built-ins called through their C procedures: the cases the gate leaves to the interpreter's dispatch
foreach a {{a b c} {} x {{a b} c}} { lappend calls [list pj_join $a] }
foreach a {hello {} o foo\ bar é€o} { lappend calls [list pj_str $a] }
foreach n {0 1 5} { lappend calls [list pj_fmt $n] }
lappend calls {set ::trj {}; trace add execution join enter {lappend ::trj}; set r [pj_join {a b}]; trace remove execution join enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set ::trj {}; trace add execution ::tcl::string::first enter {lappend ::trj}; set r [pj_str hello]; trace remove execution ::tcl::string::first enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set r [pj_join {a b}]; interp limit {} command -value 100000000; set r2 [pj_join {a b}]; interp limit {} command -value {}; list $r $r2}
lappend calls {rename join join_x; proc join {args} {return JOINED}; set r [pj_join {a b}]; rename join {}; rename join_x join; list $r [pj_join {a b}]}
lappend calls {rename ::tcl::string::first ::tcl::string::first_x; proc ::tcl::string::first {args} {return 7}; set r [pj_str hello]; rename ::tcl::string::first {}; rename ::tcl::string::first_x ::tcl::string::first; list $r [pj_str hello]}
lappend calls {pj_join {a b}} {pj_str hello}
# binary format as a built-in the compiled code treats as pure: results, errors, execution traces, replacements
foreach n {0 1 7 300} { lappend calls [list pb_loop $n] [list pb_chain $n] }
foreach a {0 1 -1 127 128 255 256 65535 65536 4294967295 4294967296 9223372036854775807 -9223372036854775808 0x10 " 5" 1.5 abc {} 1e3 100000000000000000000} {
    foreach f {c cu S s I i W w a3 A3 a* b4 B4 h2 H2 x f d} { lappend calls [list pb_catch $f $a] }
}
foreach a {0 1 {1 2} {1 2 3} {} abc} { foreach f {c* S* cu* a2 c2 c3 @2} { lappend calls [list pb_catch $f $a] } }
foreach f {c S Z @ a1x} { lappend calls [list pb_err $f] }
foreach f {SI cS Ia4 a4I} { lappend calls [list pb_two $f 1 2] [list pb_two $f abc def] }
lappend calls {pb_lit} {pb_all} {pb_scan 5} {pb_scan 70000} {pb_pack 1} {pb_pack 1 2 3}
lappend calls {set ::trj {}; trace add execution ::tcl::binary::format enter {lappend ::trj}; set r [pb_loop 3]; trace remove execution ::tcl::binary::format enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set ::trj {}; trace add execution binary enter {lappend ::trj}; set r [pb_loop 3]; trace remove execution binary enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set ::trj {}; trace add execution ::tcl::binary::format leave {lappend ::trj}; set r [pb_chain 2]; trace remove execution ::tcl::binary::format leave {lappend ::trj}; list $r [llength $::trj]}
lappend calls {rename ::tcl::binary::format ::tcl::binary::format_x; proc ::tcl::binary::format {args} {uplevel 1 {set x 99}; return FORMATTED}; set r [list [pb_pack 1 2] [pb_loop 2]]; rename ::tcl::binary::format {}; rename ::tcl::binary::format_x ::tcl::binary::format; list $r [pb_pack 1 2]}
lappend calls {rename binary binary_x; proc binary {args} {return BIN}; set r [list [pb_pack 1 2] [pb_loop 2]]; rename binary {}; rename binary_x binary; list $r [pb_pack 1 2]}
lappend calls {rename ::tcl::binary::format ::tcl::binary::format_x; interp alias {} ::tcl::binary::format {} list; set r [list [pb_pack 1 2] [pb_loop 2]]; interp alias {} ::tcl::binary::format {}; rename ::tcl::binary::format_x ::tcl::binary::format; list $r [pb_pack 1 2]}
lappend calls {pb_loop 3} {pb_pack 4 5}
# execution traces on an ensemble (string, dict) and on its subcommand, with the call made from compiled code through a compiled callee
foreach {cmd call} {string {pe_mapn 3} ::tcl::string::map {pe_mapn 3} dict {pe_dsizen 3} ::tcl::dict::size {pe_dsizen 3} string {pe_firstn 3} ::tcl::string::first {pe_firstn 3}} {
    lappend calls "set ::trj {}; trace add execution $cmd enter {lappend ::trj}; set r \[$call\]; trace remove execution $cmd enter {lappend ::trj}; list \$r \[llength \$::trj\]"
}
lappend calls {pe_mapn 3} {pe_dsizen 3} {pe_firstn 3}
# the first call of a proc attached lazily leaves the arguments as they were (no string form made for a byte array)
lappend calls {tzb_lazy}
# regexp and regsub with result variables
foreach x {{} abc k=v key=val=ue "=" x12y34 xy b1b2 a1B3 {a-b 12 c9} 123 "line\nx=1" AAA} { lappend calls [list rv_basic $x] [list rv_nomatch $x] [list rv_loop $x] [list rv_opts $x] [list rv_arg $x pre] [list rv_subst $x] [list rv_subst1 $x] [list rv_subst2 $x] [list rv_traced $x] [list rv_linked $x] [list rv_elem $x] [list rv_use $x] [list rv_use $x,5,7] }
foreach p {{(} {*} {a} {(b)} {^$} {[a-} {a{2,1}}} { lappend calls [list rv_bad $p] [list rv_dyn $p abcb] [list rv_dyn $p {}] }
lappend calls {rv_wrong} {rv_dyn -nocase ABC} {rv_dyn -- --}
# channel commands
foreach d [list {} "a" "a\n" "a\nb" "a\nb\n" "\n\n" "x\r\ny\r\n" [string repeat z 5000] "[string repeat q 3000]\nshort\n" "caf\u00e9\n"] { lappend calls [list io_lines $d] [list io_gets1 $d] [list io_pos $d] [list io_unset $d] }
foreach w {0 1 2 3 4 5} { lappend calls [list io_bad $w] }
foreach n {0 1 7 200} { lappend calls [list io_loop $n] }
# typed code entered again at a later loop after several hand-overs
foreach n {0 1 5 40} { lappend calls [list ob_chain $n] [list ob_late $n] [list ob_inner $n] }
foreach a {{} {-m 5} {-w 7 -m 8} {-x 1}} { lappend calls [list ob_two {*}$a] }
lappend calls {ob_err} {ob_err 1 2 3 4 5} {ob_err 1 2}
# string commands on strings that were appended to
foreach n {0 1 5 40} { lappend calls [list sx_idx $n] [list sx_range $n] }
foreach s {{} a abc "\u00e9t\u00e9" "\u20ac\u20ac" "\U0001F600x" "a b"} { lappend calls [list sx_scan $s] }
lappend calls {sx_uni} {sx_neg}
lappend calls {se_forms}
foreach s {{} e abcdeabcde "\u00e9e\u00e9" "\u20ace" "e\U0001F600"} { lappend calls [list se_chars $s [string length $s]] [list se_chars $s [expr {[string length $s] + 2}]] }
# string builder (kind Z)
foreach n {0 1 5 40 1000} { lappend calls [list zb_basic $n] [list zb_uni $n] [list zb_reset $n] [list zb_loopwhole $n] [list zb_idxcalc $n] }
lappend calls {zb_kinds} {zb_nul} {zb_begin} {zb_snap} {zb_big} {zb_empty} {zb_trace} {zb_unset} {zb_upv} {zb_err}
foreach s {{} a abc "\u00e9t" "x\u20ac"} { foreach i {0 1 2 -1 99 end end-1} { lappend calls [list zb_index $s $i] } }
foreach i {0 4 5 -1 end end-1 end-9 foo 1.5 {} 99999999999 -99999999999} { lappend calls [list zb_idxerr $i] }
foreach x {0 1 2.5 -3 1e3 abc "\u00e9" 12345678901234567890} { lappend calls [list zb_double $x] }
lappend calls {zb_cond 0} {zb_cond 1}
# commands replaced while a proc runs; reflected channels, traces and uplevel looking at the variables of the proc
foreach n {0 1 2 3 5} { lappend calls [list cr_string $n] [list cr_join $n] [list cr_first $n] [list cr_typed $n] }
foreach m {none eof} { lappend calls [list cr_reflect $m] }
lappend calls {cr_ydrun} {cr_shadow} {cr_refl_vars} {cr_vtrace} {cr_ctrace} {cr_modify}
foreach n {9223372036854775807 -9223372036854775807 -9223372036854775808 255 256 -256 -257 1023 1024 0 -1} { lappend calls [list sm_edge $n] }
foreach n {0 100 9223372036854774783 -9223372036854775000} { lappend calls [list sm_list $n] }
# string length of integers
foreach n {0 1 9 10 11 99 100 101 999 1000 9999 10000 99999 100000 999999999 1000000000 -1 -9 -10 -99 -100 9223372036854775807 -9223372036854775807 -9223372036854775808 9223372036854775808 -9223372036854775809 0x1F 0x7fffffffffffffff 010 007 +5 " 5" 5.0 -0 1e3 1.5 abc {} 12345678901234567890} { lappend calls [list sl_arg $n] [list sl_loop $n] }
foreach n {0 5 9 99 999999999 -1 -10 4611686018427387904 9223372036854775806 -9223372036854775807 } { lappend calls [list sl_calc $n] }
foreach n {0 1 5 8 12 105} { lappend calls [list sl_count $n] }
# list literals made by the compiler
foreach x [list {} a {a b c} {1 2 3 4 5 6 7 8 9 10} "x\ty" {\{} {a {b c} d} " lead" "trail "] { lappend calls [list ll_eval $x] [list ll_evalq $x] [list ll_cat $x] [list ll_cat2 $x] [list ll_eval2 $x] [list ll_commentlist $x] [list ll_evalbad $x] }
lappend calls {ll_eval3} {ll_listlit} {ll_eval2} {ll_eval2 1 2 3}
# rand and srand
foreach seed {0 1 7 42 -5 2147483647 1.5 abc} { lappend calls [list rn_seq $seed 6] [list rn_dbl $seed] [list rn_sum $seed 50 97] [list rn_badseed $seed] }
lappend calls {rn_args} {rn_seq 3 0}
lappend calls {rename ::tcl::mathfunc::rand ::tcl::mathfunc::rand_x; proc ::tcl::mathfunc::rand {} {return 0.5}; set r [list [rn_dbl 1]]; rename ::tcl::mathfunc::rand {}; rename ::tcl::mathfunc::rand_x ::tcl::mathfunc::rand; list $r [rn_dbl 1]}
# scan %c inline
foreach s [list {} a abc " x" "\u00e9" "\u20ac" "\U0001F600" "\U0001F600z" [format %c 0] "\t" 0 -1 [binary format c3 {200 1 2}]] { lappend calls [list sc_one $s] [list sc_unset $s] [list sc_sum $s] [list sc_loop $s] }
# dict locals held as native maps: key spellings, order, escapes, overflow
foreach n {0 1 2 7 11 12 100 3000} { lappend calls [list dt_count $n] [list dt_order $n] [list dt_forbody $n] [list dt_escape_loop [expr {$n % 50}]] [list dt_neg $n] [list dt_twice [expr {$n % 40 + 1}]] [list dt_reset $n] [list dt_neg_keys $n] [list dt_big $n] }
lappend calls {dt_keys} {dt_ovf} {dt_empty}
foreach k {5 05 -0 +5 " 5" 5.0 abc {} 9223372036854775807 -9223372036854775808 9223372036854775808 1e3 0x5 -5 007} { lappend calls [list dt_keyarg $k] [list dt_ovf2 $k] }
foreach {n k} {8 0 8 1 8 3 8 4 8 7 8 -1 0 0 1 1} { lappend calls [list dt_get $n $k] }
foreach n {0 1 8} { lappend calls [list dt_getmiss $n] }
lappend calls {interp limit {} command -value 100000000; set r [pb_loop 3]; interp limit {} command -value {}; set r}
# string first / last / index / range
set sfs [list hello {} o ll "hello world" "\u00e9\u20acx" [format a%cb 0] [binary format c3 {65 66 67}] 12345 0x1F " 5" {a b c} xxxxxxxxxxxx 1.5 "tab\there" "\u00e9" "x\u00e9y"]
set sfi {0 1 2 5 -1 -9 end end-1 end+1 abc 1.5 2147483647 2147483648 9223372036854775807 -2147483649 " 1" 0x1 1+1 {}}
foreach h $sfs { foreach n $sfs { lappend calls [list sf_first $n $h] [list sf_last $n $h] } }
foreach h $sfs { foreach i $sfi { lappend calls [list sf_index $h $i] } }
foreach h {hello {} "\u00e9\u20acx" 12345} { foreach a {0 1 -1 end 2 abc 99 2147483648} { foreach b {0 2 end 99 -1 abc end-1 9223372036854775807} { lappend calls [list sf_range $h $a $b] } } }
foreach h $sfs { lappend calls [list sf_lit $h] [list sf_loop $h] }
# == and != against the empty string
foreach x {{} 0 1 -1 abc 1.5 0x10 " " "\u00e9" {a b} {{}} 9223372036854775807 NaN Inf} { lappend calls [list em_eq $x] }
foreach l {{} {a {} b} {1 2 {}} {{} {} {}} {0 0.0 abc}} { lappend calls [list em_loop $l] }
foreach n {0 1 5} { lappend calls [list em_num $n] }
foreach x {0 1 2.5 -3} { lappend calls [list em_dbl $x] }
lappend calls {em_eq} {em_eq 1 2}
# string match
set smv [list hello {} Hello "a*b" abc "\u00e9a" [binary format c3 {97 98 99}] 12345 {a b} *a* "\u00e9\u20ac"]
foreach p {* a* ?e* {[a-c]*} {a\*b} {} HELLO *\u00e9* {[]} {\\}} { foreach s $smv { lappend calls [list sm_match $p $s] } }
foreach l {{} {a b} {abc bca {} Apple} {a A aa AA}} { lappend calls [list sm_loop $l] }
foreach s $smv { lappend calls [list sm_loop [list $s $s]] }
# regexp as an instruction
foreach p {a b+ {^a} {[0-9]} {(} {a{2}} {\d} {*a} {} {.} {\u00e9}} { foreach s {abc {} 12345 ABC "\u00e9a" {a b} aabbcc 1.5} { lappend calls [list rx_test $p $s] } }
foreach l {{} {a b} {abc Bcd {} bbb} {a A b B}} { lappend calls [list rx_loop $l] }
# the native matcher (include/tbc_re.h): every form of the command, patterns in its subset and outside it, subjects of ASCII and other characters
set rn_pats {{a+} {[ab]+} {^a} {b$} {\Aab} {a|b} {(?:ab)+c?} {\d+} {\s*} {\w+} {[[:alpha:]]+} {[^\n]*} {.} {x*} {a{2}} {[a-c]{1,3}} {(a)(b)} {(} {a*?} {\y} {é} {é} {(?i)a} {[[:digit:]]+} {\D+} {\S+} {\W} {^\s*$} {[\d.]+} {a|} {(?:a|b)*$}}
set rn_subs [list {} a ab aab abab "aabbcc 12" "ab\nab" "éaé" "x٠١y" "a b c" "ЖΩz 9" 12345 "  a  b " "\U0001F600a" "AbC dE"]
foreach p $rn_pats { foreach s $rn_subs { lappend calls [list rn_forms $p $s] [list rn_vars $p $s] [list rn_dyn $p $s] } }
foreach s $rn_subs { lappend calls [list rn_class $s] [list rn_all $s] [list rn_ns $s] }
foreach t {{} {x = 1;} {if (a < 10) { b = "q\"x"; }} "a\tb\nc d" {  } "é = 3" {foo(1.5, bar)}} { lappend calls [list rn_tokens $t] [list rn_split $t] }
# replaced, traced, limited: the call must go the way of any other command
foreach w {enter leave enterstep leavestep} { lappend calls "set ::trj {}; trace add execution regexp $w {lappend ::trj}; set r \[rn_forms {a+} abab\]; trace remove execution regexp $w {lappend ::trj}; list \$r \[llength \$::trj\]" }
lappend calls {set ::trj {}; trace add execution ::regexp enter {lappend ::trj}; set r [rn_tokens {a = 1;}]; trace remove execution ::regexp enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {rename regexp rn_orig; proc regexp {args} { uplevel 1 {set m REPL}; return REPL }; set a [list [rn_forms a abc] [rn_vars a abc] [rn_ns abb]]; rename regexp {}; rename rn_orig regexp; set a}
lappend calls {rn_forms a+ aab} {rn_vars a+ aab}
lappend calls {namespace eval rnns { proc regexp {args} { return NSHADOW } }; set a [list [rn_ns abb] [rn_forms b abb]]; namespace eval rnns { rename regexp {} }; set b [rn_ns abb]; list $a $b}
lappend calls {rn_ns abb}
lappend calls {rename regexp rn_orig2; interp alias {} regexp {} rn_orig2 -all; set a [list [rn_forms a+ aab]]; interp alias {} regexp {}; rename rn_orig2 regexp; set a}
lappend calls {rn_forms a+ aab}
lappend calls {interp limit {} command -value 100000000; set r [list [rn_forms {a+} aab] [rn_all abab]]; interp limit {} command -value {}; set r}
lappend calls {set ::rn_t {}; trace add variable ::rn_v write {lappend ::rn_t}; rn_tv; trace remove variable ::rn_v write {lappend ::rn_t}; list $::rn_v $::rn_t} {rn_ro}
# numbers that are integers or doubles at run time
set wfl [list {} {1 2 3} {1.5 2.5} {1 2.5 3} {0.1 0.2 0.3} {7.90 8} {0x10 1.5} {1e3 2} abc {1 abc 2} {9223372036854775807 1} {9223372036854775807 1.0} {-5 5} {inf 1} {nan 1} {" 5" 2} {100000000000000000000 1} {0 0.0} {5} {5.0} {-0.0 1}]
foreach l $wfl { lappend calls [list wf_sum $l] [list wf_mean $l] [list wf_pass $l] [list wf_cond $l] [list wf_neg $l] }
set wfv {0 1 -1 3 7 2.5 -2.5 0.0 1e300 abc {} 0x10 " 5" 9223372036854775807 -9223372036854775808 100000000000000000000 inf nan}
foreach a $wfv { foreach b {0 1 -2 2.5 0.0 abc 9223372036854775807} { lappend calls [list wf_cmp $a $b] [list wf_mod $a $b] } }
foreach n {0 1 3 10 100 1000} { lappend calls [list wf_loop $n] [list wf_incr $n] [list wf_store $n] }
foreach x {0 1 -1 2.5 -2.5 abc {} 9223372036854775807} { lappend calls [list wf_ret $x] [list wf_keep $x] }
foreach l $wfl { lappend calls [list wm_funcs $l] [list wm_acc $l] }
# arithmetic on objects that turn out to be doubles, in procs without a sign of floating-point numbers: integers first, then doubles, then integers again
set wal [list {1 2 3} {} {1.5 2.5} {1 2 3 4.5} {0.1 0.2 0.3} {7 8} {0x10 3} {1e3 2} {1 abc 2} {9223372036854775807 1} {9223372036854775807 1.0} {-5 5} {" 5" 2.0} {100000000000000000000 1} {1 2 3}]
foreach l $wal { lappend calls [list wa_sum $l] [list wa_mean $l] [list wa_max $l] [list wa_twice $l] [list wa_scale $l 2] [list wa_scale $l 0.5] [list wa_dot $l $l] }
foreach x {0 1 2 -3 0.5 2.5 abc 1e10 9223372036854775807} { lappend calls [list wa_poly $x] }
lappend calls {list [wa_sum {1 2 3}] [wa_sum {1.5 2}] [wa_sum {4 5}] [wa_sum {0.25 0.25}] [wa_sum {7}]}
# dense native arrays
foreach n {0 1 2 3 5 63 64 65 200 1000} { foreach base {0 1 5} { lappend calls [list da_asc $n $base] } }
foreach n {10 100 3000} { lappend calls [list da_fill $n] }
foreach n {0 1 2 7 100} { lappend calls [list da_gap $n] [list da_desc $n] [list da_strlate $n] [list da_edge $n] [list da_missing $n] [list da_incr $n] [list da_incr2 $n] [list da_base1 $n] [list da_dbl $n] [list da_twoexists $n] [list da_twomissing $n] }
lappend calls {da_str} {da_neg} {da_big} {da_missing0} {da_incrstr} {da_overflow} {da_mixed} {da_twomix} {da_twokeys} {da_twodim}
foreach n {0 1 3 70} { foreach k {0 1 2 x 01 -1 69 70 {}} { lappend calls [list da_exists $n $k] } }
foreach n {0 1 2 4 9 70} { foreach m {0 1 2 3 8 70} { lappend calls [list da_two $n $m] [list da_two1 $n $m] [list da_col $n $m] } }
foreach n {0 1 2 3 6 40} { lappend calls [list da_ragged $n] [list da_twogap $n] [list da_twoincr $n] [list da_twostr $n] [list da_matmul $n] }
foreach {x y} {abcbdab bdcaba {} abc abc {} aaaa aa xyz xyz} { lappend calls [list da_lcs $x $y] }
foreach n {0 1 2 3 7 100 1000} { lappend calls [list da_dbl $n] [list da_dmix $n] }
lappend calls {da_dinf} {da_dlit} {da_dover} {da_dstr} {da_dincr}
foreach n {0 1 2 5 9} { foreach m {0 1 3 8} { lappend calls [list da_dtwo $n $m] } }
foreach n {0 1 2 5 12 40} { lappend calls [list da_dmul $n] }
foreach n {0 1 5 300} { lappend calls [list da_dnbody $n] }
foreach n {0 1 2 3 8 30} { lappend calls [list da_kbranch $n] [list da_kboth $n] [list da_kif $n] [list da_kloop $n] [list da_kcall $n] [list da_kerr $n] }
foreach n {0 1 2 5 9 30 200} { lappend calls [list da_ord_asc $n] [list da_ord_desc $n] [list da_ord_perm $n] [list da_ord_late $n] [list da_ord_get $n] [list da_unord $n] [list da_hole $n] [list da_holeinc $n] [list da_unordmix $n] [list da_unorddbl $n] }
foreach n {0 1 5 60 300} { foreach m {1 7 50 1000} { lappend calls [list da_ord_hist $n $m] } }
foreach n {0 1 2 4 7} { foreach m {0 1 3 5} { lappend calls [list da_ord_two $n $m] [list da_ord_col $n $m] } }
lappend calls {da_ord_sparse}
# lists as native vectors
foreach n {0 1 2 3 5 17 100 1000} { lappend calls [list ls_sum $n] [list ls_for $n] [list ls_ret $n] [list ls_break $n] [list ls_mod $n] [list ls_nest [expr {min($n, 30)}]] [list ls_after $n] [list ls_idx $n] [list ls_lset $n] [list ls_lseterr $n] [list ls_reset [expr {min($n, 40)}]] [list ls_mixed $n] [list ls_pass $n] [list ls_res $n] [list ls_two $n] [list ls_copy $n] [list ls_var $n] }
lappend calls {ls_big} {ls_empty} {ls_hexlit}
# comparisons of objects that are not integers
set cmv {0 1 -1 2.5 1.0 1e3 0x10 010 " 5" abc plain left m {} {a b} {1 2} {{a b} c} 100000000000000000000 NaN Inf -0.0 1e400 true {a\ b} "\u00e9" "\u00e9a"}
foreach x $cmv { lappend calls [list cm_lit $x] [list cm_order $x] [list cm_cnt [list 1 a 1.0 $x abc {} $x] $x] [list cm_neq [list 1 a 1.0 $x abc {} $x] $x] [list cm_min [list $x 3 abc 2.5 $x]] }
# (cm_eqrec is the recursion of struct::list's equality: with NaN, which is not equal to itself, it never ends, in the interpreter as well)
foreach x $cmv { foreach y {0 1 2.5 abc {} 100000000000000000000 0x10} { lappend calls [list cm_pair $x $y] [list cm_mixed $x $y]; if {$x ne "NaN"} { lappend calls [list cm_eqrec $x $y] [list cm_eqrec [list $x $y] [list $x $y]] [list cm_eqrec [list $x $y] [list $y $x]] } } }
lappend calls {list [cm_cnt {1 2 3} 2] [cm_cnt {a b a} a] [cm_cnt {1.0 1 01} 1] [cm_neq {a b a} a] [cm_lit plain] [cm_lit left] [cm_lit x]}
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
foreach n {0 1 2 3 10 50 300} { lappend calls [list t_vec_ifstmt $n] [list t_vec_ifstmt2 $n] }
foreach n {0 2 3 4 9} { foreach x {7 abc 2.5 {} 9223372036854775807} { lappend calls [list t_vec_ifstmt3 $n $x] } }
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

# Phase A, blocker 4: expansions nested in an expansion, inside loops (sd_*): with and without a break, continue, error or return from the inner command
foreach l {{} {{a}} {{a b} {c} {d e f}} {{a} {x} {b}} {{a} {c} {b}} {{a} {e} {b}} {{a} {r} {b}} {{x}} {{c}} {{1 2} {x} {3}} {{a b c}}} {
    foreach p {sd_cat sd_append sd_nest sd_break sd_while_break sd_for_break sd_catch sd_global} { lappend calls [list $p $l] }
}
lappend calls {sd_for {a b c}} {sd_while {a b c}} {sd_for {}} {sd_while {x}}
foreach l {{} {{{a b} {c}} {{d}}} {{{a} {x} {b}} {{c}}} {{{a} {c} {b}} {{d}}} {{{a} {e}} {{d}}}} { lappend calls [list sd_two_loops $l] }

# Phase A, blocker 2: max and min (mm_*): integers, doubles, mixed, objects of every form, ties, the 2^53 boundary, text and bignums (errors), one to eight arguments
set mmv {0 1 -1 2 7 3.5 -2.5 0x10 010 " 5" 1e3 abc {} 9007199254740993 9007199254740992 -9007199254740993 9223372036854775807 -9223372036854775808 18446744073709551616 0.0 -0.0 Inf -Inf 1e400 true 1.50 2.0 2}
foreach a $mmv { foreach b $mmv {
    lappend calls [list mm_args $a $b 3] [list mm_args 3 $a $b] [list mm_err $a $b] [list mm_ties $a $b] [list mm_tag $a $b] [list mm_call $a $b] [list mm_ns_user $a $b]
}
    lappend calls [list mm_one $a] [list mm_lit $a] [list mm_many $a 1 2 3 4 5 6 7] [list mm_many 1 $a 2.5 3 4 5 6 $a]
}
foreach n {0 1 5 40} { lappend calls [list mm_int $n] [list mm_dbl $n] [list mm_mixed $n] }
foreach l {{} {5} {1 2 3} {3 2 1} {1.5 2 0x10 3} {0x10 16} {16 0x10} {2.0 2} {2 2.0} {-0.0 0.0} {0.0 -0.0} {1 abc 2} {1e3 999} {1.50 1.5}} {
    lappend calls [list mm_loop $l] [list mm_loop_min $l] [list mm_clamp $l 1 2] [list mm_clamp $l 0.5 1.5] [list mm_clamp $l 0x2 5]
}
lappend calls {mm_clamp {1 2} abc 3} {mm_clamp {1 2} 1 {}}
foreach l {{} {1} {1 2 3} {-1.5 2 -3} {0.5 0.5 -2} {9223372036854775807 1} {9223372036854775807 0.5} {-9223372036854775808 -1} {1e300 1e300} {2.5 -2.5 3} {abc} {1 abc} {0x10 0.5}} { lappend calls [list mw_funcs $l] }
foreach a {0 1 -1 7 2.5 -2.5 0x10 9223372036854775807 -9223372036854775808 1e300 abc} { foreach b {0 1 -1 3 0.5 -0.5 9223372036854775807 4611686018427387904 abc} { lappend calls [list mw_one $a $b] } }
# Phase A, blocker 3: lassign (la_*)
set long {}; for {set i 0} {$i < 176} {incr i} { lappend long [expr {$i * 0.25}] }
foreach r [list {1 2 3 4} {1 2} {} {1 2 3 4 5 6 7 8 9} "a \{b" " 1 2 3 4 " {{1 2} {3 4} 5 6} 0x10 {1.5 2.5 3.5 4.5} $long {1 2 3 abc} {1 2 3 4 5 6 7 8}] {
    foreach p {la_sum la_rest la_many la_none la_ph la_shared la_catch la_used} { lappend calls [list $p $r] }
    lappend calls [list la_dist $r 1 2] [list la_loop [list $r $r]]
}
lappend calls [list la_walls [list {0 0 4 0} {0 3 4 3} $long {0 0 0 4}] 1.5] {la_walls {} 1}
# decision 68: a lassign whose rest is thrown away at the merge point of an if/switch (ld_*): short, long, invalid and shared lists, the value used, in loops, with catch, break, continue
foreach r [list {1 2 3 4} {1 2} {} {1 2 3 4 5 6 7 8 9} "a \{b" {1.5 2.5 3.5 4.5} $long {{1 2} {3 4} 5 6}] {
    foreach fl {0 1} {
        foreach p {ld_if ld_noelse ld_last ld_last1 ld_used ld_catch ld_shared ld_mixed ld_rest} { lappend calls [list $p $r $fl] }
    }
    foreach fl {0 1 2 3} { lappend calls [list ld_switch $r $fl] }
    foreach {f g} {0 0 0 1 1 0 1 1} { lappend calls [list ld_nested $r $f $g] }
    foreach n {0 1 2 5} { lappend calls [list ld_while $r $n] }
}
lappend calls [list ld_loop [list {1 2 3 4} {2 3 4 5} $long {0 1 2 3 4 5}]] [list ld_loop [list {2 3 4 5} "a \{b"]] {ld_loop {}}
lappend calls [list ld_break [list {1 2} {3 4} {1 2 3 4 5 6} {9 9}]] [list ld_continue [list {1 2} {3 4} {1 2 3 4 5 6} {9 9}]] {ld_break {}} {ld_continue {x}}
# decision 69: the dead value of an if/switch statement, numbers, literals and objects (dt_*)
foreach a {0 1 -3 2.5 abc {} {x y} 0x10 9223372036854775807} {
    foreach f {0 1 2 3} { lappend calls [list dt_nums $a [expr {$f & 1}]] [list dt_mix $a $f] [list dt_noelse $a [expr {$f & 1}]] [list dt_lit $a [expr {$f & 1}]] [list dt_sw $a $f] }
    foreach {f g} {0 0 0 1 1 0 1 1} { lappend calls [list dt_nested $a $f $g] }
    foreach f {0 1} { lappend calls [list dt_catch $a $f] }
}
foreach n {0 1 2 3 7 20} { lappend calls [list dt_loop $n] [list dt_leak $n] }
# decision 70: loop-free arithmetic helpers on objects: integers, doubles, text, hex, bignums, limits, errors (wl_*)
set wlv {0 1 -1 7 2.5 -2.5 0x10 1e3 abc {} 9223372036854775807 -9223372036854775808 123456789012345678901234567890 Inf -0.0 .5 1_000}
foreach a $wlv {
    lappend calls [list wl_dbl $a] [list wl_ns $a]
    foreach b {0 1 3 2.5 -1 abc 9223372036854775807 0x7} {
        lappend calls [list wl_mul $a $b] [list wl_cmp $a $b] [list wl_neg $a $b]
        foreach c {2 0.5 -3} { lappend calls [list wl_expr $a $b $c] }
    }
}
foreach l {{1 2 3 4} {0.5 1.5 2.5 3.5} {1 2.5 3 4.5} {a b c d} {1 2} {} {9223372036854775807 1 2 3}} { foreach i {0 1 2 5 -1} { foreach x {2 0.5 abc} { lappend calls [list wl_lidx $l $i $x] } } }
# decision 75: double literals in arithmetic (dl_*): every operation on every kind of value, the literal texts that are not what Tcl prints, errors, the W policy with objects
set dlv {0 1 -1 2 2.5 -2.5 1e3 .5 abc {} 9223372036854775807 -9223372036854775808 1e308 1e-320 -0.0 Inf 0x10 123456789012345678901234567890 2.50 1.}
foreach a $dlv {
    lappend calls [list dl_mult $a] [list dl_floor $a] [list dl_mix $a] [list dl_cmp $a] [list dl_div $a] [list dl_zero $a] [list dl_mod $a] [list dl_big $a] [list dl_neg $a] [list dl_text $a]
    foreach b {0 1 0.5 -2 abc 1e3 2.50 9223372036854775807} { lappend calls [list dl_w $a $b] }
}
foreach n {0 1 5 100 1000} { lappend calls [list dl_loop $n] }
lappend calls {dl_loop 2.5} {dl_loop {}}   ;# not `abc`: `$i < abc` compares as strings and every integer sorts before a letter, so that loop never ends (in the interpreter too)
# decision 71: lappend and append on variables of the frame (lf_*): values of every kind, shared lists, a variable that is missing, an array, not a list, with read and write traces
lappend calls {lf_reset}
foreach v {5 2.5 abc {} {a b} {a {b c}} 0x10 "x\{y"} {
    lappend calls [list lf_var $v 3] [list lf_app $v 3] [list lf_glob $v] [list lf_call $v 2] [list lf_val $v] [list lf_shared $v] {lf_reset}
}
foreach n {0 1 7} { lappend calls [list lf_num $n] }
lappend calls {lf_reset} {lf_unset} {lf_var 1 2} {lf_unset} {lf_val 3} {lf_reset} {lf_setv {a b}} {lf_var 1 2} {lf_setv "a \{b"} {lf_var 1 2} {lf_val 2} {lf_setv 5} {lf_var 1 2} {lf_app 1 2}
lappend calls {lf_reset} {lf_arr} {lf_var 1 2} {lf_reset} {lf_arr} {lf_app 1 2} {lf_reset}
lappend calls {lf_trace_w} {lf_var 1 3} {lf_val 7} {set lflog} {lf_reset} {lf_trace_r} {lf_var 1 3} {lf_val 7} {lf_num 2} {set lflog} {lf_reset}
lappend calls [list lf_call 1 0] [list lf_upv nosuch 1 2] [list lf_upa nosuch 1 2]
# decision 72: tuples of numbers returned and taken apart unboxed (yt_*): integers, doubles, text, hex, limits, literals, a callee that also returns text, errors, overflow
set ytv {0 1 -1 3 2.5 -2.5 0x10 1e3 abc {} 9223372036854775807 -9223372036854775808 4611686018427387904 Inf}
foreach x $ytv {
    foreach p {yt_pair yt_two yt_use yt_few yt_many yt_idx yt_idx2 yt_len yt_pass yt_pass2 yt_set yt_for yt_dupuse yt_rest yt_cmp yt_lit yt_litint yt_lit_use yt_mixed yt_mixed_use} { lappend calls [list $p $x] }
    foreach f {0 1} { lappend calls [list yt_branch $x $f] }
    foreach y {2 0.5 abc} { lappend calls [list yt_wide $x $y] [list yt_w $x $y] }
    foreach y {2 -3 0.5 9223372036854775807} { lappend calls [list yt_tri $x $y 3] [list yt_use3 $x $y 3] [list yt_ovf $x $y] [list yt_ovf_use $x $y] }
}
foreach n {0 1 2 5 12} { lappend calls [list yt_loop $n] }
foreach n {0 1 2 5 30 -3 2.5 abc} { lappend calls [list yt_rec $n] }
foreach l {{1 2} {1.5 2.5} {a b} {1} {} {0x10 0.5} {{1 2} 3}} { lappend calls [list yt_obj $l] [list yt_obj_use $l] }
# decisions 73 and 74: calls through an import (the import deleted, redefined, replaced by a proc, forgotten; the origin redefined and renamed) and lsort with options
foreach n {0 1 5 40} { lappend calls [list ::imu::im_loop $n] [list ::imu::im_fnloop $n] }
foreach x {0 1 2.5 -3 abc 0x10 {}} { lappend calls [list ::imu::im_one $x] [list ::imu::im_abs $x] [list ::imu::im_fn $x] }
lappend calls {rename ::imu::im_sq ""} {catch {::imu::im_one 3} m; set m} {catch {::imu::im_loop 3} m; set m} {::imu::im_abs 3}
lappend calls {namespace eval ::imu { namespace import ::imx::im_sq }} {::imu::im_one 3} {::imu::im_loop 4}
lappend calls {proc ::imu::im_sq {x} { return shadow$x }} {::imu::im_one 3} {catch {::imu::im_loop 3} m; set m}
lappend calls {rename ::imu::im_sq ""} {namespace eval ::imu { namespace import ::imx::im_sq }} {::imu::im_one 4} {::imu::im_loop 4}
lappend calls {proc ::imx::im_sq {x} { return [expr {$x + 100.0}] }} {::imu::im_one 3} {::imu::im_loop 5} {::imu::im_abs 3}
lappend calls {rename ::imx::im_sq ::imx::im_sq2} {::imu::im_one 3} {::imu::im_loop 5} {rename ::imx::im_sq2 ::imx::im_sq} {::imu::im_one 3}
lappend calls {namespace eval ::imu { namespace forget im_sum }} {catch {::imu::im_loop 3} m; set m} {namespace eval ::imu { namespace import ::imx::im_sum }} {::imu::im_loop 3}
lappend calls {proc ::imu::im_sum {x y} { return [expr {$x + $y + 1000.0}] }} {::imu::im_loop 3} {rename ::imu::im_sum ""} {namespace eval ::imu { namespace import ::imx::im_sum }} {::imu::im_loop 3}
lappend calls {proc ::imx::im_mf {x} { return [expr {$x - 100.0}] }} {::imu::im_fn 2} {::imu::im_fnloop 4} {rename ::imu::tcl::mathfunc::im_mf ""} {catch {::imu::im_fn 2} m; set m}
foreach l {{3 1 2} {5 5 1 1} {} {10 9 8 7 100} {1 a 2} {0x10 3} {1.5 2} {-1 -5 -5 0}} {
    lappend calls [list ls_ints $l] [list ls_dict $l] [list ls_cmd $l] [list ls_err $l] [list ls_pure $l] [list ls_var $l 1]
    foreach f {-ascii -integer -real -dictionary -decreasing -unique -nocase -bogus} { lappend calls [list ls_opts $l $f] }
}
lappend calls {ls_idx {{a 3} {b 1} {c 2}}} {ls_idx {{a 3} {b 1 x} c}}
foreach n {0 1 2 7 30} { lappend calls [list ls_loop $n] }
lappend calls {rename lsort lsort_orig} {proc lsort {args} { uplevel 1 {set k 99}; return LS }} {ls_pure {2 1}} {ls_loop 3} {rename lsort ""} {rename lsort_orig lsort} {ls_pure {2 1}}
# lindex with several indices (lx_*)
set lxm [list {{a b c} {d e f} {g h i}} {{1 2} {3 4}} {} "a \{b" {{1 {2 3}} {4 5}} {a b c} 5 {{x y} {} {z}} "\{a b\} \{c"]
set lxi {0 1 2 -1 5 end end-1 1+1 0x1 a " 1" 1.5 {} {1 2} 9223372036854775807}
foreach m $lxm { foreach i $lxi { foreach j {0 1 end x} { lappend calls [list lx_multi $m $i $j] }; lappend calls [list lx_three $m $i 0 1] [list lx_three $m 0 $i 1] }
    lappend calls [list lx_const $m] [list lx_end $m] }
foreach n {0 1 3} { lappend calls [list lx_loop {{1 2 3} {4 5 6} {7 8 9}} $n] [list lx_dbl {{1.5 2 3} {4 5.5 6} {7 8 9.25}} $n] }
lappend calls {lx_loop {{1 2} {3 4}} 3} {lx_dbl {{1 2} {3 4}} 3} {lx_loop {{1 2} {3 x}} 2}
# decision 61: doubles with a string form: canonical text (held unboxed) and every other text (handed over), as arguments, stored list elements, kept elements, with tcl_precision changed
# (the calls that write tcl_precision come last in the list: the module stops accepting texts of doubles for good at the first one)
set cdprec {}
set cdlists {{0.35 2.5} {2.50 1.5} {1e3 0.1} {0.1 0.2} {3.0 1.5} {0.30000000000000004 1.0e-5} {123456789.123 0.0001} {1.7976931348623157e+308 5e-324} {-0.0 0.0} {.5 5.} {+1.5 -1.5}
    {0.5 0.50} {1.0 1} {1_0 2.5} {Inf 1.5} {inf 1.5} {0x10 1.5} {1.5 abc} {1.5} {} {2.5 0.1 0.25 7.0 3.14159265358979}}
# (a script, not a proc call: the interpreter itself parses the elements, which gives doubles that keep their text; compiled code reads a number from an element without making it one)
foreach l $cdlists {
    set pre "set cdl [list $l]; foreach cdv \$cdl {catch {expr {\$cdv + 0.0}}}; "
    lappend calls "${pre}cd_via \$cdl" "${pre}cd_store \$cdl" "${pre}cd_keep \$cdl"
    lappend cdprec "${pre}cd_prec \$cdl 3" "${pre}cd_prec \$cdl 17" "${pre}cd_prec \$cdl 0"
}
# Phase A3, decision 63: flagged tagged numbers in a proc that is not pure (fw_*)
foreach {x y} {2 3 1.5 2 2.5 0.5 0x10 3 4 0 3 0.0 abc 2 2.50 3 1e3 1 9223372036854775807 2 2 {}} {
    foreach n {0 1 2 3 4 6 9} { lappend calls [list fw_main $x $y $n] [list fw_late $x $y $n] }
}
foreach l {{1 2 3 4 5 6 7 8} {1.5 2.5 3.5 4.5 5.5 6.5 7.5 8.5} {1 2.5 3 x 5 6 7 8} {0x1 2 3 4 5.0 6 7 8}} { foreach n {0 1 3 4 6 8} { lappend calls [list fw_list $l $n] } }
foreach x {2 2.5 0x10 abc} { foreach n {0 1 2 3} { lappend calls [list fw_trace $x $n] {set fwlog} } }
# decision 64: `binary scan` and `scan` with several variables (bs_*): enough data, too little, bad formats, variables that keep their old values, strings and negative offsets
foreach d {"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18" "\xff\x80\x7f\x00\xff\x80\x7f\x00\xff\x80\x7f\x00" "" "ab" "\x01\x02\x03"} {
    foreach u {0 0.4 0.9 -0.5 2.7 5} { foreach n {1 3 6} { lappend calls [list bs_texel $d $u $n] } }
    lappend calls [list bs_fixed $d] [list bs_reuse $d]
    foreach n {0 1 4 20} { lappend calls [list bs_loop $d $n] }
}
foreach str {"12 34 abc" "12 x abc" "" "1.5,ff" "1.5,zz" "-3 +4 q" "0x10 5 w" " 7  8  z " "99999999999999999999 1 a"} { lappend calls [list bs_scan $str] }
lappend calls {bs_texel x 0 1} [list bs_texel [binary format c* {1 2 3 4 5 6 7 8}] 0.2 2]
# decision 76: `binary scan` of f and f* typed, helpers called directly by compiled callers (values, short data, an old value kept, redefinition, rename, traces, errors)
foreach v {0 1 -1 0.1 3.14159 16777217 1e38 3.5e38 -3.5e38 1e300 -1e300 1e-45 1e-50 1e400 Inf -Inf NaN 0x10 " 5" abc {} 9223372036854775807 100000000000000000000 -0.0 true 1.5e-39} {
    lappend calls [list fs_f32 $v] [list fs_f32a $v] [list fs_chain $v] [list fs_keep $v] [list fs_f32l [list $v $v]] [list fs_f32l $v]
}
foreach d [list {} "\x01" "\x01\x02\x03" [binary format f 1.5] [binary format f 0.1]x [binary format f* {1 2 3}] [binary format f* {1 2}]ab [binary format r 2.5] [binary format f nan] [binary format f -1e38] "abcdefgh" abcd é€] {
    lappend calls [list fs_scan $d] [list fs_scanl $d] [list fs_scan_twice $d] [list fs_ret_unset $d]
}
foreach n {0 1 7 100} { lappend calls [list fs_loop $n] [list fs_listloop $n] }
lappend calls [list fs_loop_obj {0 1.5 abc}] [list fs_loop_obj {0.25 1e300 3 0x4}] [list fs_loop_obj {}] [list fs_loop 2.5] {fs_f32} {fs_f32 1 2}
lappend calls {set a [fs_loop 5]; rename fs_f32 fs_f32_o; proc fs_f32 {x} { return [expr {$x * 2.0}] }; set b [fs_loop 5]; rename fs_f32 {}; rename fs_f32_o fs_f32; list $a $b [fs_loop 5]}
lappend calls {set a [fs_loop 5]; rename fs_f32a fs_f32a_o; proc fs_f32a {x} { return 7 }; set b [fs_loop 5]; set c [fs_chain 2]; rename fs_f32a {}; rename fs_f32a_o fs_f32a; list $a $b $c [fs_loop 5] [fs_chain 2]}
lappend calls {set a [fs_loop 3]; rename fs_f32 fs_f32_r; set e [catch {fs_loop 3} m]; rename fs_f32_r fs_f32; list $a $e $m [fs_loop 3]}
lappend calls {set a [fs_listloop 3]; rename fs_f32l fs_f32l_r; set e [catch {fs_listloop 3} m]; rename fs_f32l_r fs_f32l; list $a $e $m [fs_listloop 3]}
lappend calls {set a [fs_loop 3]; rename fs_f32 {}; set e [catch {fs_loop 3} m]; proc fs_f32 {x} { binary scan [binary format f $x] f r; return $r }; list $a $e $m [fs_loop 3]}
# decision 79: `binary format f` and `f*` typed: a double, an object, an integer, a string, NaN, Inf and the float range's edges as the pending value, its bytes, a list
foreach v {0 0.1 -0.0 1.5 3.14159 16777217 16777215.5 1e-45 7e-46 1e-50 1.17549435e-38 3.4028235e38 3.4028236e38 3.5e38 -3.5e38 1e300 -1e300 1e-300 1e400 Inf -Inf NaN 0x10 " 5" abc {} 9223372036854775807 100000000000000000000 true 1.5e-39 2.5 -7 0} {
    lappend calls [list f9_bytes $v] [list f9_mix $v] [list f9_int $v] [list f9_arg $v] [list f9_pair $v] [list f9_list [list $v 1.25]] [list f9_listscan [list $v $v]] [list f9_listscan $v] [list f9_loopobj [list $v 2.0]]
}
foreach l {{} {1 2 3} {1.5 abc} {0.1 NaN} {Inf -Inf 1e39} {-0.0 16777217 2.5} {{1 2} 3} {1 {} 2} {0x10 1e-45}} { lappend calls [list f9_list $l] [list f9_listscan $l] [list f9_loopobj $l] }
lappend calls [list f9_two 1.5 2.25] [list f9_two abc 1] [list f9_two 1e300 -1e300] [list f9_loop 0] [list f9_loop 9] [list f9_loop 2000]
lappend calls {set a [f9_loop 3]; rename binary binary_f9; proc binary {args} { incr ::f9n; uplevel 1 [list binary_f9 {*}$args] }; set ::f9n 0; set b [f9_loop 3]; set n $::f9n; rename binary {}; rename binary_f9 binary; list $a $b $n [f9_loop 3]}
lappend calls {set ::trj {}; trace add execution binary enter {lappend ::trj}; set r [f9_loop 3]; trace remove execution binary enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set ::trj {}; trace add execution ::tcl::binary::format leave {lappend ::trj}; set r [f9_list {1 2}]; trace remove execution ::tcl::binary::format leave {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set a [catch {f9_list {1.5 2}} m1]; rename ::tcl::binary::format f9_fmt_o; proc ::tcl::binary::format {args} { return "replaced" }; set b [catch {f9_list {1.5 2}} m2]; set c [catch {f9_mix 2.5} m3]; rename ::tcl::binary::format {}; rename f9_fmt_o ::tcl::binary::format; list $a $m1 $b $m2 $c $m3 [f9_mix 2.5]}
lappend calls {namespace eval fsns { proc fs_f32 {x} { return NS } }; set a [fs_loop 2]; namespace eval fsns { rename fs_f32 {} }; list $a [fs_loop 2]}
lappend calls {set ::trj {}; trace add execution fs_f32 enter {lappend ::trj}; set r [fs_loop 3]; trace remove execution fs_f32 enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set ::trj {}; trace add execution fs_f32l leave {lappend ::trj}; set r [fs_listloop 3]; trace remove execution fs_f32l leave {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set ::trj {}; trace add command fs_f32a rename {lappend ::trj}; set r [fs_loop 2]; rename fs_f32a fs_f32a_t; set r2 [catch {fs_loop 2} m]; rename fs_f32a_t fs_f32a; trace remove command fs_f32a rename {lappend ::trj}; list $r $r2 $m [llength $::trj]}
lappend calls {set ::trj {}; trace add execution ::tcl::binary::scan enter {lappend ::trj}; set r [fs_loop 3]; trace remove execution ::tcl::binary::scan enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set ::trj {}; trace add execution binary enter {lappend ::trj}; set r [fs_listloop 3]; trace remove execution binary enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {set ::trj {}; trace add variable ::fs_tv write {lappend ::trj}; set r [fs_loop 3]; trace remove variable ::fs_tv write {lappend ::trj}; list $r [llength $::trj]}
lappend calls {rename ::tcl::binary::scan fs_scan_o; proc ::tcl::binary::scan {args} { uplevel 1 {set r 55}; return 1 }; set a [list [fs_f32 1.5] [fs_scan [binary format f 2.5]]]; rename ::tcl::binary::scan {}; rename fs_scan_o ::tcl::binary::scan; set a}
# decision 77: lappend with several values typed; typed code entered again at a loop head (a dead or unset table array, an integer vector from the frame); caller-safe procs whose callees use `upvar 1`
foreach n {0 1 2 5 40} { lappend calls [list lp_multi $n] [list lp_mixed $n] [list lp_unset $n] [list lp_shared $n] [list lp_result $n] [list lp_base {a b} $n] [list lp_base "a \{b" $n] [list lp_base {} $n] [list lp_base 5 $n] }
foreach n {0 1 2 3} { lappend calls [list lp_self $n] }
lappend calls {lp_pre} {lp_multi} {lp_multi 1 2} {lp_base x}

# decision 80: objects appended to a native vector (the lifting step), in place `lset`; lists with doubles, text, non-canonical integers, an element held elsewhere, a shared list, a string form
set vbl {{1 2 3 4 5 6 7 8} {} {5} {1 2 3 4 5 6 7 8 9} {1 2 3.5 4 5 6 7 8} {1 2 3 abc 5 6 7 8} {1 2 3 007 5 6 7 8} {1 2 0x10 4 5 6 7 8} {1 2 3 1e3 5 6 7 8} {1 2 " 5" 4 5 6 7 8} {1 2 3 {} 5 6 7 8} {1 2 3 4 5 6 7 100000000000000000000} {9223372036854775807 2 3 4 5 6 7 8} {-1 -2 -3 -4 -5 -6 -7 -8} {1 {2 3} 3 4 5 6 7 8} {1 2 3 4}}
foreach l $vbl { foreach n {0 1 2 3 7 8 9} { lappend calls [list vb_lift_w $l 0 1 $n] [list vb_lift_str $l $n] [list vb_lift_twice $l $n] } }
foreach l {{1 2 3 4 5 6 7 8} {1 2 3 4 5 6 7 8 9 10 11 12}} { foreach {off stride n} {0 2 4 1 2 3 0 3 4 2 1 5 5 1 4} { lappend calls [list vb_lift_w $l $off $stride $n] } }
lappend calls {vb_lift_w} {vb_lift_w {1 2} 0 1} {vb_lift_w "1 \{2" 0 1 2} {vb_lift_w 5 0 1 1} {vb_lift_w 5 0 1 2}
foreach n {0 1 2 8 33} { lappend calls [list vb_inplace $n] [list vb_inplace_shared $n] }
foreach l {{1 2 3} {007 0x10 1e3} {1 2 3.5} {a b c} {{1 2} 3 4} {1 2 3 4 5} {100000000000000000000 2 3} {-1 -2 -3} {5 5 5}} { lappend calls [list vb_inplace_str $l] [list vb_inplace_elem $l] [list vb_inplace_type $l] }
foreach {l i} {{1 2 3} 3 {1 2 3} -1 {1 2 3} end {1 2 3} abc {} 0 {1 2 3} 1.5 {1 2 3} {0 0}} { lappend calls [list vb_inplace_err $l $i] }
foreach {k n} {0 8 1 8 3 16 2 1 2 2 5 33} { lappend calls [list vb_drive $k $n] }
foreach n {0 1 2 8 33} { lappend calls [list vb_inplace_dbl $n] }
foreach l {{1.5 2.5 3.5} {1 2 3} {a b c} {1e3 2e3 3e3} {0x10 007 1_0} {1.5 2.5 3.5 4.5} {{1 2} 3 4} {-0.0 0.0 1.0} {1e308 -1e308 5.5}} { lappend calls [list vb_inplace_dbl_x $l] }
foreach {l i} {{1.5 2 3} 3 {1.5 2 3} -1 {1.5 2 3} end {1.5 2 3} abc {} 0 {1.5 2 3} 1.5 {1.5 2 3} {0 0}} { lappend calls [list vb_inplace_dbl_err $l $i] }
# decision 81: index words of lindex folded into the integer they name
set ixl {{a b c d e f g h} {} {a} {{1 2} {3 4} {5 6}} "a \{b" {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}}
set ixv {-9 -3 -2 -1 0 1 2 3 5 6 7 11 12 13 2147483646 2147483647 2147483648 -2147483647 -2147483648 -2147483649 9223372036854775807 007 0x5 5.0 " 5" end abc {} {1 2} 1e1 +3 -0}
foreach l $ixl { foreach i $ixv { foreach j {0 1 -1 3 12 2147483647 -2147483648 2147483648 abc 007 { 1}} { lappend calls [list ix_basic $l $i $j] [list ix_one $l $i $j] [list ix_obj $l $i $j] } } }
foreach l $ixl { foreach i $ixv { lappend calls [list ix_lit $l $i] [list ix_keep $l $i] [list ix_shared $l $i] [list ix_nested $l $i] } }
foreach l $ixl { foreach n {0 1 2 5 9 20} { lappend calls [list ix_loop $l $n] } }
foreach n {0 1 2 3 9 40} { lappend calls [list ix_vec $n] }
foreach l $ixl { foreach {a b} {0 0 1 2 3 1 5 -3 -1 -2 2147483647 1 -2147483648 1 2147483647 -2147483648 4000000000 1 1 4000000000 1.5 2 2 1.5 abc 1 1 {} 007 1 08 1 0x3 1} { lappend calls [list ix_arith $l $a $b] [list ix_wide $l $a $b] } }
foreach l $ixl { foreach a {0 1 3 5 -1 2.5 abc 1e1} { foreach j {0 1 7 -3 2147483647} { lappend calls [list ix_tag $l $a $j] } } }
foreach l $ixl { foreach {i j} {0 1 1 1 2 -1 5 0} { lappend calls [list ix_cond $l $i $j] } }
foreach n {0 1 2 5 30} { lappend calls [list rs_main $n] [list rs_mklev $n] [list cs_outer $n] [list cs_outer2 $n] [list cs_outer3 $n] }
foreach h {{} {rs_adddl} {rs_baddl} {rs_oddl} {rs_adddl; rs_oddl} {set dl {5 6}} {set dl 7} {unset dl} {set dl "1 2 \{"} {set dl {1.5 2}} {set dl { 5 6 }}} { foreach n {0 1 4 12} { lappend calls [list rs_adj $n $h] } }
lappend calls {rs_main 2.5} {rs_mklev 2.5} {rs_up nosuch} {cs_outer 2.5}
# decision 78: a caller-safe callee redefined at run time so that it reaches its caller's frame (found by decision 77): the compiled caller must not keep a stale local
lappend calls {rename cs_inner cs_inner_o; proc cs_inner {nm} { upvar 2 $nm v; set v 1000 }; set r [cs_outer 3]; rename cs_inner {}; rename cs_inner_o cs_inner; set r}
lappend calls {rename cs_inner cs_inner_o; proc cs_inner {nm} { uplevel 2 {set x 1000}; return 1 }; set r [cs_outer 3]; rename cs_inner {}; rename cs_inner_o cs_inner; set r}
lappend calls {cs_outer 3} {cs_outer2 3}
lappend calls {rename cs_inner cs_inner_o; proc cs_inner {nm} { upvar 1 $nm v; incr v; return $v }; set r [list [cs_outer 3] [cs_outer 1]]; rename cs_inner {}; rename cs_inner_o cs_inner; set r}
proc rd_fix {} {
    proc ::rd_leaf {} { array set a {k 1}; return $a(k) }
    proc ::rd_gleaf {} { array set a {k 1}; return $a(k) }
    proc ::rd_pleaf {a} { return [expr {$a + 1}] }
    proc ::rd_swap {} { proc ::rd_leaf {} { uplevel 1 {set x 77}; return 1 } }
}
lappend calls {rd_outer 3} {rd_top 3} {rd_gouter 3} {rd_pouter 3} {rd_pdirect 3} {set r [rd_loop 4]; rd_fix; set r} {rd_two 3}
foreach body {
    {uplevel 1 {set x 77}; return 1}
    {upvar 1 x v; set v 78; return 1}
    {uplevel 1 {incr x 5}; return 1}
    {uplevel 1 {unset x}; return 1}
    {uplevel 1 {set x}; return 1}
    {return [info level]}
    {return [info level -1]}
    {return [uplevel 1 {info level}]}
    {return [uplevel 1 {info vars}]}
    {upvar 2 x v; set v 79; return 1}
    {uplevel 2 {set x 80}; return 1}
    {uplevel #1 {set x 81}; return 1}
    {uplevel #2 {set x 82}; return 1}
    {uplevel 1 {array set a {x 1}}; return 1}
    {return 5}
    {error boom}
} {
    lappend calls "rename rd_leaf rd_leaf_o; proc rd_leaf {} {$body}; set r \[catch {rd_outer 3} m\]; set r2 \[catch {rd_top 3} m2\]; set r3 \[catch {rd_two 3} m3\]; set r4 \[catch {rd_loop 3} m4\]; rename rd_leaf {}; rename rd_leaf_o rd_leaf; rd_fix; list \$r \$m \$r2 \$m2 \$r3 \$m3 \$r4 \$m4"
    lappend calls "rename rd_gleaf rd_gleaf_o; proc rd_gleaf {} {$body}; set r \[catch {rd_gouter 3} m\]; rename rd_gleaf {}; rename rd_gleaf_o rd_gleaf; rd_fix; list \$r \$m"
    lappend calls "rename rd_pleaf rd_pleaf_o; proc rd_pleaf {a} {$body}; set r \[catch {list \[rd_pdirect 3\] \[rd_pouter 3\]} m\]; rename rd_pleaf {}; rename rd_pleaf_o rd_pleaf; rd_fix; list \$r \$m"
    # the same definition made again, so that the compiled code may be used again
    lappend calls "proc rd_leaf {} {$body}; set r \[catch {rd_outer 3} m\]; proc rd_leaf {} { array set a {k 1}; return \$a(k) }; list \$r \$m \[rd_outer 3\] \[rd_outer 2\]"
}
lappend calls {rd_outer 3} {rd_top 3} {rd_gouter 3} {rd_pouter 3} {rd_pdirect 3} {set r [rd_loop 4]; rd_fix; set r}
# renamed away and back, deleted, defined again with the same text, defined in a namespace that shadows it
lappend calls {rename rd_leaf rd_leaf_o; set r [catch {rd_outer 3} m]; rename rd_leaf_o rd_leaf; list $r $m [rd_outer 3]}
lappend calls {rename rd_leaf rd_leaf_o; proc rd_leaf {} { uplevel 1 {set x 90}; return 1 }; set a [rd_outer 2]; rename rd_leaf {}; rename rd_leaf_o rd_leaf; list $a [rd_outer 2]}
lappend calls {rename rd_leaf rd_leaf_o; proc rd_leaf {} { uplevel 1 {set x 91}; return 1 }; set a [rd_outer 2]; rename rd_leaf rd_leaf_x; rename rd_leaf_o rd_leaf; set b [rd_outer 2]; rename rd_leaf_x {}; list $a $b}
lappend calls {rename rd_leaf rd_leaf_o; set r [catch {rd_outer 2} m]; proc rd_leaf {} { array set a {k 1}; return $a(k) }; rename rd_leaf_o {}; list $r $m [rd_outer 2]}
lappend calls {set r [rd_loop 5]; rd_fix; set r} {rd_outer 3}
lappend calls {rename rd_swap rd_swap_o; proc rd_swap {} { proc ::rd_leaf {} { uplevel 1 {set x 92}; return 1 } }; set a [rd_loop 4]; rename rd_swap {}; rename rd_swap_o rd_swap; rd_fix; list $a [rd_outer 2]}
lappend calls {rename rd_leaf rd_leaf_o; proc rd_leaf {} { upvar 1 x v; incr v 7; return 2 }; set a [list [rd_outer 3] [rd_loop 3] [rd_top 3]]; rename rd_leaf {}; rename rd_leaf_o rd_leaf; rd_fix; list $a [rd_outer 2]}
# traces on a callee (execution traces run in the caller's frame)
lappend calls {set ::trj {}; trace add execution rd_leaf enter {lappend ::trj}; set r [rd_outer 3]; trace remove execution rd_leaf enter {lappend ::trj}; list $r [llength $::trj]}
lappend calls {rename rd_leaf rd_leaf_o; proc rd_leaf {} { return 3 }; set ::trj {}; trace add execution rd_leaf enter {lappend ::trj}; set r [rd_outer 3]; trace remove execution rd_leaf enter {lappend ::trj}; rename rd_leaf {}; rename rd_leaf_o rd_leaf; list $r [llength $::trj]}
lappend calls {rename rd_leaf rd_leaf_o; proc rd_leaf {} { return 3 }; proc rd_trcb {args} { uplevel 2 {set x 93} }; trace add execution rd_leaf enter rd_trcb; set r [rd_outer 3]; trace remove execution rd_leaf enter rd_trcb; rename rd_leaf {}; rename rd_leaf_o rd_leaf; rename rd_trcb {}; list $r}
lappend calls {proc rd_trcb {args} { uplevel 2 {set x 94} }; trace add execution rd_leaf enter rd_trcb; set r [rd_outer 3]; trace remove execution rd_leaf enter rd_trcb; rename rd_trcb {}; list $r}
lappend calls {proc rd_trcb {args} { uplevel 2 {set x 95} }; trace add execution rd_leaf leave rd_trcb; set r [rd_outer 3]; trace remove execution rd_leaf leave rd_trcb; rename rd_trcb {}; list $r}
lappend calls {rd_outer 3} {rd_top 3} {rd_gouter 3} {rd_pouter 3} {rd_pdirect 3} {set r [rd_loop 4]; rd_fix; set r}
# decision 65: `set ::ns::name value` (ss_*): values of every kind, a variable that is missing, only declared, traced, unset, an array, in a namespace that is deleted and made again, linked
foreach v {5 2.5 abc {} {a b} 0x10 1e3 9223372036854775807} { lappend calls [list ss_set $v] [list ss_val $v] }
foreach x {2 1.5 abc 0x10} { foreach n {0 1 3} { lappend calls [list ss_num $x $n] } }
lappend calls {ss_missing} {ss_missing} {ss_declare} {ss_setD 1} {ss_setD 2.5} {ss_arr} {ss_link} {ss_set 7}
lappend calls {ss_trace_on} {ss_set 1} {ss_num 2 3} {ss_val 4} {set sslog} {ss_trace_off} {ss_set 2} {ss_num 2 3} {set sslog}
lappend calls {ss_unset} {ss_set 3} {ss_num 1 2} {ss_unset} {ss_val 4} {ss_set 5}
lappend calls {ss_ns_delete} {ss_set 1} {ss_num 1 2} {ss_val 1} {ss_ns_make} {ss_set 8} {ss_num 3 2}
# decision 65: `incr ::ns::name` (ss_incr*): integers, an incr past the limit, text, a double, an unset or missing variable, a trace
lappend calls {ss_incr_reset} {ss_incr 0} {ss_incr 1} {ss_incr 5} {ss_incr_val 3} {ss_incr_val -7} {ss_incr_val 0x10} [list ss_incr_val 2.5] [list ss_incr_val abc]
lappend calls {ss_incr_s} {ss_incr_big} {ss_incr_reset} {ss_incr_miss} {ss_incr_bad ::ssn::I} {ss_incr_bad ::ssn::S} {ss_incr_bad nonesuch}
lappend calls {ss_incr_reset} {ss_trace_i_on} {ss_incr 2} {ss_incr_val 1} {set sslog} {ss_trace_i_off} {ss_incr 2} {ss_incr_reset} {ss_trace_on} {ss_incr 2} {ss_incr_val 1} {set sslog} {ss_trace_off} {ss_incr 2} {ss_incr_reset}
# decision 66: elements of a namespace array by its literal absolute name (sa_*): values, keys, increments, missing and scalar variables, traces on an element, on the array, for reads, unset and made again
lappend calls {sa_reset}
foreach k {a b c new 7 {} {a b}} { lappend calls [list sa_set $k 5] [list sa_set $k 2.5] [list sa_set $k xyz] [list sa_exists $k] [list sa_incr $k 3] [list sa_incr $k 0x10] [list sa_incr $k abc] [list sa_incr $k 2.5] }
lappend calls {sa_loop 0} {sa_loop 1} {sa_loop 5} {sa_scalar} {sa_missing} {sa_reset} {sa_elunset a} {sa_exists a} {sa_set a 1} {sa_incr a 1} {sa_make} {sa_loop 3}
lappend calls {sa_trace_on} {sa_set a 3} {sa_set b 3} {sa_incr a 1} {sa_loop 2} {set salog} {sa_trace_off} {sa_set a 4} {set salog}
lappend calls {sa_atrace_on} {sa_set a 5} {sa_incr b 1} {sa_exists a} {set salog} {sa_atrace_off} {sa_set a 6}
lappend calls {sa_rtrace_on} {sa_exists a} {sa_set a 7} {sa_incr a 1} {set salog} {sa_rtrace_off} {sa_exists a}
lappend calls {sa_unset} {sa_set a 1} {sa_exists a} {sa_incr a 1} {sa_missing} {sa_make} {sa_set a 2} {sa_loop 2} {sa_reset}
# Phase A, blocker 1: procs that only read namespace variables (nv_*): the usual case, then each change of the variables that the interpreter notices (and compiled code must)
lappend calls {nv_reset} {nv_all 2} {nv_all 1.5} {nv_all 3} {nv_all a} {nv_loop 5} {nv_loop2 3 3} {nv_loop2 3 b}
lappend calls {nv_set K 4} {nv_all 2} {nv_loop 3} {nv_set K 4.5} {nv_all 2} {nv_set K abc} {nv_all 2} {nv_set K 0x10} {nv_all 2} {nv_set K 3.0} {nv_all 2}
lappend calls {nv_set I 9223372036854775807} {nv_all 2} {nv_set I 1e3} {nv_all 2} {nv_set I 7} {nv_set G 1} {nv_set nvG 5} {nv_all 2}
lappend calls {nv_unset K} {nv_all 2} {nv_loop 2} {nv_k 2} {nv_abs 2} {nv_up 2} {nv_set K 3.0} {nv_all 2} {nv_loop 2}
lappend calls {nv_arrayify} {nv_all 2} {nv_k 2} {nv_loop 2} {nv_reset} {nv_all 2}
# (a namespace deleted and made again with other values: a variable kept from before must not be read)
lappend calls {nv_reset 5.5 70} {nv_all 2} {nv_loop 3} {nv_reset 6.25 71} {nv_all 2} {nv_loop 3} {nv_reset} {nv_all 2} {nv_loop 3}
lappend calls {nv_trace_on K} {nv_all 2} {nv_loop 2} {nv_log} {nv_trace_off K} {nv_all 2} {nv_loop 2} {nv_log} {nv_reset}
lappend calls {nv_trace_elem} {nv_all b} {nv_loop2 2 3} {nv_log} {nv_trace_elem_off} {nv_all b} {nv_loop2 2 3} {nv_reset}
lappend calls {nv_trace_unset} {nv_all 2} {nv_unset K} {nv_all 2} {nv_set K 3.0} {nv_all 2} {nv_trace_unset_off} {nv_all 2} {nv_reset}
lappend calls {nv_all 1} {nv_ns_delete} {nv_all 1} {nv_loop2 2 3} {nv_ns_make 8.25} {nv_all 1} {nv_loop2 2 3} {nv_ns_replace 1.5} {nv_all 1} {nv_ns_replace 2.5} {nv_loop2 2 3} {nv_reset}
lappend calls {nv_rename} {nv_all 2} {nv_loop 2} {nv_rename_back} {nv_all 2} {nv_loop 2} {nv_redefine} {nv_all 2} {nv_loop 2} {nv_redefine_back} {nv_all 2} {nv_loop 2}
foreach x {0 1 2 3 b a x abc {} 1e3 0x10 -1 9223372036854775807} { lappend calls [list nv_all $x] [list nv_loop2 2 $x] }
lappend calls {nv_reset} {nv_all 2} {nv_loop 3}
lappend calls {mm_redef}

lappend calls {*}$cdprec
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
set mustAttach {::nv_k ::nv_up ::nv_glob ::nv_abs ::nv_arr ::nv_absarr ::nv_str ::nv_two ::nv_del ::nv_lit ::nv_all ::nv_loop ::nv_loop2 ::nvns::get ::lx_multi ::lx_three ::lx_const ::lx_end ::lx_loop ::lx_dbl ::la_sum ::la_rest ::la_loop ::la_many ::la_none ::la_ph ::la_shared ::la_catch ::la_used ::la_dist ::la_walls ::mw_funcs ::mw_one ::mm_int ::mm_dbl ::mm_mixed ::mm_args ::mm_one ::mm_lit ::mm_many ::mm_ties ::mm_tag ::mm_loop ::mm_loop_min ::mm_clamp ::mm_call ::mm_helper ::mm_err ::mm_ns_user ::mmns::go ::sd_cat ::sd_for ::sd_while ::sd_append ::sd_nest ::sd_break ::sd_while_break ::sd_for_break ::sd_catch ::sd_two_loops ::sd_global ::tl_lmap1 ::tl_lmap2 ::tl_lmap3 ::tl_lmap4 ::tl_lmap5 ::tl_lmap6 ::tl_lmap7 ::tl_arrset_in_loop ::tl_arrset_odd ::tl_dictfor_in_loop ::ld_if ::ld_noelse ::ld_last ::ld_last1 ::ld_used ::ld_switch ::ld_loop ::ld_break ::ld_continue ::ld_catch ::ld_shared ::ld_mixed ::ld_nested ::ld_while ::ld_rest ::dt_nums ::dt_mix ::dt_noelse ::dt_lit ::dt_sw ::dt_loop ::dt_nested ::dt_catch ::dt_leak ::wl_mul ::wl_expr ::wl_lidx ::wl_cmp ::wl_ns ::wl_dbl ::wl_neg ::lf_var ::lf_app ::lf_glob ::lf_upv ::lf_upa ::lf_call ::lf_val ::lf_shared ::lf_num ::yt_pair ::yt_two ::yt_rec ::yt_use ::yt_use3 ::yt_few ::yt_many ::yt_idx ::yt_idx2 ::yt_len ::yt_pass ::yt_pass2 ::yt_set ::yt_for ::yt_loop ::yt_branch ::yt_dupuse ::yt_rest ::yt_cmp ::yt_lit ::yt_litint ::yt_mixed ::yt_wide ::yt_obj ::yt_lit_use ::yt_w ::yt_obj_use ::yt_mixed_use ::yt_ovf ::yt_ovf_use
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
# resident set size in KB: /proc where there is one (Linux), `ps` elsewhere (macOS has no /proc)
proc rss {} {
    if {[file readable /proc/self/status]} {
        set f [open /proc/self/status]; set t [read $f]; close $f
        regexp {VmRSS:\s+(\d+)} $t -> kb
    } else {
        set kb [string trim [exec ps -o rss= -p [pid]]]
    }
    return $kb
}
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
# the dead value of an if statement that is an object is released on the edge to the pop (decision 69): one leaked object per iteration is 48 bytes, 1.5 million iterations 70 MB
dt_leak 1000
set r0 [rss]
dt_leak 1500000
set r1 [rss]
set dl [expr {$r1 - $r0}]
puts "dt_leak: RSS grew $dl KB"
if {$dl > 4096} { puts "LEAK in the dead value of an if statement: RSS grew $dl KB"; incr bad }
covreport
exit [expr {$bad ? 1 : 0}]
