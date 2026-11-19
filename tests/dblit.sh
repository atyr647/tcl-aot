#!/bin/sh
# A double literal in arithmetic is a double operand whatever its text (decision 75): `6.36619772367581382433e-01` is not what Tcl prints, so it was an object operand
# that stopped typed code at the first product.  The results are compared by the differential test (dl_* procs); this checks, in a module built with -DTBC_COV, that
# a loop of 1000 calls and the loop itself take their typed code without a hand-over.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "dblit: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/run.tcl" <<'TCL'
load {} Dltest
source $::env(DL_PROCS)
# (dl_drive is compiled: the procs it calls are called directly, as a compiled caller calls them; a loop-free proc called from the interpreter stays there)
set r [dl_drive 1000]
set r2 [dl_loop 1000]
set d [tbc::hot -dict]
set bad 0
foreach p {::dl_drive ::dl_mult ::dl_floor ::dl_mix ::dl_w ::dl_loop} {
    if {![dict exists $d $p]} { puts "FAILED: $p not counted"; incr bad; continue }
    if {[dict get $d $p handovers] != 0} { puts "FAILED: $p hands over [dict get $d $p handovers] times"; incr bad }
}
if {$bad} { exit 1 }
puts "ok"
TCL
"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/p.c" Dltest -hints tests/hints.txt >"$tmp/translate.log" 2>&1 || { echo "dblit: translation failed"; tail -3 "$tmp/translate.log"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Dltest $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "dblit: build failed"; exit 1; }
out=$(TBC_NOLITE=1 DL_PROCS="$PWD/tests/procs.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "dblit: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "dblit: FAILED"; exit 1; }
echo "dblit: double literals in arithmetic stay typed (no hand-over in a loop of 1000 calls): ok"
