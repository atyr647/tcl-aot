# Programs written the way people write Tcl, with no thought for the compiler: containers hold strings and numbers, are passed to procs and returned,
# and the loops use foreach, dict for, lappend, append, lindex, string commands.  bench/idiom/run.sh times them interpreted and compiled.
proc wordfreq {n} {
    set words {the quick brown fox jumps over the lazy dog and runs away from the big bad wolf}
    set freq {}
    for {set i 0} {$i < $n} {incr i} {
        set w [lindex $words [expr {($i * 7 + $i / 3) % [llength $words]}]]
        dict incr freq $w
    }
    set out {}
    dict for {w c} $freq { lappend out "$w=$c" }
    return [join [lsort $out] ,]
}
proc primes {n} {
    set found {}
    for {set i 2} {$i < $n} {incr i} {
        set ok 1
        foreach p $found {
            if {$p * $p > $i} break
            if {$i % $p == 0} { set ok 0; break }
        }
        if {$ok} { lappend found $i }
    }
    return [llength $found]
}
proc matmul {n} {
    set a {}; set b {}
    for {set i 0} {$i < $n} {incr i} {
        set ra {}; set rb {}
        for {set j 0} {$j < $n} {incr j} { lappend ra [expr {$i + $j}]; lappend rb [expr {$i - $j}] }
        lappend a $ra; lappend b $rb
    }
    set sum 0
    for {set i 0} {$i < $n} {incr i} {
        for {set j 0} {$j < $n} {incr j} {
            set s 0
            for {set k 0} {$k < $n} {incr k} { incr s [expr {[lindex $a $i $k] * [lindex $b $k $j]}] }
            incr sum $s
        }
    }
    return $sum
}
proc records {n} {
    set db {}
    for {set i 0} {$i < $n} {incr i} {
        dict set db $i [dict create name "user$i" age [expr {20 + $i % 50}] tags [list a b [expr {$i % 3}]]]
    }
    set total 0
    foreach id [dict keys $db] {
        set r [dict get $db $id]
        if {[dict get $r age] > 40 && [lindex [dict get $r tags] 2] == 1} { incr total [dict get $r age] }
    }
    return $total
}
proc tokenize {n} {
    set text ""
    for {set i 0} {$i < $n} {incr i} { append text "foo$i = bar + $i * (baz - 3);\n" }
    set count 0; set len [string length $text]; set i 0
    while {$i < $len} {
        set c [string index $text $i]
        if {[string is alpha $c]} {
            while {$i < $len && [string is alnum [string index $text $i]]} { incr i }
            incr count
        } elseif {[string is digit $c]} {
            while {$i < $len && [string is digit [string index $text $i]]} { incr i }
            incr count
        } elseif {$c eq " " || $c eq "\n"} { incr i } else { incr i; incr count }
    }
    return $count
}
proc nbody {n} {
    set x 0.0; set y 1.0; set vx 0.5; set vy 0.0
    for {set i 0} {$i < $n} {incr i} {
        set r2 [expr {$x * $x + $y * $y}]
        set r3 [expr {$r2 * sqrt($r2)}]
        set vx [expr {$vx - $x / $r3 * 0.001}]
        set vy [expr {$vy - $y / $r3 * 0.001}]
        set x [expr {$x + $vx * 0.001}]
        set y [expr {$y + $vy * 0.001}]
    }
    return [format %.6f [expr {$x + $y}]]
}
proc fibmemo {n} {
    array set memo {}
    proc fibm {k} { upvar 1 memo m; if {$k < 2} { return $k }; if {[info exists m($k)]} { return $m($k) }; set v [expr {[fibm [expr {$k-1}]] + [fibm [expr {$k-2}]]}]; set m($k) $v; return $v }
    return [fibm $n]
}
proc bubble {n} {
    set l {}
    for {set i 0} {$i < $n} {incr i} { lappend l [expr {($i * 7919) % 1009}] }
    set len [llength $l]
    for {set i 0} {$i < $len} {incr i} {
        for {set j 0} {$j < $len - $i - 1} {incr j} {
            set a [lindex $l $j]; set b [lindex $l [expr {$j + 1}]]
            if {$a > $b} { lset l $j $b; lset l [expr {$j + 1}] $a }
        }
    }
    return [lrange $l 0 4]
}
proc strbuild {n} {
    set s ""
    for {set i 0} {$i < $n} {incr i} { append s [format %c [expr {97 + $i % 26}]] }
    set vowels 0
    foreach ch [split $s ""] { if {$ch in {a e i o u}} { incr vowels } }
    return [list [string length $s] $vowels [string toupper [string range $s 0 9]]]
}
