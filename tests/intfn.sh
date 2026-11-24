#!/bin/sh
# Decision NN (assigned when it lands).  int(), wide() and round() of doubles and integers in typed code, at the edges of 32 and 64 bits, against the interpreter's.
# Tcl's int() keeps the low CHAR_BIT * sizeof(long) bits of the integer that entier() makes (ExprIntFunc: TclGetLongFromObj of a wide integer, mp_mod_2d of a bignum), wide() the 64
# low bits, and round() is exact whatever the width of long.  Typed code used to hand over for every int() and wide() where long is not 64 bits wide (the N64: `sizeof(long) != 8`),
# and for round(); now it computes them from `sizeof(long)` at C compile time (tbc_int_wrap, tbc_dbl_to_int, tbc_dbl_to_wide, tbc_dbl_round in include/tbc_runtime.h).  On a machine whose
# long is 64 bits wide (where this test runs) int() and wide() are the same function; the 32-bit half is proved on the N64 (docs/research/n64-cart-budget/aot6-long32/).  Checked here:
#  - every value of the edge list through int(), wide() and round() of an object (kind B), of a double (D), of an integer (I), of a tagged number (W) and of literals, and through the
#    operations that read the result (+, *, comparison, a second int()), compiled against the interpreter: the same result string or the same error;
#  - every value that is a finite number below 2^63 in magnitude stays typed: no hand-over in any of the procs (counters of the -DTBC_COV module);
#  - values that need a bignum or an error (2^63 and above, infinity, NaN, text) hand over and give the interpreter's result or error.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "intfn: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp tests/intfn_procs.tcl "$tmp/intfn_procs.tcl"
TBC_NOLITE=1 "$TCLSH" src/translate.tcl "$tmp/intfn_procs.tcl" "$tmp/m.c" Fn >"$tmp/tr.log" 2>&1 || { tail -5 "$tmp/tr.log"; echo "intfn: translation failed"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Fn $TBC_INC tools/module-shell.c "$tmp/m.c" $TBC_LIBS -o "$tmp/shell" || { echo "intfn: build failed"; exit 1; }
export FN_PROCS="$tmp/intfn_procs.tcl" TBC_NOLITE=1
status=0
for mode in lazy eager; do
  if [ $mode = eager ]; then export TBC_EAGER=1; else unset TBC_EAGER; fi
  out=$("$tmp/shell" tests/intfn.tcl 2>&1) && echo "intfn: $mode attach: ok ($(printf '%s\n' "$out" | grep -E 'compared' | head -1))" || { printf '%s\n' "$out" | head -20; echo "intfn: $mode attach: FAILED"; status=1; }
done
[ $status = 0 ] && echo "intfn: ok"
exit $status
