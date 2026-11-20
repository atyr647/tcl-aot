#!/bin/sh
# Decision 81: the index word of lindex written `$i+1`, `$i-$j` is the integer it names: the typed code makes no string for it and parses none, and a loop of such reads never hands over
# for indices that are canonical integers.  The results are compared by the differential test (ix_* procs); this checks, in a module built with -DTBC_COV, that ix_loop (the reads
# `$i+1`, `$i-1`, `$n-$i`, `$i-$n` over a list read from the frame, in range and out of range) never hands over, that an index that is text (`abc`, `007`, `1.5`) does hand over and gives
# Tcl's result or error, and that the translated code of ix_loop builds no string for these words.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "indexword: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/run.tcl" <<'TCL'
load {} Ixtest
source $::env(IX_PROCS)
set bad 0
set l {a b c d e f g h i j}
set r [ix_loop $l 10]
set d [tbc::hot -dict]
if {![dict exists $d ::ix_loop]} { puts "FAILED: ix_loop not counted"; incr bad } else {
    if {[dict get $d ::ix_loop entries] < 1} { puts "FAILED: ix_loop did not run typed"; incr bad }
    if {[dict get $d ::ix_loop handovers] > 0} { puts "FAILED: ix_loop hands over [dict get $d ::ix_loop handovers] times"; incr bad }
}
# the interpreter's answer, by hand
set want {}
for {set i 0} {$i < 10} {incr i} {
    foreach k [list [expr {$i + 1}] [expr {$i - 1}] [expr {10 - $i}] [expr {$i - 10}]] { lappend want [lindex $l $k] }
    lappend want [expr {[lindex $l [expr {$i + 1}]] eq "" ? 0 : 1}]
}
# (the order of the appends of ix_loop: $i+1 $i-1 $n-$i $i-$n then the flag)
if {$r ne $want} { puts "FAILED: ix_loop gives $r, wanted $want"; incr bad }
foreach {i j} {abc 1 007 1 1.5 1 1 abc 1 1.5} {
    tbc::hot -reset
    set a [catch {ix_obj $l $i $j} ra]
    set b [catch {lindex $l $i+$j} rb]
    if {$a != $b || $ra ne $rb} { puts "FAILED: ix_obj $i $j: $a $ra against $b $rb"; incr bad }
}
if {$bad} { exit 1 }
puts "ok"
TCL
"$TCLSH" src/translate.tcl tests/procs.tcl "$tmp/p.c" Ixtest -hints tests/hints.txt >"$tmp/translate.log" 2>&1 || { echo "indexword: translation failed"; tail -3 "$tmp/translate.log"; exit 1; }
"$CC" -O1 -w -DTBC_COV -DMODULE=Ixtest $TBC_INC tools/module-shell.c "$tmp/p.c" $TBC_LIBS -o "$tmp/shell" || { echo "indexword: build failed"; exit 1; }
out=$(TBC_NOLITE=1 IX_PROCS="$PWD/tests/procs.tcl" "$tmp/shell" "$tmp/run.tcl" 2>&1) || { printf '%s\n' "$out"; echo "indexword: FAILED"; exit 1; }
printf '%s\n' "$out" | grep -q '^ok$' || { printf '%s\n' "$out"; echo "indexword: FAILED"; exit 1; }
# no string is built for the index words of ix_loop: its typed variants have no tbc_cat_init
sed -n '/^proc ix_loop/,/^}/p' tests/procs.tcl > "$tmp/one.tcl"
"$TCLSH" src/translate.tcl "$tmp/one.tcl" "$tmp/one.c" Ixone >"$tmp/translate1.log" 2>&1 || { echo "indexword: translation of ix_loop failed"; exit 1; }
if grep -q 'tbc_cat_init' "$tmp/one.c"; then echo "indexword: FAILED: ix_loop makes a string for an index word"; exit 1; fi
echo "indexword: the index words of lindex are integers in typed code (no hand-over in a loop, text hands over, no string built): ok"
