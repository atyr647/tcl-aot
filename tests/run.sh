#!/bin/bash
# Run the test suite.
#
#   tests/run.sh          everything: differential, report, proc wrapper, guard, nest cap, capture loop, pristine Tcl, fuzz seeds, valgrind if installed
#   tests/run.sh quick    the differential, report and proc wrapper tests only
#
# Needs the Tcl build (`make tcl`) and the translator shell (`make shell`).  Exit status 0 only if every check passed.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "tests: $TCLSH not built; run 'make shell'" >&2; exit 1; }
mode=${1:-all}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
status=0
fail() { echo "FAILED: $*"; status=1; }

echo "== building the test module"
"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/p.c" Testprocs -hints tests/hints.txt -split 3 >"$tmp/translate.log" 2>&1 \
  || { tail -5 "$tmp/translate.log"; fail "translation of tests/procs.tcl"; exit 1; }
tools/build-module.sh "$tmp/p.c" "$tmp/p.o" || { fail "building the test module"; exit 1; }
"$CC" -O1 -w $TBC_INC tests/harness.c "$tmp/p.o" $TBC_LIBS -o "$tmp/suite" || { fail "linking the test shell"; exit 1; }
# a single-file build of the same module as well (the split build is what tools/build-module.sh is for; both must agree)
"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/one.c" Testprocs -hints tests/hints.txt >"$tmp/translate1.log" 2>&1 || { fail "single-file translation"; exit 1; }
"$CC" -O1 -w $TBC_INC tests/harness.c "$tmp/one.c" $TBC_LIBS -o "$tmp/suite1" || { fail "linking the single-file test shell"; exit 1; }

# $1 label, remaining arguments: the shell, then its arguments; TBC_EAGER decides the attach mode
check_run() {
  label=$1; shift
  out=$("$@" 2>&1)
  if [ $? -eq 0 ] && ! echo "$out" | grep -q -E 'MISMATCH|LEAK|NOT COMPILED|FAIL'; then
    echo "$label: $(echo "$out" | grep -E 'compared|passed' | head -1)"
  else
    echo "$out" | grep -E 'MISMATCH|LEAK|NOT COMPILED|FAIL|rror' | head -20
    fail "$label"
  fi
}

for build in suite suite1; do
  # the memory-growth checks at the end of the differential test take a while: once per attach mode, on the split build
  leakcheck=(); [ $build = suite1 ] && leakcheck=(TBC_NOLEAK=1)
  for attach in lazy eager; do
    if [ $attach = eager ]; then export TBC_EAGER=1; else unset TBC_EAGER; fi
    echo "== $build, $attach attach"
    check_run "differential" env TBC_ERRINFO=1 "${leakcheck[@]}" "$tmp/$build" tests/differential.tcl
    check_run "report" "$tmp/$build" tests/report.tcl
    check_run "proc wrapper" "$tmp/$build" tests/procwrap.tcl
  done
done
unset TBC_EAGER

if [ "$mode" = quick ]; then exit $status; fi

echo "== guard, nest cap, capture loop, unmodified Tcl"
for t in guard nestcap capture pristine; do
  out=$(tests/$t.sh 2>&1) || { echo "$out"; fail "tests/$t.sh"; continue; }
  echo "$out" | grep -E ': ok$'
done

echo "== fuzz"
for seed in 1 2; do fuzz/run.sh typed $seed || fail "fuzz typed $seed"; done
for seed in 1 2; do fuzz/run.sh boxed $seed || fail "fuzz boxed $seed"; done

if command -v valgrind >/dev/null; then
  echo "== valgrind (small calls only)"
  if TBC_NOLEAK=1 TBC_SMALL=1 valgrind -q --error-exitcode=9 "$tmp/suite" tests/differential.tcl >"$tmp/valgrind.out" 2>&1; then
    echo "valgrind: $(grep compared "$tmp/valgrind.out")"
  else
    tail -20 "$tmp/valgrind.out"; fail "valgrind"
  fi
fi
exit $status
