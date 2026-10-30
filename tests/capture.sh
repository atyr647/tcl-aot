#!/bin/bash
# The capture loop: a program builds procs from text at run time, so a module built from its source holds no code for them.  Run it once with the
# capture on, translate what was captured, build a module from that, and run the program again: its procs now run compiled, with the same results.
cd "$(dirname "$0")/.." || exit 1
. tools/env.sh || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/app.tcl" <<'APP'
# builds procs from text at run time, as sha1's transform body is built with regsub
set body {set s 0; for {set i 0} {$i < $n} {incr i} { set s [expr {($s + $i * @K@) % 1000003}] }; return $s}
foreach k {3 5 7} { proc [format "gen_%d" $k] {n} [string map [list @K@ $k] $body] }
namespace eval ::appns { proc scale {x {f 2}} { expr {$x * $f} } }
set r {}
foreach k {3 5 7} { lappend r [gen_$k 1000] }
lappend r [::appns::scale 21]
puts "RESULT $r"
if {[llength [info commands tbc::report]]} { puts "COMPILED [llength [tbc::attached]]" }
APP
cat > "$tmp/main.c" <<'C'
#include <tcl.h>
#ifdef WITH_CAPTURED
extern int Capprocs_Init(Tcl_Interp *);
#else
extern int Tbconly_Init(Tcl_Interp *);
#endif
static int AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) != TCL_OK) return TCL_ERROR;
#ifdef WITH_CAPTURED
    return Capprocs_Init(interp);
#else
    return Tbconly_Init(interp);
#endif
}
int main(int argc, char **argv) { Tcl_Main(argc, argv, AppInit); return 0; }
C

# 1. a module with no procs (only the runtime); run the program with the capture on
printf 'proc tbc_none {} {}\n' > "$tmp/none.tcl"
"$TCLSH" src/translate.tcl "$tmp/none.tcl" "$tmp/none.c" Tbconly >"$tmp/none.log" 2>&1 || { echo "capture: translation failed"; tail -3 "$tmp/none.log"; exit 1; }
"$CC" -O1 -w $TBC_INC "$tmp/main.c" "$tmp/none.c" $TBC_LIBS -o "$tmp/shell0" 2>&1 | grep error
cat > "$tmp/run0.tcl" <<'R'
tbc::capture on
source $env(APP)
tbc::capture write $env(CAPTURED)
puts "captured: [tbc::capture count]"
R
APP=$tmp/app.tcl CAPTURED=$tmp/captured.tcl "$tmp/shell0" "$tmp/run0.tcl" >"$tmp/run0.out" 2>&1
grep -E 'RESULT|captured' "$tmp/run0.out"

# 2. translate what was captured and build a module from it
"$TCLSH" src/translate.tcl "$tmp/captured.tcl" "$tmp/cap.c" Capprocs >"$tmp/cap.log" 2>&1 || { echo "capture: translating the captured file failed"; tail -3 "$tmp/cap.log"; exit 1; }
grep -E '^tcl-aot:' "$tmp/cap.log"
"$CC" -O1 -w -DWITH_CAPTURED $TBC_INC "$tmp/main.c" "$tmp/cap.c" $TBC_LIBS -o "$tmp/shell1" 2>&1 | grep error

# 3. the program again, unmodified, with the extended module
"$tmp/shell1" "$tmp/app.tcl" >"$tmp/run1.out" 2>&1
cat "$tmp/run1.out"
before=$(grep RESULT "$tmp/run0.out"); after=$(grep RESULT "$tmp/run1.out")
compiled=$(grep COMPILED "$tmp/run1.out" | awk '{print $2}')
if [ -n "$before" ] && [ "$before" = "$after" ] && [ "${compiled:-0}" -ge 4 ]; then
  echo "capture: the procs built at run time now run compiled, with the same results: ok"
else
  echo "capture: FAILED (before: $before; after: $after; compiled: ${compiled:-0})"; exit 1
fi
