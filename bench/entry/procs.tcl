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
