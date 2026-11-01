#!/bin/bash
# The tclbench programs, interpreted and compiled: for each file, a run with the capture on (the procs it builds), a module from what was captured, then the
# file again, interpreted and compiled, timed by harness.tcl.   bench/real/run.sh [file.bench ...]   (bench/real/fetch.sh first)
cd "$(dirname "$0")/../.." || exit 1
. tools/env.sh || exit 1
dir=build/tclbench/tclbench/tcl
[ -d $dir ] || { echo "run bench/real/fetch.sh first" >&2; exit 1; }
files=("$@"); [ ${#files[@]} -eq 0 ] && files=($dir/*.bench)
H=$(realpath bench/real/harness.tcl); export H
tmp=${KEEP:-$(mktemp -d)}; [ -z "$KEEP" ] && trap "rm -rf $tmp" EXIT; mkdir -p $tmp
cat > "$tmp/main.c" <<'C'
#include <tcl.h>
extern int MODINIT(Tcl_Interp *);
static int AppInit(Tcl_Interp *interp) { if (Tcl_Init(interp) != TCL_OK) return TCL_ERROR; Tcl_StaticPackage(NULL, "Realbench", MODINIT, NULL); return MODINIT(interp); }
int main(int argc, char **argv) { Tcl_Main(argc, argv, AppInit); return 0; }
C
printf 'proc tbc_none {} {}\n' > "$tmp/none.tcl"
"$TCLSH" src/translate.tcl "$tmp/none.tcl" "$tmp/none.c" Realbench >/dev/null 2>&1
"$CC" -O1 -w -DMODINIT=Realbench_Init $TBC_INC "$tmp/main.c" "$tmp/none.c" $TBC_LIBS -o "$tmp/shell0" || exit 1
cat > "$tmp/cap.tcl" <<'C'
tbc::capture on
set argv [list $env(BF)]
cd [file dirname $env(BF)]
catch { source $env(H) }
tbc::capture write $env(CAPTURED)
C
printf "%-14s %-38s %10s %10s %8s\n" file benchmark "interp ns" "comp ns" speedup
for f in "${files[@]}"; do
  b=$(basename $f .bench); w="$tmp/$b"; mkdir -p $w
  BF=$(realpath $f) CAPTURED=$w/cap.tcl timeout 300 "$tmp/shell0" "$tmp/cap.tcl" >/dev/null 2>&1 </dev/null
  [ -s $w/cap.tcl ] || { echo "$b: nothing captured"; cp /dev/null $w/cap.tcl; }
  # (the harness's own procs are left to the interpreter: the timing runs inside `bench`)
  python3 - $w/cap.tcl <<'PY'
import re, sys
p = sys.argv[1]; src = open(p).read()
out, keep, depth = [], True, 0
for line in src.splitlines(True):
    if depth == 0: keep = not re.match(r'proc ::bench(_tmpfile|_rm)? ', line)
    if keep: out.append(line)
    depth += line.count('{') - line.count('}')
open(p, 'w').write(''.join(out))
PY
  "$TCLSH" src/translate.tcl $w/cap.tcl $w/m.c Realbench >$w/tr.log 2>&1 || { echo "$b: translate failed"; continue; }
  "$CC" -O2 -w -DMODINIT=Realbench_Init $TBC_INC "$tmp/main.c" $w/m.c $TBC_LIBS -o $w/shell >$w/cc.log 2>&1 || { echo "$b: build failed"; continue; }
  ( cd $(dirname $f); timeout 300 $w/shell $H $(basename $f) > $w/i.txt 2>&1 </dev/null )
  ( cd $(dirname $f); COMPILED=1 timeout 300 $w/shell $H $(basename $f) > $w/c.txt 2>&1 </dev/null )
  python3 "$(dirname "$H")/compare.py" $b $w/i.txt $w/c.txt
done
