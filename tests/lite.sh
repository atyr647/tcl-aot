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
# loops that typed code cannot go round without handing over (`info proc` is a command it has no code for): left to the interpreter while what typed code does before it is light
# (lt_hlook: weight 300), the entry kept when it is heavy (lt_hheavy: 3150); a loop that typed code can go round (lt_hfree: the call is in a branch) keeps the entry
proc lt_hlook {method args} {
    foreach anc $::lt_b {
        if {[llength [info proc ${anc}::$method]]} { return [eval [linsert $args 0 ${anc}::$method]] }
    }
}
proc lt_hheavy {l} { set s 0; foreach x $l { set s [expr {$s + $x * 3 + $x * 5 + $x * 7 + $x * 9 + $x * 11 + $x * 13}]; if {[llength [info proc nonesuch]]} { incr s } }; return $s }
proc lt_hfree {l} { set s 0; foreach x $l { if {$x < 0} { if {[llength [info proc nonesuch]]} { incr s } } else { incr s $x } }; return $s }
namespace eval ::lt_dad { proc test {{x 5} args} { set x } }
set ::lt_b [list ::lt_dad ::none]
TCL
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/p.c" Liteprocs >"$tmp/tr.log" 2>&1 || { echo "lite: translation failed"; tail -3 "$tmp/tr.log"; exit 1; }
# the entry of a proc ends with its yres, ens and lite fields
lite() { local n=${1//_/_5f}; grep -E "^static TbcEntry tbc_e__3a_3a$n " "$tmp/p.c" | sed -E 's/.*, ([01]) \};$/\1/'; }
for p in lt_tiny lt_str lt_call lt_cmp lt_cb; do [ "$(lite $p)" = 1 ] || { echo "lite: FAILED, $p is not left to the interpreter"; exit 1; }; done
for p in lt_hlook; do [ "$(lite $p)" = 1 ] || { echo "lite: FAILED, $p is a loop typed code cannot go round and light, and is not left to the interpreter"; exit 1; }; done
for p in lt_loop lt_rec lt_hheavy lt_hfree; do [ "$(lite $p)" = 0 ] || { echo "lite: FAILED, $p is a loop or a recursion and must get the entry"; exit 1; }; done
echo "lite: small loop-free procs and light loops that hand over in every round are left to the interpreter, other loops, heavy ones and recursions are not: ok"
"$CC" -O1 -w -DMODULE=Liteprocs $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "lite: build failed"; exit 1; }
cat > "$tmp/run.tcl" <<'TCL'
if {[info exists ::env(COMPILED)]} { load {} Liteprocs }
source $::env(PROCS)
set r {}
foreach x {0 1 5 -3} { lappend r [lt_tiny $x] [lt_call $x] }
lappend r [lt_str hello] [lt_loop 50] [lt_rec 12] [lt_cb {5 3 9 1}]
lappend r [lt_hlook test] [lt_hlook test 7] [lt_hlook none] [lt_hheavy {1 2 3}] [lt_hheavy {}] [lt_hfree {1 -2 3}] [lt_hfree {}]
puts $r
puts [catch {lt_tiny} e]:$e
puts [catch {lt_tiny 1 2} e]:$e
puts [catch {lt_tiny abc} e]:$e
puts [catch {lt_hheavy abc} e]:$e
puts [catch {lt_hlook test 1 2 3} e]:$e
TCL
a=$(PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1); b=$(COMPILED=1 PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1)
[ "$a" = "$b" ] || { echo "lite: FAILED, results differ:"; echo "$a"; echo "$b"; exit 1; }
echo "lite: the results (and the errors) are the interpreter's: ok"
