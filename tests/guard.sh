#!/bin/bash
# A module compiled without the macros libtcl was built with must refuse to load: the object-allocation macros of Tcl's headers would take objects
# from a free list that nothing refills (a leak of 80 bytes per loop iteration in boxed code).
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/p.c" Testprocs -hints tests/hints.txt >"$tmp/translate.log" 2>&1 \
  || { echo "guard: translation failed"; tail -5 "$tmp/translate.log"; exit 1; }
# deliberately without $TBC_DEFS
"$CC" -O1 -w -I"$TCL_SRC/generic" -I"$TCL_SRC/unix" -I"$TBC_ROOT/include" tests/harness.c "$tmp/p.c" $TBC_LIBS -o "$tmp/bad" 2>&1 | grep error
out=$(echo 'load {} Testprocs' | "$tmp/bad" 2>&1)
case "$out" in
  *"compile it with the flags of the Tcl it loads into"*) echo "guard: a module built without the Tcl's flags is refused: ok" ;;
  *) echo "guard: FAILED, the mismatched module loaded: $out"; exit 1 ;;
esac
