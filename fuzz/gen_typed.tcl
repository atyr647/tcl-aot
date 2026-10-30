# Generates fuzz_procs.tcl (random procs), fuzz_hints.txt and fuzz_calls.tcl in the current directory.  Deterministic for a given seed.
#
#   tcl-aot-sh gen_typed.tcl seed nexpr nloop ncalls nvec nmap
#
# Arithmetic over integers and doubles (fz_), loops (fl_), integer vectors (fv_), integer maps (fm_), programs that mix typed arithmetic with arrays and
# with links made by upvar, global and namespace upvar (fa_), and programs that mix foreach, catch, math functions, calls with omitted default arguments
# and calls into procs that need a frame (fx_).  Driven by fuzz/run.sh.
set seed [expr {$argc > 0 ? [lindex $argv 0] : 7}]
set nexpr [expr {$argc > 1 ? [lindex $argv 1] : 200}]
set nloop [expr {$argc > 2 ? [lindex $argv 2] : 100}]
set ncalls [expr {$argc > 3 ? [lindex $argv 3] : 150}]
expr {srand($seed)}
proc pick {l} { lindex $l [expr {int(rand() * [llength $l])}] }
set ilits {0 1 2 3 7 -1 -5 100 2147483648 4611686018427387904 9223372036854775807}
set dlits {0.5 1.5 2.0 -3.25 1e10 0.1}
proc leaf {vars} {
    global ilits dlits
    set r [expr {rand()}]
    if {$r < 0.6} { return "\$[pick $vars]" }
    if {$r < 0.85} { return [pick $ilits] }
    return [pick $dlits]
}
proc gen {vars depth} {
    if {$depth == 0 || rand() < 0.2} { return [leaf $vars] }
    set r [expr {rand()}]
    if {$r < 0.1} { return "([gen $vars [expr {$depth-1}]] ? [gen $vars [expr {$depth-1}]] : [gen $vars [expr {$depth-1}]])" }
    set op [pick {+ + - - * * / % < <= > >= == !=}]
    return "([gen $vars [expr {$depth-1}]] $op [gen $vars [expr {$depth-1}]])"
}
set p [open fuzz_procs.tcl w]; set h [open fuzz_hints.txt w]
for {set k 0} {$k < $nexpr} {incr k} {
    puts $p "proc fz_$k {a b} { return \[expr {[gen {a b} 4]}\] }"
    puts $h "fz_$k II ID DI DD"
}
for {set k 0} {$k < $nloop} {incr k} {
    set op [pick {+ - * / %}]
    puts $p "proc fl_$k {n a} {\n    set s \$a\n    for {set i 0} {\$i < \$n} {incr i} { set s \[expr {[gen {s i a} 2]}\] }\n    return \$s\n}"
    puts $h "fl_$k II ID"
}
# int-vector programs: a list local built with lrepeat, read and written by index, aliased, re-created, returned or not
set nvec [expr {$argc > 4 ? [lindex $argv 4] : 60}]
proc idx {} { pick {{$i} {($i + 1)} {($i * 2)} {($a)} {(-1)} {($n)} {(($i + $a) % 7)} {0} {2}} }
proc vstmt {} {
    set val [gen {s i a} 1]
    set ix [idx]
    switch [expr {int(rand() * 9)}] {
        0 { return "lset v \[expr {$ix % \$len}\] \[expr {$val}\]" }
        1 { return "lset v \[expr {$ix}\] \[expr {$val}\]" }
        2 { return "set s \[expr {\$s + \[lindex \$v \[expr {$ix % \$len}\]\]}\]" }
        3 { return "set s \[expr {\$s + \[lindex \$v \[expr {$ix}\]\]}\]" }
        4 { return "set w \$v; incr s \[llength \$w\]" }
        5 { return "if {\[lindex \$v \[expr {$ix % \$len}\]\] > [pick {0 1 2}]} { incr s }" }
        6 { return "set v \[lrepeat \$len [pick {0 1 5 -3}]\]" }
        7 { return "incr s \[llength \$v\]; set s \[expr {\$s + \[lindex \$v end\]}\]" }
        8 { return "lset v [pick {0 1 2}] \[expr {$val}\]" }
    }
}
for {set k 0} {$k < $nvec} {incr k} {
    set body {}
    for {set j 0} {$j < 2 + int(rand() * 4)} {incr j} { lappend body "        [vstmt]" }
    set ret [pick {{return $s} {return $v} {return [list $s $v]} {return [list $s [lindex $v 0] [llength $v]]}}]
    puts $p "proc fv_$k {n a} {\n    set len \[expr {\$n % 9 + 1}\]\n    set v \[lrepeat \$len [pick {0 1 2}]\]\n    set s 0\n    for {set i 0} {\$i < \$n} {incr i} {\n[join $body \n]\n    }\n    $ret\n}"
    puts $h "fv_$k II ID"
}
# int-map programs
set nmap [expr {$argc > 5 ? [lindex $argv 5] : 40}]
proc mkey {} { pick {{$i} {[expr {$i % 4}]} {k$a} {x} {007} {[expr {$i * 7 % 5}]} {"k$i"} {$a}} }
proc mstmt {} {
    switch [expr {int(rand() * 8)}] {
        0 - 1 { return "dict incr d [mkey] [pick {1 1 2 -3 4611686018427387}]" }
        2 { return "if {\[dict exists \$d [mkey]\]} { incr s }" }
        3 { return "set s \[expr {\$s + \[dict get \$d [mkey]\]}\]" }
        4 { return "dict for {k v} \$d { incr s \$v }" }
        5 { return "incr s \[dict size \$d\]" }
        6 { return "set e \$d" }
        7 { return "incr s \[string length \[dict keys \$d\]\]" }
    }
}
for {set k 0} {$k < $nmap} {incr k} {
    set body {}
    for {set j 0} {$j < 2 + int(rand() * 4)} {incr j} { lappend body "        [mstmt]" }
    set ret [pick {{return $s} {return $d} {return [list $s $d]} {return [list $s [dict size $d]]}}]
    puts $p "proc fm_$k {n a} {\n    set d \[dict create\]\n    set s 0\n    for {set i 0} {\$i < \$n} {incr i} {\n[join $body \n]\n    }\n    $ret\n}"
    puts $h "fm_$k II ID"
}
# frame-variable programs: arrays with int and string keys and links to globals (upvar #0, global, namespace upvar), mixed with typed arithmetic
set nfa [expr {$argc > 6 ? [lindex $argv 6] : 50}]
proc akey {} { pick {{$i} {$i} {[expr {$i % 5}]} {[expr {$i * 3 - $a}]} {k$a} {x} {05} {5} {-1} {$a} {[expr {$i + 1}]} {"k$i"} {[expr {$i % 3}]}} }
proc aval {} { pick {{$i} {$a} {0} {1} {-7} {9223372036854775807} {abc} {1.5} {[expr {$i * 2}]} {$s} {0x10} {""} {[expr {$a + 0.5}]}} }
proc astmt {} {
    switch [expr {int(rand() * 20)}] {
        0 { return "set a([akey]) [aval]" }
        1 - 2 { return "incr a([akey])" }
        3 { return "incr a([akey]) [pick {1 -1 5 {$i} {$a} 9223372036854775807}]" }
        4 - 5 { return "set s \[expr {\$s + \$a([akey])}\]" }
        6 { return "if {\[info exists a([akey])\]} { incr s }" }
        7 { return "set s \[expr {\$s + \[info exists a([akey])\]}\]" }
        8 { return "incr g" }
        9 { return "incr g [pick {2 -3 {$i} {$a}}]" }
        10 { return "set g \[expr {\$g + \$i}\]" }
        11 { return "incr s \$g" }
        12 { return "incr ga([akey])" }
        13 { return "set ga([akey]) [aval]" }
        14 { return "set s \[expr {\$s + \$ga([akey])}\]" }
        15 { return "set b \$a([akey])" }
        16 { return "set s \[expr {\$s * 3 + \$i}\]" }
        17 { return "set g [aval]" }
        18 { return "unset -nocomplain a([akey])" }
        19 { return "incr s \[array size a\]" }
    }
}
for {set k 0} {$k < $nfa} {incr k} {
    set body {}
    for {set j 0} {$j < 2 + int(rand() * 5)} {incr j} { lappend body "        [astmt]" }
    set head [pick {{upvar #0 fzg g} {global g} {namespace upvar ::fzns g g} {variable g}}]
    set head2 [pick {{upvar #0 fzga ga} {upvar #0 fzga ga} {global ga}}]
    if {$head eq "variable g"} { set head "namespace eval ::fzns {}; namespace upvar ::fzns g g" }
    set ret [pick {{return [list $s [lsort [array get a]] $g]} {return [list $s $g [lsort [array get ga]]]} {return $s}}]
    puts $p "proc fa_$k {n a} {\n    $head\n    $head2\n    set s 0\n    for {set i 0} {\$i < \$n} {incr i} {\n[join $body \n]\n    }\n    $ret\n}"
    puts $h "fa_$k II ID"
}
# programs with arrays that are compiled locals (m, p): element stores, increments, reads and tests that typed code does on a native table, mixed with
# commands that make it write the table into the frame (array names/get/size, unset, a failing read inside catch) and with a call of a proc that has
# such an array of its own (fr_)
set nfr [expr {$argc > 6 ? [lindex $argv 6] : 50}]
puts $p {proc frh_leaf {x} { set t($x) $x; incr t($x) 2; return $t($x) }}
proc rstmt {} {
    switch [expr {int(rand() * 22)}] {
        0 { return "set m([akey]) [aval]" }
        1 - 2 { return "incr m([akey])" }
        3 { return "incr m([akey]) [pick {1 -1 5 {$i} {$a} 9223372036854775807}]" }
        4 - 5 { return "set s \[expr {\$s + \$m([akey])}\]" }
        6 { return "if {\[info exists m([akey])\]} { incr s }" }
        7 { return "set s \[expr {\$s + \[info exists p([akey])\]}\]" }
        8 { return "set p([akey]) [aval]" }
        9 { return "incr p([akey]) [pick {1 2 {$i}}]" }
        10 { return "set s \[expr {\$s * 3 + \$i}\]" }
        11 { return "set t \$m([akey])" }
        12 { return "if {\[catch {set t \$p([akey])} e\]} { incr s 100 }" }
        13 { return "lappend l \[array names m\]" }
        14 { return "incr s \[array size p\]" }
        15 { return "set s \[expr {\$s + \[frh_leaf \$i\]}\]" }
        16 { return "unset -nocomplain p([akey])" }
        17 { return "set m([akey]) \[expr {\$i * \$a}\]" }
        18 { return "set s \[expr {\$s + \$a}\]" }
        19 { return "lappend l \[array get p\]" }
        20 { return "set m(\$s) \$i" }
        21 { return "set s \[string length \$m([akey])\]" }
    }
}
for {set k 0} {$k < $nfr} {incr k} {
    set body {}
    for {set j 0} {$j < 2 + int(rand() * 6)} {incr j} { lappend body "        [rstmt]" }
    set ret [pick {{return $s} {return [list $s $l]} {return [list $s [array get m]]} {return [list $s [lsort [array names m]] [array size p]]} {return [list $s [array names p]]}}]
    puts $p "proc fr_$k {n a} {\n    set s 0\n    set l {}\n    for {set i 0} {\$i < \$n} {incr i} {\n[join $body \n]\n    }\n    $ret\n}"
    puts $h "fr_$k II ID"
}
# programs that mix foreach, catch, math functions, calls with omitted default arguments and calls into procs that need a frame (fx_)
set nfx [expr {$argc > 6 ? [lindex $argv 6] : 50}]
puts $p {proc fxh_sq {x} { expr {$x * $x} }}
puts $p {proc fxh_dflt {a {b 3} {c 0.5}} { expr {$a + $b + $c} }}
puts $p {proc fxh_arr {k} { set t($k) $k; return $t($k) }}
puts $p {proc fxh_glob {k} { global fxg; incr fxg $k; return $fxg }}
puts $p {proc fxh_err {x} { if {$x % 4 == 3} { error boom }; return $x }}
proc fxarg {} { pick {{$i} {$a} {$i} {2} {-1} {$a} {0}} }
proc fxstmt {} {
    switch [expr {int(rand() * 24)}] {
        0 { return "incr s \[fxh_sq [fxarg]\]" }
        1 { return "set d \[expr {\$d + \[fxh_dflt [fxarg]\]}\]" }
        2 { return "set d \[expr {\$d + \[fxh_dflt [fxarg] [fxarg]\]}\]" }
        3 { return "set d \[expr {\$d + \[fxh_dflt [fxarg] [fxarg] 2.5\]}\]" }
        4 { return "incr s \[fxh_arr [fxarg]\]" }
        5 { return "incr s \[fxh_glob 1\]" }
        6 { return "if {\[catch {fxh_err [fxarg]} v\]} { incr s 7 } else { incr s \$v }" }
        7 { return "catch {incr s \[expr {100 / ([fxarg] - [fxarg])}\]}" }
        8 { return "set l \[list \$i \$a 3 -1\]; foreach x \$l { incr s \[expr {\$x * \$i}\] }" }
        9 { return "set l \[list \$i \$a 3 -1 7\]; foreach {x y} \$l { catch {incr s \[expr {\$x - \$y}\]} }" }
        10 { return "set d \[expr {\$d + sqrt(abs([fxarg] + 0.5))}\]" }
        11 { return "catch {set d \[expr {\$d + log([fxarg])}\]}" }
        12 { return "catch {set d \[expr {\$d + acos(\$d)}\]}" }
        13 { return "set d \[expr {\$d + sin(\$d) + pow(abs(\$d), 0.5) + floor(\$d)}\]" }
        14 { return "incr s \[expr {int(\$d) % 7}\]" }
        15 { return "incr s \[expr {round(\$d) + wide(\$d / 3)}\]" }
        16 { return "set d \[expr {\$d + double(\[fxarg\]) + hypot(\$i, \$a) + atan2(\$i, \$a + 1)}\]" }
        17 { return "set d \[expr {\$d + fmod(\$i, \$a)}\]" }
        18 { return "set s \[expr {\$s + \[string length \[string repeat x \[expr {\$i % 4}\]\]\]}\]" }
        19 { return "if {\$d > 1e6} { set d 0.5 }" }
        20 { return "incr s \[expr {abs(\$s) % 1000}\]" }
        21 { return "foreach x {1 2 3} { incr s \$x }" }
        22 { return "catch {error x}; incr s" }
        23 { return "set d \[expr {\$d * 0.5 + \[fxh_sq \$i\]}\]" }
    }
}
for {set k 0} {$k < $nfx} {incr k} {
    set body {}
    for {set j 0} {$j < 2 + int(rand() * 5)} {incr j} { lappend body "        [fxstmt]" }
    puts $p "proc fx_$k {n a} {\n    set s 0\n    set d 0.5\n    for {set i 0} {\$i < \$n} {incr i} {\n[join $body \n]\n    }\n    return \[list \$s \$d\]\n}"
    puts $h "fx_$k II ID"
}
close $p; close $h
set ivals {0 1 -1 2 -2 3 7 -7 10 -100 255 2147483647 2147483648 -2147483648 4294967296 9007199254740991 9007199254740992 9007199254740993 -9007199254740993 4611686018427387904 9223372036854775807 -9223372036854775807 -9223372036854775808}
set dvals {0.5 -0.5 1.5 2.0 -3.25 1e10 1e15 9007199254740992.0 1e-5 0.1 1e308 -1e308 0.0}
set c [open fuzz_calls.tcl w]
proc arg {} {
    global ivals dvals
    set r [expr {rand()}]
    if {$r < 0.55} { return [pick $ivals] }
    if {$r < 0.85} { return "\[dbl [pick $dvals]\]" }
    return [pick $dvals]
}
for {set k 0} {$k < $nexpr} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fz_$k [arg] [arg]}" }
}
for {set k 0} {$k < $nloop} {incr k} {
    for {set j 0} {$j < [expr {$ncalls/3}]} {incr j} { puts $c "lappend calls {fl_$k [expr {int(rand()*14)}] [arg]}" }
}
for {set k 0} {$k < $nvec} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fv_$k [expr {int(rand()*19)}] [arg]}" }
}
for {set k 0} {$k < $nmap} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fm_$k [expr {int(rand()*25)}] [arg]}" }
}
for {set k 0} {$k < $nfx} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {unset -nocomplain ::fxg; set ::fxg 0; fx_$k [expr {int(rand()*12)}] [arg]}" }
}
for {set k 0} {$k < $nfa} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fa_reset; fa_$k [expr {int(rand()*12)}] [arg]}" }
}
for {set k 0} {$k < $nfr} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $c "lappend calls {fr_$k [expr {int(rand()*12)}] [arg]}" }
}
close $c
