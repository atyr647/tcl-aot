#!/bin/bash
# Procs of the program that have the names of procs of the translator itself (lt, kd, emit, analyze, operand, effect, refuse, prepare, allprocs...) are compiled like any
# other: the translator reads its inputs from the program's definitions, not from what is defined under the name in its own interpreter by the time it needs them.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "names: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/p.tcl" <<'TCL'
proc lt {a b} { set r 0; for {set i 0} {$i < 3} {incr i} { incr r [expr {$a < $b}] }; return $r }
proc analyze {x} { set s 0; foreach v $x { incr s $v }; return $s }
proc emit {n} { set t 0; for {set i 0} {$i < $n} {incr i} { incr t $i }; return $t }
proc kd {x} { set y [expr {$x * 2}]; return [expr {$y + 1}] }
proc operand {a {b 5}} { set s 0; for {set i 0} {$i < $a} {incr i} { incr s $b }; return $s }
proc effect {n} { set s 0; foreach c {1 2 3} { incr s [expr {$c * $n}] }; return $s }
proc prepare {x} { set n 0; foreach c [split $x {}] { incr n [scan $c %c] }; return $n }
proc refuse {a b} { set r 1; for {set i 0} {$i < $b} {incr i} { set r [expr {$r * $a}] }; return $r }
proc allprocs {x} { set s 0; for {set i 0} {$i < 3} {incr i} { incr s [expr {$x + $i}] }; return $s }
proc ordinary {n} { return [list [lt 1 2] [analyze {1 2 3}] [emit 10] [kd 4] [operand 3] [operand 3 2] [effect 2] [prepare abc] [refuse 2 3] [allprocs 4]] }
TCL
cat > "$tmp/run.tcl" <<'TCL'
if {[info exists ::env(NAMES_COMPILED)]} { load {} Names }
source $::env(NAMES_PROCS)
puts [ordinary 1]
if {[info exists ::env(NAMES_COMPILED)]} { puts "attached: [lsort [tbc::attached]]" }
TCL
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/p.c" Names >"$tmp/tr.log" 2>&1 || { echo "names: translation failed"; tail -3 "$tmp/tr.log"; exit 1; }
"$CC" -O1 -w -DMODULE=Names $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" 2>"$tmp/cc.log" || { echo "names: build failed"; tail -3 "$tmp/cc.log"; exit 1; }
want=$(NAMES_PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1)
got=$(NAMES_COMPILED=1 NAMES_PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1)
[ "$(echo "$got" | head -1)" = "$(echo "$want" | head -1)" ] || { echo "names: FAILED, results differ: interpreter '$(echo "$want" | head -1)', compiled '$(echo "$got" | head -1)'"; exit 1; }
for p in lt analyze emit kd operand effect prepare refuse allprocs ordinary; do
  echo "$got" | grep '^attached:' | grep -q "::$p\b" || { echo "names: FAILED, ::$p was left to the interpreter ($(echo "$got" | grep '^attached:'))"; exit 1; }
done
echo "names: procs named like the translator's own are compiled and give the interpreter's results: ok"

# every entry of a module carries its fingerprint as hexadecimal digits (a fingerprint such as 53240e9073862955 read as a number by expr gave 0xInf once)
"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/all.c" Allprocs -hints tests/hints.txt >"$tmp/tr2.log" 2>&1 || { echo "names: translation of tests/procs.tcl failed"; tail -3 "$tmp/tr2.log"; exit 1; }
bad=$(grep -o 'UINT64_C(0x[^)]*)' "$tmp/all.c" | grep -v -E '^UINT64_C\(0x[0-9a-f]{1,16}\)$' | head -3)
[ -z "$bad" ] || { echo "names: FAILED, an entry has a fingerprint that is not hexadecimal digits: $bad"; exit 1; }
echo "names: every fingerprint in the module of the test procs is a hexadecimal number: ok"

