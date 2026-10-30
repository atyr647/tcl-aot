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
