#!/bin/bash
# Regression test for a slowdown found by measuring: a proc that keeps integer lists in locals (kept as native vectors) and does `lset` in one branch of an `if`
# and something else in the other copied the vector into a Tcl list on every run through the branch, and ran 10 times SLOWER than the interpreter.  The value of the
# `if` is popped at once, so it must cost nothing.  Instructions are counted (not time: the box may be busy); the compiled proc must give the same result
# and use less than half the instructions of the interpreter (it uses about a sixth; the broken code used about eight times more).
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "localvec: $TCLSH not built; run 'make shell'" >&2; exit 1; }
command -v valgrind >/dev/null || { echo "localvec: valgrind not installed, skipped: ok"; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$TCLSH" src/translate.tcl bench/shape.tcl "$tmp/m.c" Shape >"$tmp/translate.log" 2>&1 || { tail -5 "$tmp/translate.log"; echo "localvec: translation failed"; exit 1; }
"$CC" -O1 -w -DMODULE=Shape $TBC_INC tools/module-shell.c "$tmp/m.c" $TBC_LIBS -o "$tmp/shell" || exit 1
cat > "$tmp/run.tcl" <<'T'
if {[info exists ::env(COMPILED)]} { load {} Shape }
source bench/shape.tcl
if {[info exists ::env(RUN)]} { puts RESULT:[runB 256 40 30] }
T
count() { valgrind --tool=callgrind --callgrind-out-file=/dev/null "$tmp/shell" "$tmp/run.tcl" 2>"$tmp/vg" >"$tmp/out"; awk '/refs/ { gsub(",", "", $NF); print $NF }' "$tmp/vg"; }
base=$(count)
i=$(( $(RUN=1 count) - base )); ri=$(grep RESULT "$tmp/out")
k=$(( $(COMPILED=1 RUN=1 count) - base )); rk=$(grep RESULT "$tmp/out")
if [ "$ri" != "$rk" ] || [ -z "$ri" ]; then echo "localvec: results differ: $ri / $rk"; exit 1; fi
if [ $((k * 2)) -gt $i ]; then echo "localvec: compiled $k instructions against $i interpreted (must be under half): a vector is being copied again"; exit 1; fi
awk -v i=$i -v k=$k 'BEGIN { printf "localvec: interpreter %d, compiled %d instructions (%.1fx fewer): ok\n", i, k, i / k }'
