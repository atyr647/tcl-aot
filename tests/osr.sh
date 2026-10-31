#!/bin/bash
# Boxed code must enter typed code again at a loop head after typed code has handed over before the loop (a bignum, an out-of-range value).  The results are
# compared by the differential test (os_* procs); this checks that the entry is taken, which the results alone cannot show: coverage counters of the test module.
cd "$(dirname "$0")/.." || exit 1
out=$(tests/coverage.sh '(os_[a-z]+/B|dn_up/BB|dn_list/BB|dnns::f/BB)/RE=' 2>&1) || { echo "osr: coverage run failed"; echo "$out" | tail -3; exit 1; }
for p in os_big os_giveup os_mid os_nested os_foreach os_while os_error os_catch os_return os_dbl; do
  n=$(echo "$out" | sed -n "s|^V:::$p/B/RE=||p")
  if [ -z "$n" ] || [ "$n" -lt 1 ]; then echo "osr: FAILED, $p never entered typed code again at a loop head"; exit 1; fi
done
# (procs that link state by names held in variables, and read numbers from it: typed code goes on at the loop head after the `upvar`)
for p in dn_up dn_list dnns::f; do
  n=$(echo "$out" | sed -n "s|^V:::$p/BB/RE=||p")
  if [ -z "$n" ] || [ "$n" -lt 1 ]; then echo "osr: FAILED, $p never entered typed code again at a loop head"; exit 1; fi
done
echo "osr: boxed code entered typed code again at a loop head in all os_* and dn_* procs: ok"
