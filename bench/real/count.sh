#!/bin/bash
# The tclbench programs by instruction count (callgrind), interpreted and compiled, net of start-up: one run of every body, so a program's figure is the sum over its
# benchmarks.  Instruction counts do not vary from run to run, so they rank the work.   bench/real/count.sh [file.bench ...]
cd "$(dirname "$0")/../.." || exit 1
. tools/env.sh || exit 1
dir=build/tclbench/tclbench/tcl
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
cnt() { ( cd $(dirname $1); shift; env "$@" valgrind --tool=callgrind --callgrind-out-file=/dev/null 2>&1 >/dev/null | grep -o "Collected : [0-9]*" | cut -d' ' -f3 ); }
printf "%-12s %14s %14s %8s\n" file "interp Minstr" "compiled Minstr" ratio
for f in "${files[@]}"; do
  b=$(basename $f .bench); w="$tmp/$b"; mkdir -p $w; f=$(realpath $f)
  BF=$f CAPTURED=$w/cap.tcl COUNT=1 timeout 600 "$tmp/shell0" "$tmp/cap.tcl" >/dev/null 2>&1 </dev/null
  [ -s $w/cap.tcl ] || : > $w/cap.tcl
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
  "$CC" -O2 -g -w -DMODINIT=Realbench_Init $TBC_INC "$tmp/main.c" $w/m.c $TBC_LIBS -o $w/shell >$w/cc.log 2>&1 || { echo "$b: build failed"; continue; }
  d=$(dirname $f); n=$(basename $f)
  i0=$(cnt $f SKIP=1 $w/shell $H $n); i1=$(cnt $f COUNT=1 $w/shell $H $n)
  c0=$(cnt $f SKIP=1 COMPILED=1 $w/shell $H $n); c1=$(cnt $f COUNT=1 COMPILED=1 $w/shell $H $n)
  python3 -c "
i=($i1-$i0)/1e6; c=($c1-$c0)/1e6
print('%-12s %14.1f %14.1f %7.2fx' % ('$b', i, c, i/c if c > 0 else 0))"
done
