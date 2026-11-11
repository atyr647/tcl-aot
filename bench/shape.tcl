# The same toy kernel (move n entities for t ticks with wall bounce on a grid, fixed-point integers) written three ways, to see what shape of Tcl compiles
# well.  The result is a checksum, the same for every version.  Style A keeps its state in namespace variables, one call per tick; style B does the whole
# run in one proc on local lists of integers; style C on local arrays with integer keys.  tests/localvec.sh fails if style B gets slower than the interpreter
# again (it did: a lset in one branch of an `if` copied the whole vector on every run through that branch).
namespace eval ns {
    variable X {} Y {} VX {} VY {} WALL {} W 0 N 0
    proc init {n w} {
        variable X; variable Y; variable VX; variable VY; variable WALL; variable W; variable N
        set N $n; set W $w; set X {}; set Y {}; set VX {}; set VY {}; set WALL {}
        for {set i 0} {$i < $n} {incr i} {
            lappend X [expr {(($i*37) % ($w-2) + 1)*64+10}]; lappend Y [expr {(($i*91) % ($w-2) + 1)*64+20}]
            lappend VX [expr {($i % 5) - 2}]; lappend VY [expr {(($i*3) % 5) - 2}]
        }
        for {set c 0} {$c < $w*$w} {incr c} {lappend WALL [expr {($c*2654435761 >> 7) % 100 < 12 || $c % $w == 0 || $c % $w == $w-1 || $c < $w || $c >= $w*($w-1)}]}
    }
    proc step {} {
        variable X; variable Y; variable VX; variable VY; variable WALL; variable W; variable N
        for {set i 0} {$i < $N} {incr i} {
            set nx [expr {[lindex $X $i]+[lindex $VX $i]}]; set ny [expr {[lindex $Y $i]+[lindex $VY $i]}]
            if {[lindex $WALL [expr {($ny >> 6)*$W + ($nx >> 6)}]]} {
                lset VX $i [expr {-[lindex $VX $i]}]; lset VY $i [expr {-[lindex $VY $i]}]
            } else {lset X $i $nx; lset Y $i $ny}
        }
    }
    proc runA {ticks} {
        variable X; variable Y
        for {set t 0} {$t < $ticks} {incr t} {step}
        set s 0; foreach x $X y $Y {set s [expr {($s*31 + $x*7 + $y*13) & 0xFFFFFFFF}]}
        return $s
    }
}
proc runB {n w ticks} {
    set X {}; set Y {}; set VX {}; set VY {}; set WALL {}
    for {set i 0} {$i < $n} {incr i} {
        lappend X [expr {(($i*37) % ($w-2) + 1)*64+10}]; lappend Y [expr {(($i*91) % ($w-2) + 1)*64+20}]
        lappend VX [expr {($i % 5) - 2}]; lappend VY [expr {(($i*3) % 5) - 2}]
    }
    for {set c 0} {$c < $w*$w} {incr c} {lappend WALL [expr {($c*2654435761 >> 7) % 100 < 12 || $c % $w == 0 || $c % $w == $w-1 || $c < $w || $c >= $w*($w-1)}]}
    for {set t 0} {$t < $ticks} {incr t} {
        for {set i 0} {$i < $n} {incr i} {
            set nx [expr {[lindex $X $i]+[lindex $VX $i]}]; set ny [expr {[lindex $Y $i]+[lindex $VY $i]}]
            if {[lindex $WALL [expr {($ny >> 6)*$w + ($nx >> 6)}]]} {
                lset VX $i [expr {-[lindex $VX $i]}]; lset VY $i [expr {-[lindex $VY $i]}]
            } else {lset X $i $nx; lset Y $i $ny}
        }
    }
    set s 0; foreach x $X y $Y {set s [expr {($s*31 + $x*7 + $y*13) & 0xFFFFFFFF}]}
    return $s
}
proc runC {n w ticks} {
    for {set i 0} {$i < $n} {incr i} {
        set X($i) [expr {(($i*37) % ($w-2) + 1)*64+10}]; set Y($i) [expr {(($i*91) % ($w-2) + 1)*64+20}]
        set VX($i) [expr {($i % 5) - 2}]; set VY($i) [expr {(($i*3) % 5) - 2}]
    }
    for {set c 0} {$c < $w*$w} {incr c} {set WALL($c) [expr {($c*2654435761 >> 7) % 100 < 12 || $c % $w == 0 || $c % $w == $w-1 || $c < $w || $c >= $w*($w-1)}]}
    for {set t 0} {$t < $ticks} {incr t} {
        for {set i 0} {$i < $n} {incr i} {
            set nx [expr {$X($i)+$VX($i)}]; set ny [expr {$Y($i)+$VY($i)}]
            if {$WALL([expr {($ny >> 6)*$w + ($nx >> 6)}])} {
                set VX($i) [expr {-$VX($i)}]; set VY($i) [expr {-$VY($i)}]
            } else {set X($i) $nx; set Y($i) $ny}
        }
    }
    set s 0
    for {set i 0} {$i < $n} {incr i} {set s [expr {($s*31 + $X($i)*7 + $Y($i)*13) & 0xFFFFFFFF}]}
    return $s
}
