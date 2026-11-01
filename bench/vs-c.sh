#!/bin/bash
# Compiled Tcl against the interpreter and against C: the same kernels (bench/c/kernels.tcl, bench/c/kernels.c), wall time, best of three.  The goal is that
# the ratio to C of compiled code is small for any kernel written in Tcl; the kernels that are far from it show where the work is.
#
#   bench/vs-c.sh            table: interpreter ms, compiled ms, C ms, compiled / C, interpreter / compiled
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "bench: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$TCLSH" src/translate.tcl bench/c/kernels.tcl "$tmp/m.c" Kernels >"$tmp/tr.log" 2>&1 || { tail -5 "$tmp/tr.log"; exit 1; }
"$CC" -O2 -w -DMODULE=Kernels $TBC_INC tools/module-shell.c "$tmp/m.c" $TBC_LIBS -o "$tmp/shell" || exit 1
gcc -O2 -o "$tmp/c" bench/c/kernels.c || exit 1
cat > "$tmp/time.tcl" <<'T'
if {[info exists ::env(COMPILED)]} { load {} Kernels }
source bench/c/kernels.tcl
foreach {p a} {k_arith 20000000 k_collatz 100000 k_fib 30 k_sieve 3000000 k_mat 120 k_hist 3000000 k_dotd 1000000 k_lcs 600} {
    set best 1e30
    for {set k 0} {$k < 3} {incr k} { set t0 [clock microseconds]; set r [$p $a]; set t [expr {([clock microseconds] - $t0) / 1000.0}]; if {$t < $best} { set best $t } }
    if {$p eq "k_dotd"} { set r [expr {int($r)}] }
    puts "$p $r $best"
}
T
"$tmp/shell" "$tmp/time.tcl" > "$tmp/i.txt"
COMPILED=1 "$tmp/shell" "$tmp/time.tcl" > "$tmp/c.txt"
"$tmp/c" > "$tmp/native.txt"
printf "%-10s %10s %10s %10s %12s %12s\n" kernel "interp ms" "compiled ms" "C ms" "compiled/C" "interp/comp"
paste -d' ' "$tmp/i.txt" "$tmp/c.txt" "$tmp/native.txt" | awk '{ if ($2 != $5 || $2 != $8) bad = bad " " $1; printf "%-10s %10.1f %10.1f %10.3f %11.1fx %11.1fx\n", $1, $3, $6, $9, $6 / $9, $3 / $6 } END { if (bad != "") { print "RESULTS DIFFER:" bad; exit 1 } }'
