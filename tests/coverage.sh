#!/bin/bash
# Which typed variants the differential test enters, and where typed code gives up (D: deoptimisation points, C: post-call stubs, R: resumes after a
# failure in a proc with frame variables).  Builds the test module with -DTBC_COV.
#
#   tests/coverage.sh [pattern]     counters whose name matches the egrep pattern (default: all)
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "coverage: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/p.c" Testprocs -hints tests/hints.txt >"$tmp/translate.log" 2>&1 || { tail -5 "$tmp/translate.log"; exit 1; }
"$CC" -O1 -w -DTBC_COV $TBC_INC tests/harness.c "$tmp/p.c" $TBC_LIBS -o "$tmp/suite" || exit 1
TBC_NOLEAK=1 TBC_COV_DETAIL=1 "$tmp/suite" tests/differential.tcl 2>&1 | grep -E '^(V|D|C|R):' | grep -E "${1:-.}"
