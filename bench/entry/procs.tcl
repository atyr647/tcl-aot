# micro cases: each proc exercises one call shape; the driver loop is interpreted in both modes
proc m_triv {x} { return $x }
proc m_arith {x} { expr {$x * 2 + 1} }
proc m_str {s} { string length $s }
proc m_strops {s} { set n [string length $s]; return [string toupper [string range $s 0 3]] }
proc m_list {l} { lindex $l 0 }
proc m_lappend {n} { set l {}; for {set i 0} {$i < $n} {incr i} { lappend l $i }; return [llength $l] }
proc m_global {} { global g; incr g; return $g }
proc m_upvar {name} { upvar 1 $name v; incr v }
proc m_uplevel {} { uplevel 1 {set u 1} }
proc m_call2 {x} { return [m_triv $x] }
proc m_callproc {x} { return [m_unc $x] }
proc m_unc {x} { uplevel 0 {} ; return $x }
proc m_array {k} { set a($k) 1; return [array size a] }
proc m_dict {d} { dict get [list a $d] a }
proc m_catch {x} { catch {expr {$x + 1}} r; return $r }
proc m_if {x} { if {$x > 3} { return big } elseif {$x > 1} { return mid } else { return small } }
proc m_foreach {l} { set s 0; foreach v [split $l ""] { incr s $v }; return $s }
proc m_format {x} { format %05d $x }
proc m_regexp {s} { regexp {^(\w+)_(\w+)$} $s -> a b; return $b }
proc m_switch {x} { switch -- $x { a { return 1 } b { return 2 } default { return 0 } } }
proc m_split {s} { llength [split $s ,] }
proc m_join {l} { join [split $l ""] - }
proc m_eval {x} { eval [list expr $x + 1] }
proc m_incr {} { set i 0; incr i; incr i; return $i }
proc m_cl {x} { upvar 0 x y; set s 0; for {set i 0} {$i < 3} {incr i} { incr s $y }; return $s }
proc m_lc {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [m_cl $i] }; return $s }
proc m_cp {x} { set s 0; for {set i 0} {$i < 3} {incr i} { incr s $x }; return $s }
proc m_lp {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [m_cp $i] }; return $s }
proc m_lu {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s [m_cu $i] }; return $s }
proc m_cu {x} { return [string length [format %d $x]] }
proc m_e4 {val} {
    if {$val == 0} {return z}
    return [binary format ccccc [expr { ( $val / 52200625) + 33 }] [expr { (($val % 52200625) / 614125) + 33 }] [expr { (($val % 614125) / 7225) + 33 }] [expr { (($val % 7225) / 85) + 33 }] [expr { ( $val % 85) + 33 }]]
}
proc m_e4c {val} { m_e4 $val }
# the lookup and the switch of tclbench's methods program: a loop over a list, `info proc` (typed code hands over there), a script built with linsert and evaluated
namespace eval ::dad { proc test {{x 5} args} { set x } }
set ::b [list ::dad ::none]
proc m_look {method args} {
    foreach anc $::b {
        if {[llength [info proc ${anc}::$method]]} {
            return [eval [linsert $args 0 ${anc}::$method]]
        }
    }
}
proc m_sw {method args} {
    switch $method {
        a {}
        b {}
        test {return [eval [linsert $args 0 ::dad::test]]}
    }
}
# a loop that hands over to boxed code in every round (info proc), with 0, 2 and 6 rounds of arithmetic as typed work before it (the weights of liteWeight: 150, 1150, 3150; the entry
# stub pays for itself above about 950, decision 51)
proc m_hn0 {l} { set s 0; foreach x $l { if {[llength [info proc nonesuch]]} { incr s } }; return $s }
proc m_hn2 {l} { set s 0; foreach x $l { set s [expr {$s + $x * 3 + $x * 5}]; if {[llength [info proc nonesuch]]} { incr s } }; return $s }
proc m_hn6 {l} { set s 0; foreach x $l { set s [expr {$s + $x * 3 + $x * 5 + $x * 7 + $x * 9 + $x * 11 + $x * 13}]; if {[llength [info proc nonesuch]]} { incr s } }; return $s }
