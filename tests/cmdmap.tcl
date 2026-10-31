# cmdMap (src/cmdmap.tcl) against the loop over every command it replaced, on random nested command tables, and on a size the loop could not do in time.
source [file join [file dirname [info script]] .. src cmdmap.tcl]
proc reference {pcs cmds} {
    foreach pc $pcs {
        set best {}
        foreach c $cmds { if {[dict get $c codefrom] <= $pc && $pc <= [dict get $c codeto]} { set best [list [dict get $c scriptfrom] [expr {[dict get $c scriptto] - [dict get $c scriptfrom] + 1}]] } }
        set m($pc) $best
    }
    return [lsort [array get m]]
}
# a random table in the interpreter's shape: commands in order of their start, nested ones after the one around them, addresses of instructions of 1 to 5 bytes
proc randomCase {n} {
    set pcs {}; set pc 0
    for {set i 0} {$i < $n} {incr i} { lappend pcs $pc; incr pc [expr {1 + int(rand() * 5)}] }
    set cmds {}
    proc gen {from to depth} {
        upvar cmds cmds
        set at $from
        while {$at < $to} {
            set len [expr {1 + int(rand() * ($to - $at))}]
            set end [expr {$at + $len - 1}]
            if {rand() < 0.2} { incr at; continue }              ;# some stretches belong to no command
            lappend cmds [dict create codefrom $at codeto $end scriptfrom [expr {$at * 3}] scriptto [expr {$end * 3 + 2}]]
            if {$depth < 4 && $len > 3} { gen $at [expr {$end + 1}] [expr {$depth + 1}] }
            set at [expr {$end + 1}]
        }
    }
    gen 0 $pc 0
    return [list $pcs $cmds]
}
expr {srand(12345)}
set bad 0
for {set t 0} {$t < 300} {incr t} {
    lassign [randomCase [expr {1 + int(rand() * 60)}]] pcs cmds
    if {[lsort [cmdMap $pcs $cmds]] ne [reference $pcs $cmds]} { incr bad; puts "FAILED: case $t differs from the loop over all commands" }
}
# no commands, and commands that cover no instruction
if {[cmdMap {} {}] ne {}} { incr bad; puts "FAILED: empty" }
if {[lsort [cmdMap {0 2 4} {}]] ne [lsort {0 {} 2 {} 4 {}}]} { incr bad; puts "FAILED: no commands" }
if {[lsort [cmdMap {0 2 4} [list [dict create codefrom 5 codeto 9 scriptfrom 1 scriptto 2]]]] ne [lsort {0 {} 2 {} 4 {}}]} { incr bad; puts "FAILED: a command past the last instruction" }
# the size of a generated proc: 40000 instructions in 16000 commands, nested twice.  The loop over all commands does 640 million tests (a minute or more); bisection
# does a few hundred thousand steps
set pcs {}; for {set i 0} {$i < 40000} {incr i} { lappend pcs $i }
set cmds [list [dict create codefrom 0 codeto 39999 scriptfrom 0 scriptto 999999]]
for {set i 0} {$i < 8000} {incr i} {
    lappend cmds [dict create codefrom [expr {$i * 5}] codeto [expr {$i * 5 + 4}] scriptfrom [expr {$i * 10}] scriptto [expr {$i * 10 + 9}]]
    lappend cmds [dict create codefrom [expr {$i * 5 + 1}] codeto [expr {$i * 5 + 3}] scriptfrom [expr {$i * 10 + 2}] scriptto [expr {$i * 10 + 7}]]
}
set t0 [clock milliseconds]
array set r [cmdMap $pcs $cmds]
set ms [expr {[clock milliseconds] - $t0}]
if {$r(0) ne {0 10} || $r(2) ne {2 6} || $r(4) ne {0 10} || $r(39999) ne {79990 10}} { incr bad; puts "FAILED: the large table maps to $r(0) $r(2) $r(4) $r(39999)" }
if {$ms > 5000} { incr bad; puts "FAILED: mapping 40000 instructions to 16000 commands took $ms ms (bisection takes well under a second)" }
puts "cmdmap: [expr {$bad ? "FAILED" : "ok"}] (large table in $ms ms)"
exit [expr {$bad != 0}]
