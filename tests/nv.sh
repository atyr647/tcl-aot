#!/bin/bash
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
proc nv_loop {n} { set s 0.0; for {set i 0} {$i < $n} {incr i} { set s [expr {$s + [nv_var $i] + [nv_up $i] + [nv_abs $i]}] }; return $s }
TCL
cat > "$tmp/run.tcl" <<'TCL'
load {} Nvtest
source $::env(NV_PROCS)
set r1 [nv_loop 1000]
set d [tbc::hot -dict]
proc check {what cond} { if {![uplevel 1 [list expr $cond]]} { puts "FAILED: $what"; incr ::bad } }
set bad 0
foreach p {::nv_var ::nv_up ::nv_abs} {
    # (entered from typed code: the entries of the first call may come from the interpreter's)
    check "$p typed entries" {[lindex [dict get $d $p entries] 1] >= 999}
    check "$p never hands over" {[dict get $d $p handovers] == 0}
}
check "the loop does not hand over" {[dict get $d ::nv_loop handovers] == 0}
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
out=$(NV_PROCS="$tmp/p.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { echo "$out"; echo "nv: FAILED"; exit 1; }
echo "$out" | grep -q '^ok$' || { echo "$out"; echo "nv: FAILED"; exit 1; }
echo "nv: procs that read namespace variables are called directly, with no frame, and hand over without effect when the variable is not as usual: ok"
