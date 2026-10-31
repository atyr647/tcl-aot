#!/bin/bash
# The command-per-instruction map of the translator (src/cmdmap.tcl): same result as the loop over every command, and not quadratic in the size of a proc.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "cmdmap: $TCLSH not built; run 'make shell'" >&2; exit 1; }
out=$("$TCLSH" tests/cmdmap.tcl 2>&1) || { echo "$out"; exit 1; }
echo "cmdmap: the command of every instruction is found as by the loop over all commands, 40000 instructions in a fraction of a second: ok"
