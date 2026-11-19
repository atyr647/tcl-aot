#!/bin/sh
# Decision 77.  Three rules that keep per-element loops in typed code, checked by what the counters of a -DTBC_COV module say (equal results alone would not show them):
#  - `lappend var a b c` is typed (no hand-over per call: after the first one the boxed code did not enter typed code again, so the rest of the loop ran boxed);
#  - typed code is entered again at a loop head after a hand-over although the proc holds an array in its own table (not used after the head, or still unset) and an integer
#    vector (a list of integers in the frame);
#  - a proc is caller-safe if its callees reach no frame but its own (`upvar 1`), so a typed caller calls it without handing over; one that reaches further (`upvar 2`) is not.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "rescall: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/p.tcl" <<'TCL'
proc rc_fill {n} { set o {}; for {set i 0} {$i < $n} {incr i} { lappend o $i [expr {$i * 2}] x$i }; return $o }
proc rc_up {name} { upvar 1 $name arr; set s 0; foreach k [array names arr] { incr s $arr($k) }; return $s }
proc rc_osr {n} {
    for {set i 0} {$i < $n} {incr i} { set cq($i,0) $i }
    set t [rc_up cq]
    set dl {}
    for {set i 0} {$i < $n} {incr i} { lappend dl [expr {$i * $t}] }
    for {set i 0} {$i < $n} {incr i} { set lev($i) [lindex $dl $i] }
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $lev($i) }
    return [list $t $s [llength $dl]]
}
proc rc_mklev {} { upvar 1 lev lev; set lev(99) 5; return 1 }
proc rc_osr2 {n} {
    for {set i 0} {$i < $n} {incr i} { set cq($i,0) $i }
    set t [rc_up cq]
    rc_mklev
    for {set i 0} {$i < $n} {incr i} { set lev($i) $i }
    set s 0
    for {set i 0} {$i < $n} {incr i} { incr s $lev($i) }
    return [list $t $s $lev(99)]
}
proc rc_inner {nm} { upvar 1 $nm v; incr v; return $v }
proc rc_mid {} { set x 5; rc_inner x; return $x }
proc rc_outer {n} { set x 100; set s 0; for {set i 0} {$i < $n} {incr i} { incr s [rc_mid] }; return [list $x $s] }
proc rc_inner2 {nm} { upvar 2 $nm v; incr v; return $v }
proc rc_mid2 {} { set x 5; rc_inner2 x; return $x }
proc rc_outer2 {n} { set x 100; set s 0; for {set i 0} {$i < $n} {incr i} { incr s [rc_mid2] }; return [list $x $s] }
TCL
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/p.c" Rcall >"$tmp/tr.log" 2>&1 || { echo "rescall: translation failed"; tail -3 "$tmp/tr.log"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Rcall $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "rescall: build failed"; exit 1; }
cat > "$tmp/run.tcl" <<'TCL'
load {} Rcall
source $::env(PROCS)
set src [read [open $::env(PROCS)]]
interp create ref
ref eval $src
set bad 0
proc check {what cond} { if {![uplevel 1 [list expr $cond]]} { puts "FAILED: $what"; incr ::bad } }
proc same {call} { set a [eval $call]; set b [ref eval $call]; check "$call: [list $a] against [list $b]" [expr {$a eq $b}] }
foreach c {{rc_fill 0} {rc_fill 1} {rc_fill 300} {rc_osr 0} {rc_osr 1} {rc_osr 30} {rc_osr2 0} {rc_osr2 5} {rc_osr2 40} {rc_outer 0} {rc_outer 20} {rc_outer2 0} {rc_outer2 20}} { same $c }
set d [tbc::hot -dict]
proc g {d p k} { if {![dict exists $d $p]} { return -1 }; dict get $d $p $k }
# lappend of several values: typed code never hands over
check "rc_fill hands over ([g $d ::rc_fill handovers])" {[g $d ::rc_fill handovers] == 0}
# typed code after the hand-over at the call that links to the caller's variables: entered again at the loop head, once per call that runs the loop (a loop of no iterations has no body to enter: n = 0 does not count)
check "rc_osr resumed [g $d ::rc_osr resumed] times in 2 calls that run the loop (a table array not used after the head, one still unset, a vector from the frame)" {[g $d ::rc_osr resumed] == 2}
# an array the callee created in the frame: the check at the loop head sees it and typed code does not enter (the result is the same as the interpreter's, above)
check "rc_osr2 resumed [g $d ::rc_osr2 resumed] times with an array in the frame that typed code would not know (never expected)" {[g $d ::rc_osr2 resumed] == 0}
# a callee that reaches only its caller: the proc is caller-safe and its typed caller does not hand over; one that reaches further is not and does
check "rc_outer hands over ([g $d ::rc_outer handovers])" {[g $d ::rc_outer handovers] == 0}
check "rc_outer2 must hand over ([g $d ::rc_outer2 handovers])" {[g $d ::rc_outer2 handovers] > 0}
if {$bad} { exit 1 }
puts ok
TCL
out=$(PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "rescall: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "rescall: FAILED"; exit 1; }
echo "rescall: lappend of several values, the entry at a loop head with a table array and a vector, and caller-safe procs with upvar 1 callees: ok"
