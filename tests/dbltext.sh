#!/bin/sh
# A double that has a string form is taken as an unboxed argument or element when its text is the one Tcl prints for it (decision 61).  The results are compared by the
# differential test (cd_* procs: canonical text, 2.50, 1e3, .5, Inf, tcl_precision changed); this checks that the unboxed entry is taken for the canonical ones, which the
# results alone cannot show: coverage counters of the test module.
cd "$(dirname "$0")/.." || exit 1
out=$(TBC_NOLITE=1 tests/coverage.sh '(cd_helper/DD|cd_store/B/RE|cd_helper/BB)=' 2>&1) || { echo "dbltext: coverage run failed"; printf '%s\n' "$out" | tail -3; exit 1; }
dd=$(printf '%s\n' "$out" | sed -n 's|^V:::cd_helper/DD=||p')
bb=$(printf '%s\n' "$out" | sed -n 's|^V:::cd_helper/BB=||p')
re=$(printf '%s\n' "$out" | sed -n 's|^V:::cd_store/B/RE=||p')
[ "${dd:-0}" -ge 5 ] || { echo "dbltext: FAILED, cd_helper took the unboxed entry ${dd:-0} times (canonical texts must): $out"; exit 1; }
[ "${bb:-0}" -ge 10 ] || { echo "dbltext: FAILED, cd_helper took the generic entry only ${bb:-0} times (texts such as 2.50 and 1e3 must): $out"; exit 1; }
[ "${re:-0}" -ge 3 ] || { echo "dbltext: FAILED, cd_store never entered typed code again at a loop head after a text that is not canonical (${re:-0})"; exit 1; }
echo "dbltext: doubles with canonical text are taken unboxed (entry $dd times), other texts go the generic way ($bb times): ok"
