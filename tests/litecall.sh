#!/bin/sh
# A small loop-free proc is left to the interpreter when interpreted code calls it (the entry costs more than the body saves, decision 51), but a compiled caller calls its typed code
# directly, with no Tcl frame (decision 76: the engine's float32 and fixed-point helpers; a measurement under TBC_NOLITE=1 against the default shows the same time, so the lite rule
# is not what held them back, see the decision).  This checks, in a module built with -DTBC_COV and WITHOUT TBC_NOLITE, that
#  - the lite helpers are lite (entry field 1), so interpreted calls do not enter compiled code (their entry counts stay 0 for 50 calls from the top level);
#  - the calls of a compiled loop enter the typed code of each (every call but the first, which attaches the proc, is a direct call), with no hand-over;
#  - a helper redefined between two runs of the loop is not called directly any more (the loop sees the new body), and the old one is called again after it is restored.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "litecall: $TCLSH not built; run 'make shell'" >&2; exit 1; }
unset TBC_NOLITE
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/p.tcl" <<'TCL'
proc lc_tiny {x} { expr {$x * 2 + 1} }
proc lc_clamp {v} { return [expr {$v < 0.0 ? 0 : $v > 255.0 ? 255 : int($v)}] }
proc lc_f32 {x} { binary scan [binary format f $x] f r; return $r }
proc lc_f32l {l} { binary scan [binary format f* $l] f* r; return $r }
proc lc_loop {n} { set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [lc_tiny $i] + [lc_clamp [expr {$i * 0.7}]] + [lc_f32 [expr {$i * 0.1}]] + [llength [lc_f32l [list $s 1.5]]]}] }; return $s }
TCL
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/p.c" Lcall >"$tmp/tr.log" 2>&1 || { echo "litecall: translation failed"; tail -3 "$tmp/tr.log"; exit 1; }
lite() { grep -E "^static TbcEntry tbc_e__3a_3a$(printf '%s' "$1" | sed 's/_/_5f/g') " "$tmp/p.c" | sed 's/.*, \([01]\) };$/\1/'; }
for p in lc_tiny lc_clamp lc_f32 lc_f32l; do [ "$(lite $p)" = 1 ] || { echo "litecall: FAILED, $p is not a lite proc (the test would not test the lite rule)"; exit 1; }; done
[ "$(lite lc_loop)" = 0 ] || { echo "litecall: FAILED, lc_loop has a loop and must get the entry"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Lcall $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "litecall: build failed"; exit 1; }
cat > "$tmp/run.tcl" <<'TCL'
load {} Lcall
source $::env(PROCS)
proc entries {d p} { set t 0; if {[dict exists $d $p]} { dict for {k v} [dict get $d $p entries] { incr t $v } }; return $t }
set bad 0
proc check {what ok} { if {!$ok} { puts "FAILED: $what"; incr ::bad } }
# the interpreter calls them 50 times: no entry into compiled code
for {set i 0} {$i < 50} {incr i} { lc_tiny $i; lc_clamp 3.5; lc_f32 0.1; lc_f32l {1.0 2.0} }
set d [tbc::hot -dict]
foreach p {::lc_tiny ::lc_clamp ::lc_f32 ::lc_f32l} { check "$p entered from the interpreter ([entries $d $p])" [expr {[entries $d $p] == 0}] }
set ref [lc_loop 1000]
set d [tbc::hot -dict]
foreach p {::lc_tiny ::lc_clamp ::lc_f32 ::lc_f32l} {
    check "$p entered [entries $d $p] times by a loop of 1000 calls (direct calls expected)" [expr {[entries $d $p] >= 999}]
    check "$p hands over" [expr {![dict exists $d $p] || [dict get $d $p handovers] == 0}]
}
# redefined: the loop must see the new body, and be direct again after the old one is back
rename lc_tiny lc_tiny_o
proc lc_tiny {x} { expr {$x * 3} }
set r2 [lc_loop 10]
rename lc_tiny {}
rename lc_tiny_o lc_tiny
proc lc_tiny {x} { expr {$x * 2 + 1} }
check "a redefined helper was not seen by the loop" [expr {$r2 != [lc_loop 10]}]
check "the result changed after the helper was restored" [expr {[lc_loop 1000] == $ref}]
if {$bad} { exit 1 }
puts ok
TCL
out=$(PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "litecall: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "litecall: FAILED"; exit 1; }
echo "litecall: lite helpers are direct calls from a compiled loop and interpreter calls stay in the interpreter: ok"
