#!/bin/bash
# Idiomatic programs against the interpreter: wall time, best of three, results compared.   bench/idiom/run.sh
cd "$(dirname "$0")/../.." || exit 1
. tools/env.sh || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$TCLSH" src/translate.tcl bench/idiom/idiom.tcl "$tmp/m.c" Idiom >"$tmp/tr.log" 2>&1 || { tail -5 "$tmp/tr.log"; exit 1; }
"$CC" -O2 -w -DMODULE=Idiom $TBC_INC tools/module-shell.c "$tmp/m.c" $TBC_LIBS -o "$tmp/shell" || exit 1
cat > "$tmp/time.tcl" <<'T'
if {[info exists ::env(COMPILED)]} { load {} Idiom }
source bench/idiom/idiom.tcl
foreach {p a} {wordfreq 300000 primes 60000 matmul 60 records 20000 tokenize 20000 nbody 500000 fibmemo 25 bubble 700 strbuild 300000} {
    set best 1e30
    for {set k 0} {$k < 3} {incr k} { set t0 [clock microseconds]; set r [$p $a]; set t [expr {([clock microseconds] - $t0) / 1000.0}]; if {$t < $best} { set best $t } }
    puts "$p [string map {{ } _} $r] $best"
}
T
"$tmp/shell" "$tmp/time.tcl" > "$tmp/i.txt"
COMPILED=1 "$tmp/shell" "$tmp/time.tcl" > "$tmp/c.txt"
printf "%-10s %12s %12s %10s\n" program "interp ms" "compiled ms" speedup
paste -d' ' "$tmp/i.txt" "$tmp/c.txt" | awk '{ if ($2 != $5) bad = bad " " $1; printf "%-10s %12.1f %12.1f %9.1fx\n", $1, $3, $6, $3/$6 } END { if (bad) print "RESULTS DIFFER:" bad }'
