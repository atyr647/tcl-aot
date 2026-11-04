#!/bin/bash
# Procs that the module leaves to the interpreter when interpreted code calls them (a loop-free, not recursive body whose typed code is small: the entry stub would cost more than
# the body saves, decision 51) must give the interpreter's results whoever calls them, and a loop, a recursion, or a lot of typed code must still get the stub.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
unset TBC_NOLITE
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/p.tcl" <<'TCL'
proc lt_tiny {x} { expr {$x * 2 + 1} }
proc lt_str {s} { string length $s }
proc lt_call {x} { return [expr {[lt_tiny $x] + [lt_str abc]}] }
proc lt_loop {n} { set s 0; for {set i 0} {$i < $n} {incr i} { incr s $i }; return $s }
proc lt_rec {n} { if {$n < 2} { return $n }; return [expr {[lt_rec [expr {$n - 1}]] + [lt_rec [expr {$n - 2}]]}] }
proc lt_cb {l} { lsort -command lt_cmp $l }
proc lt_cmp {a b} { expr {$a - $b} }
# an expression of nine operations breaks even with the entry (m_p9 of bench/entry: 1.00 with it, 0.93 to 0.99 for fewer), so the interpreter keeps it; one of fourteen, the size of ascii85's
# encode4bytes, gains from typed code
proc lt_nine {v} { return [expr {(((((((($v + 3) * 7) - 5) & 255) | 9) ^ 11) << 2) >> 1) + 1}] }
proc lt_fourteen {v} { return [expr {(((((((((((((($v + 3) * 7) - 5) & 255) | 9) ^ 11) << 2) >> 1) + 1) * 5) - 3) ^ 6) | 17) & 1023) + 2}] }
TCL
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/p.c" Liteprocs >"$tmp/tr.log" 2>&1 || { echo "lite: translation failed"; tail -3 "$tmp/tr.log"; exit 1; }
# the entry of a proc ends with its yres, ens and lite fields
lite() { local n=${1//_/_5f}; grep -E "^static TbcEntry tbc_e__3a_3a$n " "$tmp/p.c" | sed -E 's/.*, ([01]) \};$/\1/'; }
for p in lt_tiny lt_str lt_call lt_cmp lt_cb lt_nine; do [ "$(lite $p)" = 1 ] || { echo "lite: FAILED, $p is not left to the interpreter"; exit 1; }; done
for p in lt_loop lt_rec lt_fourteen; do [ "$(lite $p)" = 0 ] || { echo "lite: FAILED, $p is a loop or a recursion and must get the entry"; exit 1; }; done
echo "lite: small loop-free procs are left to the interpreter, loops and recursions are not: ok"
"$CC" -O1 -w -DMODULE=Liteprocs $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "lite: build failed"; exit 1; }
cat > "$tmp/run.tcl" <<'TCL'
if {[info exists ::env(COMPILED)]} { load {} Liteprocs }
source $::env(PROCS)
set r {}
foreach x {0 1 5 -3} { lappend r [lt_tiny $x] [lt_call $x] }
lappend r [lt_str hello] [lt_loop 50] [lt_rec 12] [lt_cb {5 3 9 1}] [lt_nine 100] [lt_fourteen 100] [lt_nine -7] [lt_fourteen 9223372036854775807]
puts $r
puts [catch {lt_tiny} e]:$e
puts [catch {lt_tiny 1 2} e]:$e
puts [catch {lt_tiny abc} e]:$e
TCL
a=$(PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1); b=$(COMPILED=1 PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1)
[ "$a" = "$b" ] || { echo "lite: FAILED, results differ:"; echo "$a"; echo "$b"; exit 1; }
echo "lite: the results (and the errors) are the interpreter's: ok"
