# Oracle and driver of the conversion helper test (tests/intfn.sh): the doubles (the powers of two from 2^0 to 2^70 and their neighbours one ulp either side, negatives, +-0, halves,
# NaN, infinities, and random bit patterns), the helper program's answers, and the interpreter's int(), wide() and round() of each.
# argv: the helper program, then "wide" (this machine's long) or "narrow" (the program was built with -DTBC_EMU_LONG32)
lassign $argv prog mode
proc bitsOf {d} { binary scan [binary format Q $d] H16 h; return $h }
proc dblOf {h} { binary scan [binary format H16 $h] Q d; return $d }
proc nbr {h delta} { return [format %016x [expr {(wide("0x$h") + $delta) & 0xFFFFFFFFFFFFFFFF}]] }
set hs {}
for {set e 0} {$e <= 70} {incr e} {
    set h [bitsOf [expr {2.0 ** $e}]]
    foreach d {-1 0 1} { lappend hs [nbr $h $d] [nbr [bitsOf [expr {-(2.0 ** $e)}]] $d] }
}
foreach d {0.0 -0.0 0.5 -0.5 1.5 -1.5 2.5 -2.5 0.49999999999999994 -0.49999999999999994 2147483647.5 -2147483648.5 2147483648.5 4294967295.5 4294967296.5 4503599627370495.5 -4503599627370495.5 4503599627370496.5 9007199254740991.0 9007199254740992.0 9007199254740993.0 1e19 -1e19 1.8446744073709552e19 3e19 1e300 -1e300 9.2e18 -9.2e18 9223372036854774784.0 -9223372036854774784.0 3000000000.0 -3000000000.0 4e9 -1e10} { lappend hs [bitsOf $d] }
lappend hs 7ff0000000000000 fff0000000000000 7ff8000000000000 fff8000000000000 7ff8000000000001 7ff0000000000001 7fffffffffffffff ffffffffffffffff 0000000000000001 000fffffffffffff 7fefffffffffffff ffefffffffffffff
expr {srand(12345)}
for {set i 0} {$i < 20000} {incr i} { lappend hs [format %016x [expr {(int(rand() * 4294967296.0) << 32 | int(rand() * 4294967296.0))}]] }
for {set i 0} {$i < 20000} {incr i} {   ;# random doubles of magnitude 2^40 to 2^66, with a random fraction part where there is one
    set d [expr {(rand() + 0.5) * 2.0 ** (40 + int(rand() * 27)) * (rand() < 0.5 ? -1 : 1)}]
    lappend hs [bitsOf $d]
}
set inf [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] intfn_cvt_in.[pid]]
set fh [open $inf w]; puts $fh [join $hs \n]; close $fh
set got [split [string trim [exec $prog < $inf]] \n]; file delete $inf
if {[llength $got] != [llength $hs]} { puts "FAILED: [llength $got] answers for [llength $hs] values"; exit 1 }
proc s32 {w} { set u [expr {$w & 0xFFFFFFFF}]; expr {$u >= 0x80000000 ? $u - 0x100000000 : $u} }
set bad 0; set n 0; set ho {int 0 wide 0 round 0}; set tot 0
foreach h $hs l $got {
    lassign $l bits ia a ib b ic c
    set d [dblOf $h]
    incr n
    set fin [expr {$d == $d && abs($d) != Inf}]
    # int() and wide(): any finite double gives a result; the error for NaN and infinity is the boxed code's
    if {$fin} {
        set ew [expr {wide($d)}]
        set ei [expr {$mode eq "narrow" ? [s32 $ew] : int($d)}]
        if {$mode eq "wide" && $ei != $ew} { puts "ORACLE: int != wide for $h"; incr bad }
        if {!$ia || $a != $ei} { puts "BAD int($d) bits $h: helper ok=$ia $a, interpreter $ei"; incr bad }
        if {!$ib || $b != $ew} { puts "BAD wide($d) bits $h: helper ok=$ib $b, interpreter $ew"; incr bad }
        # round(): exact integer; the helper must give it whenever it is below 2^63 in magnitude (and may hand over at -2^63 and beyond)
        set er [expr {round($d)}]
        if {abs($er) < 9223372036854775808} {
            if {!$ic || $c != $er} { puts "BAD round($d) bits $h: helper ok=$ic $c, interpreter $er"; incr bad }
        } elseif {$ic && $c != $er} { puts "BAD round($d) bits $h: helper gave $c, interpreter $er (a bignum)"; incr bad }
        if {$ic == 0} { dict incr ho round }
    } else {
        if {$ia || $ib || $ic} { puts "BAD bits $h (NaN or infinity): helper ok=$ia $ib $ic, must hand over"; incr bad }
        foreach f {int wide round} { if {![catch {expr "${f}(\$d)"} m]} { puts "ORACLE: $f($d) did not fail"; incr bad } }
    }
}
puts "intfn_cvt ($mode long): $n doubles, int/wide/round compared with the interpreter: [expr {$bad ? "FAILED ($bad)" : "ok"}] (round handed over [dict get $ho round] times: values of 2^63 and more, -2^63, infinity, NaN)"
exit [expr {$bad != 0}]
