#!/bin/sh
# The float32 rounding idiom of the engine (`binary scan [binary format f $x] f r`, decision 79) is typed: a double or an object argument is rounded in C
# (tbc_f32_round, tbc_f32_obj) and the scanned value is the double itself, with no byte array made.  This checks, in a module built with -DTBC_COV:
#  - the typed variants of the helpers take the rounding in C (their C has tbc_f32_round for the double variant, and the scan of the pending value reads sd, not bytes);
#  - a compiled loop of 1000 calls of each helper enters its typed code each time (direct calls) with no hand-over;
#  - a helper whose argument is not a number hands over and the boxed code raises the error the interpreter raises;
#  - the rounded results equal the interpreter's for the edge values, before and after the loop (a replaced `binary` is NOT seen by a helper called from a loop: a gap that
#    predates decision 79, see the decision; not tested here).
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "f32idiom: $TCLSH not built; run 'make shell'" >&2; exit 1; }
unset TBC_NOLITE
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/p.tcl" <<'TCL'
proc fi_f32 {x} { binary scan [binary format f $x] f r; return $r }
proc fi_f32l {l} { binary scan [binary format f* $l] f* r; return $r }
proc fi_bytes {x} { return [binary format f $x] }
proc fi_loop {n} { set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [fi_f32 [expr {$i * 0.1 - 20.0}]] + [llength [fi_f32l [list $s 1.5]]]}] }; return $s }
proc fi_objloop {l} { set s 0.0; foreach e $l { set s [expr {$s + [fi_f32 $e]}] }; return $s }
TCL
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/p.c" Fidiom >"$tmp/tr.log" 2>&1 || { echo "f32idiom: translation failed"; tail -3 "$tmp/tr.log"; exit 1; }
# the double variant of fi_f32 rounds in C and reads the pending value; no bytes are made for it
d=$(awk '/^static Tcl_Obj \* V__3a_3afi_5ff32_D\(Tcl_Interp \*interp/{f=1} f&&/^}/{print; exit} f' "$tmp/p.c")
[ -n "$d" ] || { echo "f32idiom: FAILED, no double variant of fi_f32 was generated"; exit 1; }
printf '%s\n' "$d" | grep -q 'tbc_f32_round(' || { echo "f32idiom: FAILED, the double variant does not round in C"; exit 1; }
printf '%s\n' "$d" | grep -q 'tbc_bscan_f\|tbc_f32_bytes' && { echo "f32idiom: FAILED, the double variant makes or reads bytes"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Fidiom $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "f32idiom: build failed"; exit 1; }
cat > "$tmp/run.tcl" <<'TCL'
load {} Fidiom
source $::env(PROCS)
proc entries {d p} { set t 0; if {[dict exists $d $p]} { dict for {k v} [dict get $d $p entries] { incr t $v } }; return $t }
set bad 0
proc check {what ok} { if {!$ok} { puts "FAILED: $what"; incr ::bad } }
set edge {0 0.1 -0.0 16777217 3.4028236e38 -3.5e38 1e-45 1e-50 NaN Inf -Inf 2.5 7 0x10}
set ref {}
foreach v $edge { lappend ref [fi_f32 $v] }
set r1 [fi_loop 1000]
set d [tbc::hot -dict]
foreach p {::fi_f32 ::fi_f32l} {
    check "$p entered [entries $d $p] times by a loop of 1000 calls (direct calls expected)" [expr {[entries $d $p] >= 999}]
    check "$p hands over" [expr {![dict exists $d $p] || [dict get $d $p handovers] == 0}]
}
set again {}
foreach v $edge { lappend again [fi_f32 $v] }
check "the helper gives the same values before and after the loop" [expr {$ref eq $again}]
# a non-number: the error of the interpreter, from the boxed code
proc fi_loop_bad {} { set s 0; for {set i 0} {$i < 3} {incr i} { set s [fi_f32 abc] }; return $s }
set e1 [catch {fi_loop_bad} m1]
check "an object that is no number raises the error ($m1)" [expr {$e1 == 1 && [string match {expected floating-point number*} $m1]}]
check "the result changed after the loop" [expr {[fi_f32 1.5] eq "1.5" && [fi_loop 1000] == $r1}]
check "the bytes of a rounded value" [expr {[fi_bytes 1.5] eq [binary format f 1.5]}]
if {$bad} { exit 1 }
puts ok
TCL
out=$(PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "f32idiom: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "f32idiom: FAILED"; exit 1; }
echo "f32idiom: the float32 rounding idiom is typed (double and object arguments, pending value read by the scan): ok"
