#!/bin/bash
# The reports that say how well compiled code does: TBC_REPORT=1 (at translation: how much of each proc is typed code, what it cannot do) and tbc::hot (at run
# time, in a module built with -DTBC_COV: where typed code handed over, per proc and instruction).  Checked in a single-file build and in a split one (the counters
# are shared state there), and a build without -DTBC_COV must have no tbc::hot.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
[ -x "$TCLSH" ] || { echo "hot: $TCLSH not built; run 'make shell'" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/p.tcl" <<'TCL'
proc h_sum {l} { set s 0; foreach v $l { set s [expr {$s + $v}] }; return $s }
proc h_ok {x} { return [expr {$x * 2}] }
proc h_dict {d} { set n 0; dict for {k v} $d { incr n $v }; return $n }
proc h_cmp {a b} { if {[lindex $a 0] == $a && [lindex $b 0] == $b} { return 1 }; if {$a != "left"} { return 2 }; return 3 }
proc h_nan {x} { set NaN $x; set Inf [expr {$NaN + 1}]; return $Inf }
proc h_two {n} { set x [dict create a 1]; dict for {k v} $x { }; return $n }
TCL
cat > "$tmp/run.tcl" <<'TCL'
load {} Hot
source $::env(HOT_PROCS)
set l {}; for {set i 0} {$i < 50} {incr i} { lappend l [expr {$i * 0.5}] }
for {set k 0} {$k < 6} {incr k} { h_sum $l; h_ok $k; h_dict {a 1 b 2} }
h_two 5; h_two abc; h_two 7
foreach x {{a b c} abc 1.5 {} left {1 2}} { h_cmp $x $x; h_cmp $x abc }
if {[info exists ::env(HOT_NONE)]} { puts "hot-command: [llength [info commands tbc::hot]]"; exit }
set d [tbc::hot -dict]
proc check {what cond} { if {![uplevel 1 [list expr $cond]]} { puts "FAILED: $what"; incr ::bad } }
set bad 0
# a proc that never hands over: entered every time, no sites
check "h_ok entries" {[dict get $d ::h_ok entries] eq "B 6" || [dict get $d ::h_ok entries] eq "I 6"}
check "h_ok never hands over" {[dict get $d ::h_ok handovers] == 0 && [dict get $d ::h_ok sites] eq ""}
# the sum meets doubles: the first call hands over at the add (a guard), and every call, that one included, goes on in the tagged version from the loop head
check "h_sum hands over at the add once" {[lindex [dict get $d ::h_sum sites] 0 1] eq "add" && [lindex [dict get $d ::h_sum sites] 0 3] eq "guard" && [lindex [dict get $d ::h_sum sites] 0 4] == 1}
check "h_sum resumed in the w variant" {[dict get $d ::h_sum resumed] == 6 && [dict get $d ::h_sum resumes] eq "Bw 6" && [dict get $d ::h_sum entries] eq "B 1"}
# an instruction typed code has no code for hands over at every call, and the report names it
check "h_dict unsupported site" {[lindex [dict get $d ::h_dict sites] 0 1] eq "dictFirst" && [lindex [dict get $d ::h_dict sites] 0 3] eq "unsupported" && [lindex [dict get $d ::h_dict sites] 0 4] == 6}
set text [tbc::hot -top 1]
check "text names the proc and the instruction" {[string match "*::h_dict: typed entries 6*dictFirst*unsupported*" $text]}
check "-top limits the sites" {![string match "*more sites*" [tbc::hot -top 5]]}
tbc::hot -reset
check "reset" {![dict exists [tbc::hot -dict] ::h_dict]}
# the integer and the object variant of one proc hand over at the same instruction: one site, the hits of both
check "sites of the variants of a proc are merged" {[llength [dict get $d ::h_two sites]] == 1 && [lindex [dict get $d ::h_two sites] 0 4] == 3}
# == and != of objects that are not integers (text, lists, doubles) are done in typed code, by the generic comparison: no hand-over at them
check "comparisons of text and lists stay typed" {[dict get $d ::h_cmp handovers] == 0 && [dict get $d ::h_cmp sites] eq ""}
check "bad option" {[catch {tbc::hot -nosuch}]}
puts "checks failed: $bad"
TCL
rep=$(TBC_REPORT=1 "$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/one.c" Hot 2>&1 >/dev/null | grep '^REPORT')
echo "$rep" | grep -q '^REPORT ::h_ok/B .*100%.*0 unsupported' || { echo "hot: FAILED, the report of h_ok:"; echo "$rep"; exit 1; }
echo "$rep" | grep -q '^REPORT     unsupported: dictFirst@' || { echo "hot: FAILED, the report does not list dictFirst as unsupported:"; echo "$rep"; exit 1; }
echo "$rep" | grep -q '^REPORT ::h_nan/.*locals.*NaN=' || { echo "hot: FAILED, the report of a proc with variables named NaN and Inf:"; echo "$rep" | grep h_nan; exit 1; }
echo "$rep" | grep -q '^REPORT ::h_sum/Bw ' || { echo "hot: FAILED, the report has no line for the tagged variant of h_sum"; exit 1; }
echo "hot: TBC_REPORT lists the typed share of every variant and the unsupported instructions: ok"
"$TCLSH" src/translate.tcl "$tmp/p.tcl" "$tmp/split.c" Hot -split 2 >/dev/null 2>&1 || { echo "hot: split translation failed"; exit 1; }
tools/build-module.sh "$tmp/split.c" "$tmp/split.o" -j 2 >/dev/null 2>&1 || { echo "hot: plain split build failed"; exit 1; }
for mode in single split; do
  if [ $mode = single ]; then src="$tmp/one.c"; else
    CFLAGS_V="-O1 -DTBC_COV" CFLAGS_G="-O1 -DTBC_COV" CFLAGS_I="-O1 -DTBC_COV" tools/build-module.sh "$tmp/split.c" "$tmp/split_cov.o" >"$tmp/b.log" 2>&1 || { echo "hot: counter build (split) failed"; tail -5 "$tmp/b.log"; exit 1; }
    src="$tmp/split_cov.o"
  fi
  "$CC" -O1 -w -DTBC_COV -DMODULE=Hot $TBC_INC tools/module-shell.c "$src" $TBC_LIBS -o "$tmp/shell_$mode" 2>"$tmp/cc.log" || { echo "hot: linking the $mode counter shell failed"; tail -5 "$tmp/cc.log"; exit 1; }
  out=$(HOT_PROCS="$tmp/p.tcl" "$tmp/shell_$mode" "$tmp/run.tcl" 2>&1)
  echo "$out" | grep -q '^checks failed: 0$' || { echo "hot: FAILED, tbc::hot in the $mode build:"; echo "$out" | head; exit 1; }
done
echo "hot: tbc::hot reports entries, resumes and hand-over sites per proc, in a single-file and in a split build: ok"
"$CC" -O1 -w -DMODULE=Hot $TBC_INC tools/module-shell.c "$tmp/one.c" $TBC_LIBS -o "$tmp/shell_none" 2>"$tmp/cc.log" || { echo "hot: linking the plain shell failed"; exit 1; }
out=$(HOT_NONE=1 HOT_PROCS="$tmp/p.tcl" "$tmp/shell_none" "$tmp/run.tcl" 2>&1)
echo "$out" | grep -q '^hot-command: 0$' || { echo "hot: FAILED, a module built without -DTBC_COV has tbc::hot: $out"; exit 1; }
echo "hot: a module built without -DTBC_COV has no counters and no tbc::hot: ok"
