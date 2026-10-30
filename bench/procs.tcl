# Benchmark procs: loops over arrays, over variables reached through links (upvar, global, namespace variables) and over plain integers.
# bench/run.sh runs them with the interpreter alone and with the compiled module.

proc arr_sieve {n} {
    for {set i 0} {$i <= $n} {incr i} { set s($i) 1 }
    for {set i 2} {$i * $i <= $n} {incr i} {
        if {$s($i)} {
            for {set j [expr {$i * $i}]} {$j <= $n} {incr j $i} { set s($j) 0 }
        }
    }
    set c 0
    for {set i 2} {$i <= $n} {incr i} { incr c $s($i) }
    return $c
}

proc arr_hist {n} {
    for {set i 0} {$i < $n} {incr i} { incr h([expr {$i % 17}]) }
    set t 0
    foreach k [array names h] { incr t $h($k) }
    return $t
}

proc arr_fib {n} {
    set f(0) 0
    set f(1) 1
    for {set i 2} {$i <= $n} {incr i} {
        set f($i) [expr {($f([expr {$i - 1}]) + $f([expr {$i - 2}])) % 1000003}]
    }
    return $f($n)
}

proc arr_mat {n} {
    for {set i 0} {$i < $n} {incr i} {
        for {set j 0} {$j < $n} {incr j} {
            set a($i,$j) [expr {$i + $j}]
            set b($i,$j) [expr {$i - $j}]
        }
    }
    set tr 0
    for {set i 0} {$i < $n} {incr i} {
        for {set j 0} {$j < $n} {incr j} {
            set s 0
            for {set k 0} {$k < $n} {incr k} { incr s [expr {$a($i,$k) * $b($k,$j)}] }
            incr tr $s
        }
    }
    return $tr
}

proc ups_count {name n} {
    upvar 1 $name x
    for {set i 0} {$i < $n} {incr i} { incr x }
}

proc ups_run {n} {
    set cnt 0
    ups_count cnt $n
    return $cnt
}

proc glob_loop {n} {
    global gcount
    set gcount 0
    for {set i 0} {$i < $n} {incr i} { incr gcount $i }
    return $gcount
}

namespace eval nn {
    variable cnt 0
    variable tbl

    proc bump {n} {
        variable cnt
        for {set i 0} {$i < $n} {incr i} { incr cnt }
        return $cnt
    }

    proc fill {n} {
        variable tbl
        for {set i 0} {$i < $n} {incr i} { set tbl($i) [expr {$i * 2}] }
        set t 0
        for {set i 0} {$i < $n} {incr i} { incr t $tbl($i) }
        return $t
    }
}

proc int_loop {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { set s [expr {($s + $i * 7) % 1000003}] }
    return $s
}

# calls between procs, math functions, foreach, string commands and the constructs typed code does not take yet

proc sq {x} { expr {$x * $x} }
proc addd {a {b 10}} { expr {$a + $b} }
proc idx {a} { set t($a) $a; return $t($a) }

proc call_small {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s [sq $i] }
    return $s
}

proc call_default {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s [addd $i] }
    return $s
}

proc call_frame {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s [idx $i] }
    return $s
}

proc math_funcs {n} {
    set s 0.0
    for {set i 1} {$i < $n} {incr i} { set s [expr {$s + sqrt($i) + double($i % 7)}] }
    return $s
}

proc math_int {n} {
    set s 0
    for {set i 1} {$i < $n} {incr i} { incr s [expr {int($i * 0.5)}] }
    return $s
}

proc list_foreach {n} {
    set l {}
    for {set i 0} {$i < 1000} {incr i} { lappend l $i }
    set s 0
    for {set k 0} {$k < $n} {incr k} { foreach x $l { incr s $x } }
    return $s
}

proc list_index {n} {
    set l {}
    for {set i 0} {$i < 1000} {incr i} { lappend l $i }
    set s 0
    for {set k 0} {$k < $n} {incr k} {
        for {set i 0} {$i < 1000} {incr i} { incr s [lindex $l $i] }
    }
    return $s
}

proc str_ops {n} {
    set s 0
    set str "hello world"
    for {set i 0} {$i < $n} {incr i} { incr s [string length $str]; incr s [string first o $str] }
    return $s
}

proc sw_loop {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        switch -- [expr {$i % 4}] { 0 { incr s 1 } 1 { incr s 2 } 2 { incr s 3 } default { incr s 4 } }
    }
    return $s
}

proc catch_loop {n} {
    set s 0
    for {set i 0} {$i < $n} {incr i} {
        if {[catch {expr {$i % 5}} r]} { incr s } else { incr s $r }
    }
    return $s
}
