# The command each instruction belongs to.  `pcs` is the list of the instruction addresses of a proc in ascending order, `cmds` the interpreter's table of its
# commands (a list of dicts with codefrom, codeto, scriptfrom, scriptto, in the order the table gives them: a command starts before the commands inside it).
# The result maps every address to {scriptfrom length} of the innermost command that covers it, the last one in the table's order, or {} when none does.
#
# Each command's first instruction is found by bisection and the addresses it covers are then visited once, so the work is the size of the ranges (nesting depth
# times the number of instructions) and not instructions times commands: a generated proc of 70000 lines, with 100000 commands, took half an hour with a loop over
# all commands for every instruction.
proc cmdMap {pcs cmds} {
    set npcs [llength $pcs]
    foreach pc $pcs { set m($pc) {} }
    foreach c $cmds {
        set cf [dict get $c codefrom]; set ct [dict get $c codeto]
        set val [list [dict get $c scriptfrom] [expr {[dict get $c scriptto] - [dict get $c scriptfrom] + 1}]]
        set lo 0; set hi $npcs
        while {$lo < $hi} { set mid [expr {($lo + $hi) / 2}]; if {[lindex $pcs $mid] < $cf} { set lo [expr {$mid + 1}] } else { set hi $mid } }
        for {set i $lo} {$i < $npcs} {incr i} { set pc [lindex $pcs $i]; if {$pc > $ct} break; set m($pc) $val }
    }
    return [array get m]
}
