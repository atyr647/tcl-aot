#!/bin/sh
# Procs that only read namespace variables (`variable`, `upvar #0`, `global`, `$::ns::var`) are called directly by compiled code, with no frame (decision 57): in a module built
# with -DTBC_COV, a compiled loop that calls them 1000 times enters their typed code 1000 times and never hands over, and the interpreter is not used for the calls.  When a variable
# is missing or has a trace the same calls are made the ordinary way (the results are the interpreter's: tests/differential.tcl compares them; here only that the fall-back happens).
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "nv: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/p.tcl" <<'TCL'
namespace eval nvx { variable K 3.0; variable F; array set F {a 1.5 b 2} }
proc nv_var {x} { variable ::nvx::K; return [expr {$x * $K + 0.5}] }
proc nv_up {x} { upvar #0 ::nvx::K k; return [expr {$x + $k + 0.5}] }
proc nv_abs {x} { return [expr {$x * $::nvx::K + $::nvx::F(a) + 0.5}] }
# a loop-free helper that takes doubles and multiplies list elements (objects) by them: no sign of floating-point numbers but the argument kinds, so tagged numbers must be used
# in the variants that take a double (it handed over at the multiplication in every call, and the whole call was made by the interpreter)
proc nv_at {pl b x y} { return [expr {[lindex $pl $b] + [lindex $pl $b+1] * $x + [lindex $pl $b+2] * $y}] }
proc nv_at_loop {n} { set pl {0.5 1.5 2.5 3.5 4.5 5.5}; set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [nv_at $pl 1 [expr {$i * 0.5}] 1.25]}] }; return $s }
# a loop-free helper with no sign of floating-point numbers called by the interpreter with doubles: it has no loop for the adaptive version to re-enter, so the variant that takes
# objects uses tagged numbers from the start (decision 70) and does not hand over in every call
proc nv_wl {a b} { return [expr {$a * $b + $a}] }
proc nv_loop {n} { set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [nv_var $i] + [nv_up $i] + [nv_abs $i]}] }; return $s }
TCL
cat > "$tmp/run.tcl" <<'TCL'
load {} Nvtest
source $::env(NV_PROCS)
set r1 [nv_loop 1000]
set r3 [nv_at_loop 1000]
set wl 0.0
for {set i 0} {$i < 500} {incr i} { set wl [expr {$wl + [nv_wl [expr {$i * 0.5}] 3]}] }
set wl2 [nv_wl 7 6]
set d [tbc::hot -dict]
proc check {what cond} { if {![uplevel 1 [list expr $cond]]} { puts "FAILED: $what"; incr ::bad } }
set bad 0
foreach p {::nv_var ::nv_up ::nv_abs} {
    # (entered from typed code: the entries of the first call may come from the interpreter's)
    check "$p typed entries" {[lindex [dict get $d $p entries] 1] >= 999}
    check "$p never hands over" {[dict get $d $p handovers] == 0}
}
check "the loop does not hand over" {[dict get $d ::nv_loop handovers] == 0}
# (the first call is the interpreter's, which attaches the compiled body and enters with objects, where the integer variant meets a double once)
check "a helper that takes doubles hands over at most once, not in every call" {[dict get $d ::nv_at handovers] <= 1 && [lindex [dict get $d ::nv_at entries] end] >= 998}
check "and gives the interpreter's result" {$r3 == 630250.0}
check "a loop-free helper called with doubles by the interpreter does not hand over" {[dict get $d ::nv_wl handovers] == 0 && [dict get $d ::nv_wl entries BB] >= 500}
check "and gives the interpreter's result" {$wl == 249500.0 && $wl2 == 49}
tbc::hot -reset
# a trace on the variable: the calls are made the ordinary way, and give the interpreter's results
set ::log {}
proc tr {args} { lappend ::log $args }
trace add variable ::nvx::K read tr
set r2 [nv_loop 3]
trace remove variable ::nvx::K read tr
check "traced reads happened" {[llength $::log] == 9}
check "the loop still gives the same result" {$r2 eq [nv_loop 3] && abs($r2 - 3 * 0.0) > 0}
puts "nv: $r1 $r2"
if {$bad} { exit 1 }
puts "ok"
TCL
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/m.c" Nvtest >"$tmp/translate.log" 2>&1 || { echo "nv: translation failed"; tail -3 "$tmp/translate.log"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Nvtest $TBC_INC tools/module-shell.c "$tmp/m.c" $TBC_LIBS -o "$tmp/shell" || { echo "nv: build failed"; exit 1; }
out=$(NV_PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "nv: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "nv: FAILED"; exit 1; }
echo "nv: procs that read namespace variables are called directly, with no frame, and hand over without effect when the variable is not as usual: ok"
