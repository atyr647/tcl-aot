# The kernels of bench/vs-c.sh: the same computation in Tcl (here) and in C (kernels.c).  They are the programs people reach for C for.
proc k_arith {n} { set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {($s + $i * 3) % 1000003}] }; return $s }
proc k_collatz {n} { set best 0; for {set i 1} {$i < $n} {incr i} { set x $i; set c 0; while {$x != 1} { if {$x % 2} { set x [expr {3 * $x + 1}] } else { set x [expr {$x / 2}] }; incr c }; if {$c > $best} { set best $c } }; return $best }
proc k_fib {n} { if {$n < 2} { return $n }; return [expr {[k_fib [expr {$n - 1}]] + [k_fib [expr {$n - 2}]]}] }
proc k_sieve {n} {
    for {set i 0} {$i <= $n} {incr i} { set p($i) 1 }
    for {set i 2} {$i * $i <= $n} {incr i} { if {$p($i)} { for {set j [expr {$i * $i}]} {$j <= $n} {incr j $i} { set p($j) 0 } } }
    set c 0; for {set i 2} {$i <= $n} {incr i} { if {$p($i)} { incr c } }; return $c
}
proc k_mat {n} {
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set a($i,$j) [expr {$i + $j}]; set b($i,$j) [expr {$i - $j}] } }
    set t 0
    for {set i 0} {$i < $n} {incr i} { for {set j 0} {$j < $n} {incr j} { set s 0; for {set k 0} {$k < $n} {incr k} { incr s [expr {$a($i,$k) * $b($k,$j)}] }; incr t $s } }
    return $t
}
proc k_hist {n} { for {set i 0} {$i < $n} {incr i} { incr h([expr {($i * 7) % 1000}]) }; set s 0; for {set k 0} {$k < 1000} {incr k} { incr s [expr {$h($k) * $k}] }; return $s }
proc k_dotd {n} { for {set i 0} {$i < $n} {incr i} { set x($i) [expr {$i * 0.5}]; set y($i) [expr {$i / 4.0}] }; set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + $x($i) * $y($i)}] }; return $s }
proc k_lcs {n} {
    set x {}; set y {}
    for {set i 0} {$i < $n} {incr i} { append x [string index abcd [expr {($i * 7) % 4}]]; append y [string index abcd [expr {($i * 5 + 1) % 4}]] }
    for {set i 0} {$i <= $n} {incr i} { for {set j 0} {$j <= $n} {incr j} { set d($i,$j) 0 } }
    for {set i 1} {$i <= $n} {incr i} { for {set j 1} {$j <= $n} {incr j} {
        if {[string index $x [expr {$i - 1}]] eq [string index $y [expr {$j - 1}]]} { set d($i,$j) [expr {$d([expr {$i - 1}],[expr {$j - 1}]) + 1}] } else { set u $d([expr {$i - 1}],$j); set l $d($i,[expr {$j - 1}]); set d($i,$j) [expr {$u > $l ? $u : $l}] } } }
    return $d($n,$n)
}
proc k_lsum {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l [expr {$i * 3 % 1001}] }; set s 0; for {set i 0} {$i < $n} {incr i} { incr s [lindex $l $i] }; return $s }
proc k_lfor {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l [expr {$i * 7 % 1009}] }; set s 0; foreach v $l { if {$v > 500} { incr s $v } }; return $s }
proc k_lset {n} { set l [lrepeat $n 0]; for {set i 0} {$i < $n} {incr i} { lset l $i [expr {$i * $i % 997}] }; set s 0; for {set i 1} {$i < $n} {incr i} { incr s [expr {[lindex $l $i] - [lindex $l [expr {$i - 1}]]}] }; return $s }
proc k_dict {n} { set d {}; for {set i 0} {$i < $n} {incr i} { dict incr d [expr {$i * 13 % 5000}] }; set s 0; dict for {k v} $d { incr s [expr {$k * $v}] }; return $s }
proc k_str {n} { set s ""; for {set i 0} {$i < $n} {incr i} { append s [string index abcdefghij [expr {$i % 10}]] }; set c 0; for {set i 0} {$i < $n} {incr i} { if {[string index $s $i] eq "e"} { incr c } }; return [list $c [string length $s]] }

