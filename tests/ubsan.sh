#!/bin/bash
# Undefined behaviour in the generated code and in the runtime header.  What the C standard leaves undefined may give the right answer in one build and the
# wrong one in another (the shared small integers once returned the object for -1 when asked for 9223372036854775807 + 256, in one optimised module and not in
# a smaller one), so the answer of a test is not enough: the test module is built with -fsanitize=undefined (typed code, boxed code, tables, the runtime
# header, the test shell) and the differential test runs with the first report ending the run, plain and with forced hand-over at every typed instruction.
# Only the module and the header are instrumented, not libtcl.
#
# UBSAN_EXTRA: more compiler flags for the module (tests that this test fails when it must name another copy of the headers, -I<dir>).
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
SAN="-fsanitize=undefined -fno-sanitize-recover=undefined"
echo 'int main(void) { volatile int x = 1; return x - 1; }' > "$tmp/probe.c"
if ! "$CC" $SAN "$tmp/probe.c" -o "$tmp/probe" 2>/dev/null || ! "$tmp/probe"; then
  echo "ubsan: not run, $CC cannot build with -fsanitize=undefined here"
  exit 0
fi
export TBC_NOLITE=1   # every compiled body is entered from the interpreter, as in tests/run.sh
export TBC_ERRINFO=1 TBC_NOLEAK=1 UBSAN_OPTIONS=print_stacktrace=1
fail=0
for mode in plain forced; do
  if [ $mode = forced ]; then export TBC_FORCE_DEOPT=1; else unset TBC_FORCE_DEOPT; fi
  "$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/$mode.c" Testprocs -hints tests/hints.txt -split 3 >"$tmp/translate_$mode.log" 2>&1 \
    || { tail -5 "$tmp/translate_$mode.log"; echo "ubsan: FAILED, translation ($mode)"; exit 1; }
  unset TBC_FORCE_DEOPT
  CFLAGS_V="-O2 $SAN ${UBSAN_EXTRA:-}" CFLAGS_G="-Og $SAN ${UBSAN_EXTRA:-}" CFLAGS_I="-O1 $SAN ${UBSAN_EXTRA:-}" \
    tools/build-module.sh "$tmp/$mode.c" "$tmp/$mode.o" >"$tmp/build_$mode.log" 2>&1 || { tail -5 "$tmp/build_$mode.log"; echo "ubsan: FAILED, build ($mode)"; exit 1; }
  # shellcheck disable=SC2086  # the flag variables hold several words
  "$CC" -O1 -w $SAN ${UBSAN_EXTRA:-} $TBC_INC tests/harness.c "$tmp/$mode.o" $TBC_LIBS -o "$tmp/shell_$mode" || { echo "ubsan: FAILED, link ($mode)"; exit 1; }
  for attach in lazy eager; do
    if [ $attach = eager ]; then export TBC_EAGER=1; else unset TBC_EAGER; fi
    out=$("$tmp/shell_$mode" tests/differential.tcl 2>&1)
    if [ $? -eq 0 ] && ! echo "$out" | grep -q -E 'runtime error|MISMATCH|NOT COMPILED'; then
      echo "ubsan: $mode, $attach attach: $(echo "$out" | grep -E 'compared' | head -1)"
    else
      echo "$out" | grep -E -A6 'runtime error|MISMATCH|NOT COMPILED' | head -30
      echo "ubsan: FAILED ($mode, $attach attach)"
      fail=1
    fi
  done
  unset TBC_EAGER
done
[ $fail = 0 ] || exit 1
echo "ubsan: the test module built with -fsanitize=undefined runs the differential test, plain and with forced hand-over, without a report: ok"
