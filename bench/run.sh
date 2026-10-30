#!/bin/bash
# Time the benchmark procs with the interpreter alone and with the compiled module, and, if valgrind is installed, count instructions (which, unlike
# wall time, does not depend on the machine's load).
#
#   bench/run.sh            wall time of each proc
#   bench/run.sh count      instructions of each proc, startup excluded (needs valgrind; slow)
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "bench: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$TCLSH" src/translate.tcl bench/procs.tcl "$tmp/m.c" Benchprocs >"$tmp/translate.log" 2>&1 || { tail -5 "$tmp/translate.log"; exit 1; }
"$CC" -O1 -w -DMODULE=Benchprocs $TBC_INC tools/module-shell.c "$tmp/m.c" $TBC_LIBS -o "$tmp/shell" || exit 1

# {proc argument} pairs for the timing run
cases="{arr_sieve 300000} {arr_hist 300000} {arr_fib 3000} {arr_mat 40} {ups_run 1000000} {glob_loop 1000000} {nn::bump 1000000} {nn::fill 200000} {int_loop 3000000} {call_small 1000000} {call_default 1000000} {call_frame 200000} {math_funcs 1000000} {math_int 1000000} {list_foreach 1000} {list_index 1000} {str_ops 500000} {sw_loop 1000000} {catch_loop 1000000}"

if [ "${1:-}" != count ]; then
  cat > "$tmp/time.tcl" <<'T'
if {[info exists ::env(COMPILED)]} { load {} Benchprocs }
source bench/procs.tcl
foreach c $::env(CASES) {
    lassign $c p a
    set best 1e30
    for {set k 0} {$k < 3} {incr k} {
        set t0 [clock microseconds]; set r [$p $a]; set t [expr {([clock microseconds] - $t0) / 1000.0}]
        if {$t < $best} { set best $t }
    }
    puts [format "%-10s %-14s %9.1f ms" $p $r $best]
}
T
  echo "interpreter alone (best of 3):"; CASES="$cases" "$tmp/shell" "$tmp/time.tcl"
  echo "compiled module (best of 3):";   COMPILED=1 CASES="$cases" "$tmp/shell" "$tmp/time.tcl"
  exit 0
fi

command -v valgrind >/dev/null || { echo "bench: valgrind is not installed" >&2; exit 1; }
cat > "$tmp/one.tcl" <<'T'
if {[info exists ::env(COMPILED)]} { load {} Benchprocs }
source bench/procs.tcl
if {[info exists ::env(PROC)]} { $::env(PROC) $::env(ARG) }
T
count() { valgrind --tool=callgrind --callgrind-out-file=/dev/null "$tmp/shell" "$tmp/one.tcl" 2>&1 | awk '/refs/ { gsub(",", "", $NF); print $NF }'; }
base_i=$(count); base_c=$(COMPILED=1 count)
printf "%-12s %14s %14s %8s\n" proc interpreter compiled ratio
for c in arr_sieve=100000 arr_hist=100000 arr_fib=2000 arr_mat=30 ups_run=300000 glob_loop=300000 nn::bump=300000 nn::fill=100000 int_loop=300000 call_small=100000 call_default=100000 call_frame=100000 math_funcs=100000 math_int=100000 list_foreach=100 list_index=100 str_ops=100000 sw_loop=100000 catch_loop=100000; do
  p=${c%%=*}; a=${c##*=}
  i=$(( $(PROC=$p ARG=$a count) - base_i )); k=$(( $(COMPILED=1 PROC=$p ARG=$a count) - base_c ))
  awk -v p="$p" -v i="$i" -v k="$k" 'BEGIN { printf "%-12s %14d %14d %7.2fx\n", p, i, k, i / k }'
done
