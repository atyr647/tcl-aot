#!/bin/sh
# Decision 88: the hand-over blocks that the sites of a typed function share.  What the frame holds when typed code hands over to the boxed code must be what the interpreter's frame
# holds: the same variables, with the same values, and no write into a variable that the interpreter would not have written (a trace would fire).  The test builds the module of
# tests/procs.tcl with a forced hand-over (TBC_FORCE_DEOPT=1) and runs the ho_* calls of tests/differential.tcl (dead locals, unset, a resume at a loop head, vectors and arrays,
# callees that reach the frame with upvar 1 / upvar 2 / uplevel, traces on a local set through upvar) against the interpreter with the hand-over forced at the k-th typed instruction after each
# entry (TBC_FORCE_AT=k), for k = 1 ... 80 and some larger ones, and by rate (TBC_FORCE_RATE).  Each TBC_HANDOVER mode of the translator is tested: none (the old code), site, set (the default),
# and settab: set with TBC_FLUSH_INLINE=0, so that every flush set is written from a table (with the default 6 few sets of procs.tcl are large enough to use the table).
#   tests/handover.sh          the modes none, site, set, settab
#   tests/handover.sh chk      also the mode chk: the flush of all sites of a depth is one block that writes every local that holds an object and stops the program when a site does not
#                              have that local in its own flush set (the evidence for the draft `all`, not part of the default test: it runs the whole differential test too)
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export TBC_NOLITE=1
status=0
modes="none site set settab"; [ "${1:-}" = chk ] && modes="$modes chk"
# HO_MODES="all": only the listed modes (all is the draft that writes every local that holds an object: expected to fail where a site does not flush a local)
[ -n "${HO_MODES:-}" ] && modes=$HO_MODES
for mode in $modes; do
  hm=$mode; unset TBC_FLUSH_INLINE
  [ "$mode" = settab ] && { hm=set; export TBC_FLUSH_INLINE=0; }
  TBC_HANDOVER=$hm TBC_FORCE_DEOPT=1 "$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/$mode.c" Testprocs -hints tests/hints.txt -split 3 >"$tmp/$mode.log" 2>&1 \
    || { tail -5 "$tmp/$mode.log"; echo "handover: FAILED, translation in mode $mode"; exit 1; }
  # -DTBC_COV: the counters of the hand-overs taken, to show that the forced hand-overs really happen
  CFLAGS_V="-O2 -DTBC_COV" CFLAGS_G="-O1 -DTBC_COV" CFLAGS_I="-O1 -DTBC_COV" tools/build-module.sh "$tmp/$mode.c" "$tmp/$mode.o" || { echo "handover: FAILED, building the module of mode $mode"; exit 1; }
  "$CC" -O1 -w $TBC_INC tests/harness.c "$tmp/$mode.o" $TBC_LIBS -o "$tmp/$mode" || { echo "handover: FAILED, linking mode $mode"; exit 1; }
  n=0; bad=0
  # the forced hand-over must really happen: a run at instruction 1 must report hand-overs taken
  cov=$(env TBC_ONLY='ho_*' TBC_FORCE_AT=1 TBC_NOLEAK=1 TBC_ERRINFO=1 "$tmp/$mode" tests/differential.tcl 2>&1 | grep '^coverage:')
  case "$cov" in *"(0 deopts in total"*|"") echo "handover: mode $mode: FAILED, no hand-over was taken ($cov)"; status=1; continue ;; esac
  echo "handover: mode $mode, forced at instruction 1: $cov"
  for k in $(seq 1 80) 100 130 170 220 300 500 800; do
    out=$(env TBC_ONLY='ho_*' TBC_FORCE_AT=$k TBC_NOLEAK=1 TBC_ERRINFO=1 "$tmp/$mode" tests/differential.tcl 2>&1)
    if [ $? -ne 0 ] || printf '%s\n' "$out" | grep -q -E 'MISMATCH|LEAK|NOT COMPILED|FLUSHCHK'; then
      printf '%s\n' "$out" | grep -E -A3 'MISMATCH|LEAK|NOT COMPILED|FLUSHCHK' | head -8; echo "handover: mode $mode, forced at instruction $k: FAILED"; bad=1; status=1; break
    fi
    n=$((n + 1))
  done
  for rate in 2 3 5 11; do for seed in 1 2 3; do
    out=$(env TBC_ONLY='ho_*' TBC_FORCE_RATE=$rate TBC_FORCE_SEED=$seed TBC_NOLEAK=1 TBC_ERRINFO=1 "$tmp/$mode" tests/differential.tcl 2>&1)
    if [ $? -ne 0 ] || printf '%s\n' "$out" | grep -q -E 'MISMATCH|LEAK|NOT COMPILED|FLUSHCHK'; then
      printf '%s\n' "$out" | grep -E -A3 'MISMATCH|LEAK|NOT COMPILED|FLUSHCHK' | head -8; echo "handover: mode $mode, rate $rate seed $seed: FAILED"; bad=1; status=1
    fi
  done; done
  [ $bad = 0 ] && echo "handover: mode $mode: the ho_* calls equal the interpreter's with a hand-over forced at each of $n instruction counts and at 12 rates: ok"
  if [ "$mode" = chk ]; then
    for rate in 3 17 101; do for seed in 1 2; do
      out=$(env TBC_FORCE_RATE=$rate TBC_FORCE_SEED=$seed TBC_NOLEAK=1 TBC_ERRINFO=1 "$tmp/chk" tests/differential.tcl 2>&1)
      if [ $? -ne 0 ] || printf '%s\n' "$out" | grep -q -E 'MISMATCH|LEAK|NOT COMPILED|FLUSHCHK'; then
        printf '%s\n' "$out" | grep -E -A3 'MISMATCH|LEAK|NOT COMPILED|FLUSHCHK' | head -8; echo "handover: mode chk, whole differential test, rate $rate seed $seed: FAILED"; status=1
      fi
    done; done
    [ $status = 0 ] && echo "handover: mode chk: no hand-over of the whole differential test (rates 3, 17, 101) writes a local that is not in its site's flush set: ok"
  fi
done
exit $status
