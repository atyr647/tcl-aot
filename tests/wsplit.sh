#!/bin/sh
# Decision 82: (1) a tagged-number argument (an integer or a double known only at run time) to a pure callee whose double variant returns a double calls the double variant
# when the value is a double: no object is made for the argument or the result (ws_loop calls ws_sq on `$e * 3`, e an element of a list; ws_loop32 does the same with f32 and builds a list); (2) `lmap` is typed:
# its body's value is appended in C (lc_* procs), so a loop of lmap never hands over.  In a module built with -DTBC_COV: the loops run typed with no hand-over, the
# translated code of ws_loop calls V_ws_sq_D, and the TBC_REPORT of lc_d/lc_two/lc_f has no unsupported instruction.  The results are compared by the
# differential test (ws_* and lc_* calls); here the values are also checked against the interpreter's by hand.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "wsplit: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/run.tcl" <<'TCL'
load {} Wstest
source $::env(WS_PROCS)
# the interpreter's answers, from reference procs defined here under other names (the module compiles only the procs of the file it was built from)
proc ref_f32 {x} { binary scan [binary format f $x] f x; return $x }
set bad 0
proc check {what got want} { global bad; if {$got ne $want} { puts "FAILED: $what: got {$got}, wanted {$want}"; incr bad } }
set l {1.5 2.25 3 4.75 -0.5 1e10 0.1}
set want {}; foreach e $l { lappend want [ref_f32 [expr {$e - 1}]] }
tbc::hot -reset
check ws_loop32 [ws_loop32 $l] $want
set s 0.0; foreach e $l { set s [expr {$s + ($e * 3 * 2.0 + 1)}] }
check ws_loop [ws_loop $l] $s
set want {}; foreach e $l { lappend want [expr {$e * 0.5}] }
check lc_d [lc_d $l] $want
set a {1 2 3 4}; set b {10 20 30 40}
set want {}; foreach p $a q $b { lappend want [expr {$p - $q}] }
check lc_two [lc_two $a $b] $want
set want {}; foreach p $l { lappend want [ref_f32 [expr {$p * 0.5}]] }
check lc_f [lc_f $l] $want
set d [tbc::hot -dict]
foreach p {::ws_loop ::lc_d ::lc_two ::lc_f} {
    if {![dict exists $d $p]} { puts "FAILED: $p not counted"; incr bad; continue }
    if {[dict get $d $p entries] < 1} { puts "FAILED: $p did not run typed"; incr bad }
    if {[dict get $d $p handovers] > 0} { puts "FAILED: $p hands over [dict get $d $p handovers] times"; incr bad }
}
if {$bad} { exit 1 }
puts "ok"
TCL
"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/p.c" Wstest -hints tests/hints.txt >"$tmp/translate.log" 2>&1 || { echo "wsplit: translation failed"; tail -3 "$tmp/translate.log"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Wstest $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "wsplit: build failed"; exit 1; }
out=$(TBC_NOLITE=1 WS_PROCS="$PWD/tests/procs.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "wsplit: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "wsplit: FAILED"; exit 1; }
# the translated code: ws_loop, alone, calls the double variant of ws_sq; lc_d, lc_two and lc_f have no unsupported instruction
{ sed -n '/^proc ws_f32/p;/^proc ws_sq/p' tests/procs.tcl; sed -n '/^proc ws_loop /p;/^proc lc_d /p;/^proc lc_two/p;/^proc lc_f /p' tests/procs.tcl; } > "$tmp/one.tcl"
TBC_REPORT=1 "$TCLSH" src/translate.tcl "$tmp/one.tcl" "$tmp/one.c" Wsone >"$tmp/translate1.log" 2>&1 || { echo "wsplit: translation of the small file failed"; exit 1; }
if ! grep -q 'V__3a_3aws_5fsq_D(interp' "$tmp/one.c"; then echo "wsplit: FAILED: ws_loop does not call the double variant of ws_sq"; exit 1; fi
if grep '^REPORT ::lc_' "$tmp/translate1.log" | grep -v ' 0 unsupported' | grep -q .; then echo "wsplit: FAILED: an lmap proc has an unsupported instruction"; grep '^REPORT ::lc_' "$tmp/translate1.log" | grep -v ' 0 unsupported'; exit 1; fi
# the index word of lset (ls_loop: `lset a $y+$x ...`) builds no string
sed -n '/^proc ls_loop /p' tests/procs.tcl > "$tmp/two.tcl"
"$TCLSH" src/translate.tcl "$tmp/two.tcl" "$tmp/two.c" Wstwo >"$tmp/translate2.log" 2>&1 || { echo "wsplit: translation of ls_loop failed"; exit 1; }
if grep -q 'tbc_cat_init' "$tmp/two.c"; then echo "wsplit: FAILED: ls_loop makes a string for an index word"; exit 1; fi
echo "wsplit: a tagged-number argument picks the double variant, lmap is typed (no hand-over, no unsupported instruction): ok"
