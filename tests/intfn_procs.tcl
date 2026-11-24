namespace eval ::fn {}
# B: the argument as it comes (an object)
proc ::fn::b_int {x} { return [expr {int($x)}] }
proc ::fn::b_wide {x} { return [expr {wide($x)}] }
proc ::fn::b_round {x} { return [expr {round($x)}] }
# D: a double in a typed local
proc ::fn::d_int {x} { set d [expr {double($x)}]; return [expr {int($d)}] }
proc ::fn::d_wide {x} { set d [expr {double($x)}]; return [expr {wide($d)}] }
proc ::fn::d_round {x} { set d [expr {double($x)}]; return [expr {round($d)}] }
# what later operations see of the result
proc ::fn::d_use {x} { set d [expr {double($x)}]; set i [expr {int($d)}]; return [list [expr {$i + 1}] [expr {$i * 2}] [expr {$i < 0}] [expr {int($i)}] [expr {wide($i) - $i}] [expr {$i <= $i + 1}] [expr {$i % 7}] [expr {$i >> 3}] [expr {$i & 0xFF}]] }
proc ::fn::w_use {x} { set d [expr {double($x)}]; set i [expr {wide($d)}]; return [list [expr {$i + 1}] [expr {$i * 2}] [expr {$i < 0}] [expr {int($i)}] [expr {$i - $d}] [expr {$i % 7}] [expr {$i >> 3}] [expr {$i & 0xFF}]] }
proc ::fn::r_use {x} { set d [expr {double($x)}]; set i [expr {round($d)}]; return [list [expr {$i + 1}] [expr {$i * 2}] [expr {$i < 0}] [expr {int($i)}] [expr {wide($i) - $i}] [expr {$i % 7}] [expr {$i >> 3}]] }
# I: an integer in a typed local (the result of wide() or round()), through int(), wide() and round()
proc ::fn::i_int {x} { set d [expr {double($x)}]; set w [expr {wide($d)}]; return [list [expr {int($w)}] [expr {wide($w)}] [expr {round($w)}]] }
proc ::fn::i_round {x} { set d [expr {double($x)}]; set w [expr {round($d)}]; return [list [expr {int($w)}] [expr {wide($w)}] [expr {round($w)}]] }
# the integer as an object (the value of an argument that is an integer), then a typed sum
proc ::fn::o_int {x} { set s [expr {$x + 0}]; return [list [expr {int($s)}] [expr {wide($s)}] [expr {round($s)}]] }
# a tagged number: an integer or a double, as max() of both gives it
proc ::fn::t_int {x} { set d [expr {double($x)}]; set m [expr {max($d, 1)}]; return [list [expr {int($m)}] [expr {wide($m)}] [expr {round($m)}]] }
proc ::fn::t_min {x} { set d [expr {double($x)}]; set m [expr {min($d, 5000000000)}]; return [list [expr {int($m)}] [expr {wide($m)}] [expr {round($m)}]] }
# literals
proc ::fn::l_int {} { return [list [expr {int(3000000000)}] [expr {int(-3000000000)}] [expr {int(4294967296)}] [expr {int(2147483648)}] [expr {int(-2147483649)}] [expr {int(3000000000.0)}] [expr {int(-3000000000.5)}] [expr {int(4e9)}] [expr {int(9.2e18)}]] }
proc ::fn::l_wide {} { return [list [expr {wide(3000000000)}] [expr {wide(-3000000000)}] [expr {wide(4294967296)}] [expr {wide(3000000000.0)}] [expr {wide(-3000000000.5)}] [expr {wide(4e9)}] [expr {wide(9.2e18)}]] }
proc ::fn::l_round {} { return [list [expr {round(0.5)}] [expr {round(-0.5)}] [expr {round(2147483647.5)}] [expr {round(-2147483648.5)}] [expr {round(3000000000.5)}] [expr {round(4e9)}] [expr {round(9.2e18)}]] }
# the loops of the engine: int() of a double in a loop, a sum of its results
proc ::fn::loop {n x} { set s 0; set d [expr {double($x)}]; for {set i 0} {$i < $n} {incr i} { incr s [expr {int($d * $i)}]; incr s [expr {round($d / ($i + 1))}]; incr s [expr {wide($d - $i)}] }; return $s }
proc ::fn::all {x} { return [list [b_int $x] [b_wide $x] [b_round $x] [d_int $x] [d_wide $x] [d_round $x]] }
