#!/bin/bash
# What a call into a compiled proc from interpreted code costs, against the interpreter's own call: instructions per call (callgrind, steady state: the difference of 5000 and 1000
# calls), for one proc of each shape (bench/entry/procs.tcl, the arguments in bench/entry/cases.txt).  A ratio under 1.00 is a proc that is slower compiled than interpreted.
# This is where the figures of liteProc (src/translate.tcl) come from: the entry costs about 700 instructions, and typed code of a loop-free body saves about 5 per instruction.
#   bench/entry.sh [-nolite]      -nolite: every body gets the entry stub (the module as the tests run it)
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
command -v valgrind >/dev/null || { echo "entry: needs valgrind" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ "${1:-}" = "-nolite" ] && export TBC_NOLITE=1
"$TCLSH" src/translate.tcl bench/entry/procs.tcl "$tmp/m.c" EntryProcs >"$tmp/tr.log" 2>&1 || { tail -5 "$tmp/tr.log"; exit 1; }
"$CC" -O1 -w -DMODULE=EntryProcs $TBC_INC tools/module-shell.c "$tmp/m.c" $TBC_LIBS -o "$tmp/shell" || exit 1
cat > "$tmp/one.tcl" <<T
if {[info exists ::env(COMPILED)]} { load {} EntryProcs }
source $PWD/bench/entry/procs.tcl
set ::g 0; set ::u 0; set ::vv 0
set p \$::env(CASE); set arg \$::env(ARG); set n \$::env(N)
for {set i 0} {\$i < \$n} {incr i} { if {\$arg eq "-"} { \$p } else { \$p \$arg } }
T
cnt() { env $3 CASE=$p ARG="$arg" N=$1 valgrind --tool=callgrind --callgrind-out-file=/dev/null "$tmp/shell" "$tmp/one.tcl" 2>&1 >/dev/null | grep -o "Collected : [0-9]*" | cut -d' ' -f3; }
printf "%-12s %12s %12s %8s\n" proc "interp/call" "compiled/call" ratio
while IFS= read -r line; do
  p=${line%% *}; arg=${line#* }
  i0=$(cnt 1000 x X=1); i1=$(cnt 5000 x X=1); c0=$(cnt 1000 x COMPILED=1); c1=$(cnt 5000 x COMPILED=1)
  python3 -c "print('%-12s %12.0f %12.0f %8.2f' % ('$p', ($i1-$i0)/4000, ($c1-$c0)/4000, ($i1-$i0)/max(1,($c1-$c0))))"
done < bench/entry/cases.txt
