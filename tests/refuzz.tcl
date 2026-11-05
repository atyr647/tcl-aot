# Differential fuzz of the native matcher (include/tbc_re.h) against Tcl's: random patterns of its subset (and a few outside it, which it must leave to Tcl), random subjects,
# random -start.  The answer of `tbc::re` must be that of `regexp -indices -start`, or "pass".  Run with the shell tests/run.sh builds:
#   shell tests/refuzz.tcl ?seed? ?cases?
# Environment: REFUZZ_VERBOSE=1 prints every case that is passed to Tcl.
load {} Testprocs
set seed [expr {[llength $argv] > 0 ? [lindex $argv 0] : 1}]
set cases [expr {[llength $argv] > 1 ? [lindex $argv 1] : 20000}]
expr {srand($seed)}
proc pick {l} { lindex $l [expr {int(rand() * [llength $l])}] }
proc chance {p} { expr {rand() < $p} }

# ---- the pattern generator
set lits {a b c x y 0 1 2 A Z _ - " " ,  : = / @ ! ~ # % & ' < > ; \" }
set escapedlits {\\. \\\\ \\* \\+ \\? \\| \\( \\) \\[ \\] \\\{ \\\} \\^ \\$ \\- \\/ \\n \\t \\r}
set brackets {{[abc]} {[a-c]} {[^a]} {[^a-c0]} {[a-]} {[]a]} {[\n]} {[^\n]} {[0-9]} {[a-zA-Z_]} {[a-zA-Z_0-9]} {[ \t\n]} {[^"\\]} {[^\\\"]} {[.;,!]} {[-+]} {[eE]}
    {[[:xdigit:]]} {[[:blank:]]} {[[:digit:]]} {[[:space:]]} {[[:alpha:]_]} {[[:upper:]]} {[\d]} {[\s]} {[^\w]} {[a\]]} {[\\]} {[[:alnum:]]}}
set classes {\\d \\s \\w \\D \\S \\W}
proc gen_atom {depth} {
    global lits escapedlits brackets classes
    set r [expr {rand()}]
    if {$r < 0.30} { set a [pick $lits]; if {$a eq "\\"} { set a "\\\\" }; return [expr {[string first $a "\\\"" ] >= 0 && $a eq "\"" ? "\"" : $a}] }
    if {$r < 0.38} { return . }
    if {$r < 0.55} { return [pick $brackets] }
    if {$r < 0.62} { return [pick $classes] }
    if {$r < 0.68} { return [pick $escapedlits] }
    if {$depth < 3 && $r < 0.92} { return "(?:[gen_alt [expr {$depth + 1}]])" }
    if {$r < 0.94} { return "(" }                                ;# unsupported: must pass or error
    return [pick $lits]
}
proc gen_quant {} {
    set r [expr {rand()}]
    if {$r < 0.45} { return "" }
    if {$r < 0.60} { return * }
    if {$r < 0.72} { return + }
    if {$r < 0.82} { return ? }
    if {$r < 0.88} { return \{[expr {int(rand() * 3)}]\} }
    if {$r < 0.93} { set m [expr {int(rand() * 3)}]; return \{$m,[expr {$m + int(rand() * 3)}]\} }
    if {$r < 0.97} { return \{[expr {int(rand() * 3)}],\} }
    return [pick {*? +? ?? {{1,2}?} **}]                          ;# non-greedy, or nonsense: must pass or error
}
proc gen_branch {depth} {
    set n [expr {1 + int(rand() * 3)}]
    set s ""
    for {set i 0} {$i < $n} {incr i} { append s [gen_atom $depth][gen_quant] }
    return $s
}
proc gen_alt {depth} {
    set n [expr {[chance 0.25] ? 2 + int(rand() * 2) : 1}]
    set parts {}
    for {set i 0} {$i < $n} {incr i} { lappend parts [gen_branch $depth] }
    return [join $parts |]
}
proc gen_pattern {} {
    set p [gen_alt 0]
    set r [expr {rand()}]
    if {$r < 0.30} { set p "\\A$p" } elseif {$r < 0.45} { set p "^$p" }
    set r [expr {rand()}]
    if {$r < 0.20} { append p $ } elseif {$r < 0.30} { append p {\Z} }
    return $p
}
# ---- the subjects
set chars {a b c x y 0 1 2 " " - _ . "\n" "\t" A Z , : "\"" "\\" e E + ! ; é €     \U0001F600 ٠ \u00A0 \u2003 \u0416 \u03A9 \u03C9 \u00B2 \u0663 \u2028}
proc gen_subject {} {
    global chars
    set n [expr {int(rand() * 13)}]
    set s ""
    for {set i 0} {$i < $n} {incr i} { append s [pick $chars] }
    return $s
}

set total 0; set native 0; set passed 0; set bad 0; set terr 0; set matched 0; set empties 0
for {set k 0} {$k < $cases} {incr k} {
    set pat [gen_pattern]
    # (each pattern on several subjects: the cached states of the native matcher are used by the later ones)
    for {set j 0} {$j < 6} {incr j} {
        set s [gen_subject]
        set len [string length $s]
        set start [expr {[chance 0.5] ? 0 : int(rand() * ($len + 1))}]
        incr total
        if {[catch {set ok [regexp -indices -start $start -- $pat $s m]} err]} {
            set want "error"
        } else {
            set want [expr {$ok ? "1 [lindex $m 0] [lindex $m 1]" : 0}]
        }
        if {[catch {tbc::re $pat $s $start} got]} { set got "ERR $got" }
        if {$got eq "pass"} {
            incr passed
            if {[info exists ::env(REFUZZ_VERBOSE)]} { puts "pass: [list $pat] [list $s] $start" }
            continue
        }
        incr native
        if {$want ne "0" && $want ne "error"} { incr matched; if {[lindex $want 2] < [lindex $want 1]} { incr empties } }
        if {$want eq "error"} { incr terr; puts "MISMATCH (Tcl rejects the pattern, the native matcher took it): [list $pat] [list $s] start=$start got=$got"; incr bad; continue }
        if {$got ne $want} {
            incr bad
            if {$bad <= 25} { puts "MISMATCH [list $pat] subject=[list $s] start=$start tcl={$want} native={$got}" }
        }
    }
}
# ---- the whole command: switches, -all, -inline, -start, match variables (tbc_regexp_fast against regexp, results and variables)
proc gen_subject2 {} {
    global chars
    if {[chance 0.6]} {
        set alpha {a b c 0 1 " " - "\n" a b}
        set n [expr {int(rand() * 9)}]
        set s ""
        for {set i 0} {$i < $n} {incr i} { append s [pick $alpha] }
        return $s
    }
    return [gen_subject]
}
proc via {cmd opts pat s nv} {
    set names [lrange {v1 v2 v3 v4} 0 [expr {$nv - 1}]]
    foreach n {v1 v2 v3 v4} { catch {unset $n} }
    set r [catch {$cmd {*}$opts -- $pat $s {*}$names} res]
    set vars {}
    foreach n $names { lappend vars [expr {[info exists $n] ? [set $n] : "<unset>"}] }
    return [list $r $res $vars]
}
proc viaTcl {opts pat s nv} {
    set names [lrange {v1 v2 v3 v4} 0 [expr {$nv - 1}]]
    foreach n {v1 v2 v3 v4} { catch {unset $n} }
    set r [catch {regexp {*}$opts -- $pat $s {*}$names} res]
    set vars {}
    foreach n $names { lappend vars [expr {[info exists $n] ? [set $n] : "<unset>"}] }
    return [list $r $res $vars]
}
set total2 0; set native2 0; set bad2 0; set kinds {}
for {set k 0} {$k < $cases / 4} {incr k} {
    set pat [gen_pattern]
    for {set j 0} {$j < 4} {incr j} {
        set s [gen_subject2]
        set len [string length $s]
        set opts {}
        set inline [chance 0.2]
        if {[chance 0.35]} { lappend opts {-all} }
        if {$inline} { lappend opts {-inline} }
        if {[chance 0.4]} { lappend opts {-indices} }
        if {[chance 0.3]} { lappend opts [list -start [expr {[chance 0.1] ? $len + 1 + int(rand() * 2) : int(rand() * ($len + 1))}]] }
        set opts [concat {*}[lsort -command {apply {{a b} {expr {rand() < 0.5 ? -1 : 1}}}} $opts]]
        set nv [expr {$inline ? 0 : int(rand() * 4)}]
        incr total2
        set want [viaTcl $opts $pat $s $nv]
        set got [via tbc::refast $opts $pat $s $nv]
        if {[lindex $got 1] eq "TBC-PASS"} continue
        incr native2
        if {$got ne $want} {
            incr bad2
            if {$bad2 <= 25} { puts "MISMATCH(command) [list $pat] subject=[list $s] opts=[list $opts] nv=$nv tcl={$want} native={$got}" }
        }
    }
}
puts "refuzz commands: $total2 cases, $native2 native, $bad2 mismatches"
incr bad $bad2
puts "refuzz seed $seed: $total cases, $native native ($passed passed to Tcl; $matched matched, $empties of them empty), $bad mismatches"
exit [expr {$bad ? 1 : 0}]
