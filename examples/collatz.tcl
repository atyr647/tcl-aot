# Longest Collatz chain below a limit: integer arithmetic in a loop, and a proc that calls another.

proc steps {n} {
    set count 0
    while {$n != 1} {
        if {$n % 2 == 0} { set n [expr {$n / 2}] } else { set n [expr {3 * $n + 1}] }
        incr count
    }
    return $count
}

proc longest {limit} {
    set best 0
    set arg 1
    for {set i 1} {$i < $limit} {incr i} {
        set s [steps $i]
        if {$s > $best} { set best $s; set arg $i }
    }
    return [list $arg $best]
}
