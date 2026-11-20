#!/bin/sh
# Decision 80: in a proc with no sign of floating-point numbers an object appended to a native vector (`lappend e [lindex $P $i]`, an integer in its canonical text) is pushed as
# a number with no hand-over, and `lset` of an integer writes over an element that nothing else holds.  The results are compared by the differential test (vb_* procs); this checks,
# in a module built with -DTBC_COV, that vb_drive (a compiled loop of integer lifting steps over a list read from the frame) never hands over, that a list with a double in it
# does hand over (and gives the interpreter's result), and, with the objects counted by the runtime, that the second pass of lset over a list makes no new object.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "vecobj: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/run.tcl" <<'TCL'
load {} Vbtest
source $::env(VB_PROCS)
set bad 0
set r [vb_drive 10 64]
set d [tbc::hot -dict]
# (the driver hands over at its calls of vb_lift, which links to its variable by name, a constant number of times; the lifting step itself never)
foreach {p max} {::vb_drive 2 ::vb_lift 0} {
    if {![dict exists $d $p]} { puts "FAILED: $p not counted"; incr bad; continue }
    if {[dict get $d $p handovers] > $max} { puts "FAILED: $p hands over [dict get $d $p handovers] times"; incr bad }
}
if {[dict get $d ::vb_lift entries] < 20} { puts "FAILED: vb_lift entered typed code [dict get $d ::vb_lift entries] times"; incr bad }
# a list with a double in it: the call hands over, the result is Tcl's
tbc::hot -reset
set l {1 2 3.5 4 5 6 7 8}
set P $l; vb_lift P 0 1 8
set want {}
set e {}; set o {}
foreach i {0 1 2 3} { lappend e [lindex $l $i] }
foreach i {4 5 6 7} { lappend o [lindex $l $i] }
set exp [list]
for {set i 0} {$i < 4} {incr i} { lset e $i [expr {[lindex $e $i] * 3 + 1}] }
for {set i 0} {$i < 4} {incr i} { lset o $i [expr {[lindex $o $i] - [lindex $e [expr {min($i, 3)}]]}] }
set Q $l
for {set i 0} {$i < 4} {incr i} { lset Q [expr {2 * $i}] [lindex $e $i] }
for {set i 0} {$i < 4} {incr i} { lset Q [expr {2 * $i + 1}] [lindex $o $i] }
if {$P ne $Q} { puts "FAILED: double in the list: $P against $Q"; incr bad }
if {![dict exists [tbc::hot -dict] ::vb_lift] || [dict get [tbc::hot -dict] ::vb_lift handovers] < 1} { puts "FAILED: a double in the list did not hand over"; incr bad }
if {$bad} { exit 1 }
puts "ok"
TCL
"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/p.c" Vbtest -hints tests/hints.txt >"$tmp/translate.log" 2>&1 || { echo "vecobj: translation failed"; tail -3 "$tmp/translate.log"; exit 1; }
# (the report says what the translator made of the lifting step: both lists are native vectors)
TBC_REPORT=1 "$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/r.c" Vbrep -hints tests/hints.txt 2>&1 | grep -E '^REPORT ::vb_lift/' | grep -q ' e=A o=A' || { echo "vecobj: FAILED: vb_lift keeps e and o as Tcl lists"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Vbtest $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "vecobj: build failed"; exit 1; }
out=$(TBC_NOLITE=1 VB_PROCS="$PWD/tests/procs.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "vecobj: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "vecobj: FAILED"; exit 1; }
echo "vecobj: objects appended to a native vector stay typed (no hand-over in a loop of lifting steps), a double hands over and gives Tcl's result: ok"
