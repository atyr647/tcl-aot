#!/bin/bash
# Compiled code recurses on the C stack, the interpreter on its heap stack.  Past TBC_NEST_CAP live compiled entries a call is run by the interpreter
# instead (as inside a coroutine); results and error info must not change.  Builds the test module with caps far below the recursion depths of the
# suite and requires the differential run to agree in both attach modes.  (A WebAssembly guest has 512 KiB of call stack by default; there the cap is 200.)
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/p.c" Testprocs -hints tests/hints.txt >"$tmp/translate.log" 2>&1 \
  || { echo "nestcap: translation failed"; tail -5 "$tmp/translate.log"; exit 1; }
status=0
for cap in 1 3 40; do
  "$CC" -O1 -w -DTBC_NEST_CAP=$cap $TBC_INC tests/harness.c "$tmp/p.c" $TBC_LIBS -o "$tmp/suite" 2>&1 | grep error
  for mode in lazy eager; do
    if [ $mode = eager ]; then export TBC_EAGER=1; else unset TBC_EAGER; fi
    out=$(TBC_NOLEAK=1 timeout 600 "$tmp/suite" tests/differential.tcl 2>&1 | grep -E 'compared|NOT COMPILED')
    case "$out" in
      *" 0 mismatches"*) echo "nest cap $cap, $mode attach: $out: ok" ;;
      *) echo "nest cap $cap, $mode attach: FAILED: $out"; status=1 ;;
    esac
  done
done
exit $status
