# Generates fuzz_procs2.tcl and fuzz_calls2.tcl in the current directory: random programs over strings, lists, dicts, arrays, flow control, named
# variables and bit operators.  Deterministic for a given seed.  usage: tcl-aot-sh gen_boxed.tcl seed nprocs ncalls.  Driven by fuzz/run.sh.
set seed [expr {$argc > 0 ? [lindex $argv 0] : 7}]
set nprocs [expr {$argc > 1 ? [lindex $argv 1] : 60}]
set ncalls [expr {$argc > 2 ? [lindex $argv 2] : 40}]
expr {srand($seed)}
proc pick {l} { lindex $l [expr {int(rand() * [llength $l])}] }
# placeholders: @S string-ish variable, @L list-ish variable, @N number-ish variable, @I index, @V literal value, @K key, @W word
proc sub {t} {
    set map {}
    foreach {ph choices} {
        @S {a b c s r $a $b $c}
        @L {a b c l}
        @N {n n n i a b}
        @I {0 1 2 end end-1 -1 99 x 1.5 {} $n}
        @V {{} 0 1 -1 7 abc {a b} 1.5 9223372036854775807 100000000000000000000 x {{x y}} 0x10 {a 1 b 2}}
        @K {a b k x 0 {} $a $s}
        @W {a b x abc {}}
        @OP {+ - * / % & | ^ << >> ** == != < > <= >= eq ne in ni && ||}
    } {
        while {[string first $ph $t] >= 0} {
            set i [string first $ph $t]
            set rep [pick $choices]
            set t [string replace $t $i [expr {$i + [string length $ph] - 1}] [string map {$ "\x01"} $rep]]
        }
    }
    return [string map {"\x01" $} $t]
}
set stmts {
    {lappend r [string index @S @I]}
    {lappend r [string range @S @I @I]}
    {lappend r [string first @W @S] [string last @W @S]}
    {lappend r [string map [list @W @V] @S]}
    {lappend r [string trim @S @W] [string trimleft @S @W] [string trimright @S]}
    {lappend r [string match @W @S] [string match -nocase @W @S]}
    {lappend r [string compare @S @S] [expr {@S eq @S}] [expr {@S ne @S}]}
    {lappend r [string toupper @S] [string tolower @S] [string totitle @S]}
    {lappend r [string length @S] [string is integer -strict @S] [string is alpha @S]}
    {lappend r [string replace @S @I @I @W]}
    {set s [string cat $s @S]}
    {set s @S}
    {append s @S}
    {lappend r [expr {@N @OP @N}]}
    {lappend r [expr {@S @OP @S}]}
    {lappend r [expr {-@N}] [expr {~@N}] [expr {!@N}]}
    {lappend r [expr {@V in @L}] [expr {@V ni @L}]}
    {set n [expr {@N @OP @N}]}
    {incr n}
    {incr n @N}
    {lappend l @V}
    {lappend l @V @V}
    {set l [list {*}@L @V]}
    {set l [linsert @L @I @V]}
    {lappend r [lindex @L @I] [lindex @L @I @I] [llength @L]}
    {lappend r [lrange @L @I @I] [lrange @L 1 end]}
    {lset l @I @V}
    {lset l @I @I @V}
    {lappend r [concat @L @L]}
    {lappend r [lsort @L] [lsearch @L @V]}
    {lappend r [join @L @W] [split @S @W]}
    {dict set d @K @V}
    {dict set d @K @K @V}
    {dict unset d @K}
    {dict append d @K @V}
    {dict lappend d @K @V}
    {dict incr d @K}
    {lappend r [dict get $d @K]}
    {lappend r [dict exists $d @K] [dict exists $d @K @K] [dict size $d]}
    {lappend r [dict get $d @K @K]}
    {set d @L}
    {dict update d @K x { set x @V }}
    {dict with d { lappend r [info exists a] }}
    {set arr(@K) @V}
    {lappend r $arr(@K)}
    {incr arr(@K)}
    {append arr(@K) @V}
    {lappend arr(@K) @V @V}
    {unset arr(@K)}
    {lappend r [info exists arr(@K)] [array exists arr] [array size arr]}
    {array set arr @L}
    {lappend r [lsort [array names arr]]}
    {set nm x; set $nm @V; lappend r [set $nm]}
    {set nm @W; catch {set $nm} m; lappend r $m}
    {incr nm}
    {foreach x @L { lappend r $x }}
    {foreach {x y} @L { lappend r $y$x }}
    {foreach x @L y @L { lappend r $x$y }}
    {foreach x @L { if {$x eq @W} break; lappend r $x }}
    {foreach x @L { if {$x eq @W} continue; lappend r $x }}
    {switch -- @S { a { lappend r A } b - c { lappend r BC } abc { lappend r ABC } default { lappend r D } }}
    {switch -glob -- @S { a* { lappend r A } *b { lappend r B } default { lappend r D } }}
    {if {@S eq @W} { lappend r EQ } elseif {@N > 3} { lappend r GT } else { lappend r ELSE }}
    {catch {error @W} m; lappend r $m}
    {catch {lindex @L @I @I} m; lappend r $m}
    {catch {expr {@N @OP @N}} m o; lappend r $m [dict get $o -code]}
    {for {set i 0} {$i < 3} {incr i} { lappend r $i }}
    {set i 0; while {$i < 3} { incr i; if {$i == 2} continue; lappend r $i }}
    {lappend r [info level] [namespace current]}
    {lappend r [regexp {a.} @S] [regexp -nocase {A.*} @S]}
    {lappend r [string cat {*}@L]}
    {lappend r [list {*}@L {*}@L]}
    {lappend r [lindex {*}@L]}
    {lappend r {*}@L}
    {unset -nocomplain s l n d}
    {set s ""; set l {}; set n 0; set d {}}
    {lappend r [expr @S]}
    {catch @S m; lappend r $m}
}
set pf [open fuzz_procs2.tcl w]
for {set k 0} {$k < $nprocs} {incr k} {
    set body {}
    set cnt [expr {3 + int(rand() * 7)}]
    for {set j 0} {$j < $cnt} {incr j} {
        set st [sub [pick $stmts]]
        # some statements run under catch, so that one error does not hide everything after it
        if {rand() < 0.85} { set st "catch \{$st\} err; lappend r E\$err" }
        lappend body "    $st"
    }
    puts $pf "proc fg_$k {a b c} {\n    set r {}; set s {}; set l {}; set n 0; set d {}; array set arr {}; set i 0\n[join $body \n]\n    return \$r\n}"
}
close $pf
set vals {{} 0 1 -1 7 abc {a b c} {{x y} z} {1 2 3} {a 1 b 2} end 1.5 "\{" "abé" 100000000000000000000 0x10 " " abcabc {x y z} 9223372036854775807 2 3 64 -5}
set cf [open fuzz_calls2.tcl w]
for {set k 0} {$k < $nprocs} {incr k} {
    for {set j 0} {$j < $ncalls} {incr j} { puts $cf "lappend calls [list [list fg_$k [pick $vals] [pick $vals] [pick $vals]]]" }
}
close $cf
