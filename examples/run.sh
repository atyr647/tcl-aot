#!/bin/bash
# Translate examples/collatz.tcl, link the result into a shell, and run examples/main.tcl with the interpreter alone and with the compiled procs.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "examples: $TCLSH not built; run 'make shell'" >&2; exit 1; }
out=${OUT:-$BUILD/example}
mkdir -p "$out"

"$TCLSH" src/translate.tcl examples/collatz.tcl "$out/collatz.c" Collatz
"$CC" -O1 -w -DMODULE=Collatz $TBC_INC tools/module-shell.c "$out/collatz.c" $TBC_LIBS -o "$out/shell"
echo "-- interpreter alone"
"$out/shell" examples/main.tcl
echo "-- compiled"
COMPILED=1 "$out/shell" examples/main.tcl
