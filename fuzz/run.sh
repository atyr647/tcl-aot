#!/bin/bash
# Differential fuzzing: random procs and calls, run by the interpreter alone and with the compiled module; results, error codes and error info must be
# equal.  Deterministic for a seed.
#
#   fuzz/run.sh typed <seed> [-O flags]   arithmetic, integer vectors, integer maps, arrays and links: the typed code and its fall-backs
#   fuzz/run.sh boxed <seed> [-O flags]   strings, lists, dicts, arrays, flow control, named variables, bit operators: the boxed code
set -u
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "fuzz: $TCLSH not built; run 'make shell'" >&2; exit 1; }
kind=${1:?usage: fuzz/run.sh typed|boxed <seed>}
seed=${2:?usage: fuzz/run.sh typed|boxed <seed>}
shift 2
cflags=${*:--O1}
fuzz=$PWD/fuzz
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1

case $kind in
  typed)
    "$TCLSH" "$fuzz/gen_typed.tcl" "$seed" 150 80 150 60 40 || exit 1
    cp "$fuzz/run_typed.tcl" run.tcl
    "$TCLSH" "$TBC_ROOT/src/translate.tcl" fuzz_procs.tcl module.c Fuzzprocs -hints fuzz_hints.txt >translate.log 2>&1 \
      || { echo "fuzz: translation failed"; tail -5 translate.log; exit 1; }
    module=Fuzzprocs ;;
  boxed)
    "$TCLSH" "$fuzz/gen_boxed.tcl" "$seed" 60 40 || exit 1
    cp "$fuzz/run_boxed.tcl" run.tcl
    "$TCLSH" "$TBC_ROOT/src/translate.tcl" fuzz_procs2.tcl module.c Fuzzprocs2 -untyped >translate.log 2>&1 \
      || { echo "fuzz: translation failed"; tail -5 translate.log; exit 1; }
    module=Fuzzprocs2 ;;
  *) echo "usage: fuzz/run.sh typed|boxed <seed>" >&2; exit 2 ;;
esac

# shellcheck disable=SC2086  # cflags and the Tcl flags hold several words
"$CC" $cflags -w -DTBC_COV -DMODULE=$module $TBC_INC "$TBC_ROOT/tools/module-shell.c" module.c $TBC_LIBS -o shell 2>cc.log || { grep error cc.log | head; exit 1; }
timeout 1800 ./shell run.tcl >out.txt 2>&1
status=$?
echo "fuzz $kind seed $seed: $(grep -E 'compared' out.txt | tail -1)"
grep -E 'NO COMPILED BODY|MISMATCH' out.txt | head -5
exit $status
