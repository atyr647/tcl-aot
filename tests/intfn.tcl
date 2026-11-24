# Driver of tests/intfn.sh.  The compiled procs live in ::fn; a second interpreter, `ref`, has the same definitions without the module.
load {} Fn
uplevel #0 [list source $::env(FN_PROCS)]
interp create ref
ref eval [read [open $::env(FN_PROCS)]]
# finite numbers below 2^63 in magnitude (text forms included): must stay typed
set fits {0 1 -1 0.5 -0.5 1.5 -1.5 2.5 -2.5 0.49999999999999994 -0.49999999999999994 2.4999999999999996 4.5 1e-300 -0.0 0.0
  2147483646 2147483647 2147483648 2147483649 -2147483647 -2147483648 -2147483649 -2147483650 4294967295 4294967296 4294967297 -4294967295 -4294967296 -4294967297 3000000000 -3000000000 6442450944 -6442450944
  2147483646.0 2147483647.0 2147483648.0 2147483649.0 -2147483647.0 -2147483648.0 -2147483649.0 -2147483650.0 2147483647.5 2147483646.5 -2147483647.5 -2147483648.5 -2147483649.5 2147483647.4999
  4294967295.0 4294967296.0 4294967297.0 4294967295.5 4294967296.5 -4294967295.0 -4294967296.0 -4294967297.0 -4294967295.5 -4294967296.5 4e9 -4e9 3e9 -3e9 5e9 -5e9 6442450944.0 -6442450944.0 1e10 -1e10 1.5e10 123456789012.75 -123456789012.75
  9007199254740991 9007199254740992 9007199254740993 -9007199254740993 9007199254740992.0 -9007199254740992.0 4503599627370495.5 4503599627370496.5 -4503599627370495.5 1e15 1e16 -1e16 9.2e18 -9.2e18
  9223372036854775807 -9223372036854775807 -9223372036854775808 9223372036854774784.0 -9223372036854774784.0 9223372036854773760.0 4611686018427387904 4611686018427387904.0 -4611686018427387904.0
  0x10 0x7FFFFFFF 0x80000000 0xFFFFFFFF 0x100000000 0x7FFFFFFFFFFFFFFF " 5" 1e3 010 -0x80000000}
# these need a bignum or an error (or are not numbers): the interpreter's result is what they must give
set others {9223372036854775808.0 -9223372036854775808.0 -9223372036854775809.0 1e19 -1e19 1.8446744073709552e19 3e19 1e300 -1e300 Inf -Inf NaN 1e400 -1e400
  9223372036854775808 -9223372036854775809 18446744073709551616 100000000000000000000 abc {} {1 2} 0x {1e} true}
set bad 0
set ncomp 0
proc call {c} { set r [catch {uplevel #0 $c} v o]; list $r $v [expr {$r == 1 ? [dict get $o -errorcode] : {}}] }
proc rcall {c} { set r [catch {ref eval $c} v o]; list $r $v [expr {$r == 1 ? [dict get $o -errorcode] : {}}] }
set procs {b_int b_wide b_round d_int d_wide d_round d_use w_use r_use i_int i_round o_int t_int t_min loop all}
proc compare {c} {
    set a [call $c]; set b [rcall $c]; incr ::ncomp
    if {$a ne $b} { puts "MISMATCH $c: compiled [list $a] interpreter [list $b]"; incr ::bad }
}
proc sweep {vals {nloop {0 1 5}}} {
    foreach v $vals {
        foreach p {b_int b_wide b_round d_int d_wide d_round d_use w_use r_use i_int i_round o_int t_int t_min all} { compare [list ::fn::$p $v] }
        foreach n $nloop { compare [list ::fn::loop $n $v] }
    }
}
foreach p {l_int l_wide l_round} { compare [list ::fn::$p] }
# first the values that stay typed: finite, and small enough that the arithmetic on the result (a sum, a product by 2, the loop's sums) does not overflow 64 bits either (the
# loop only with values up to 1e12); the counters are read before anything else is run
set safe {}; set tiny {}
foreach v $fits { set a [expr {abs(double($v))}]; if {$a <= 4e18} { lappend safe $v }; if {$a <= 1e12} { lappend tiny $v } }
sweep $safe {}
sweep $safe {}
sweep $tiny {0 1 5}
set d [tbc::hot -dict]
foreach p {b_int b_wide b_round d_int d_wide d_round d_use w_use r_use i_int i_round o_int t_int t_min loop all l_int l_wide l_round} {
    set p ::fn::$p
    if {![dict exists $d $p]} { puts "FAILED: $p was never entered typed"; incr bad; continue }
    if {[dict get $d $p handovers] != 0} { puts "FAILED: $p handed over [dict get $d $p handovers] times: [tbc::hot -top 3]"; incr bad }
}
# then every value, the ones that overflow or need a bignum included
sweep $fits
sweep $others
# the same values again after the compiled procs have run (the objects have been converted by then: a double that was read as text is now a double object)
sweep [concat $fits $others]
foreach v {2147483648.0 -3000000000.0 4294967296.0 1e19} { set x [expr {$v * 1}]; compare [list ::fn::b_int $x]; compare [list ::fn::d_int $x]; compare [list ::fn::b_wide $x]; compare [list ::fn::b_round $x] }
puts "compared $ncomp calls: [expr {$bad ? "FAILED ($bad)" : "ok"}]"
exit [expr {$bad != 0}]
