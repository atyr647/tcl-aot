#!/bin/bash
# Where the instructions of one tclbench program go, interpreted against compiled: the functions whose cost differs most (callgrind, 30 runs of each body).
#   KEEP=/tmp/cnt3 bench/real/count.sh file.bench   (builds the shell)   then   bench/real/diff.sh file.bench [n]
cd "$(dirname "$0")/../.." || exit 1
. tools/env.sh || exit 1
f=$(realpath ${1:?file.bench}); b=$(basename $f .bench); n=${2:-15}; sh=${KEEP:-/tmp/cnt3}/$b/shell; H=$(realpath bench/real/harness.tcl)
tmp=$(mktemp -d); trap "rm -rf $tmp" EXIT
for m in X=1 COMPILED=1; do ( cd $(dirname $f); env COUNT=30 $m valgrind --tool=callgrind --callgrind-out-file=$tmp/$m.out $sh $H $(basename $f) >/dev/null 2>&1 ); callgrind_annotate $tmp/$m.out 2>/dev/null | sed -n '/file:function/,$p' | tail -n +3 | sed -E 's/^ *([0-9,]+) \([ 0-9.]+%\)  (.*)$/\1 \2/' | tr -d ',' | sed -E 's/ \[[^]]*\]$//' > $tmp/$m.txt; done
python3 - $tmp/X=1.txt $tmp/COMPILED=1.txt $n <<'PY'
import sys, re
def rd(p):
    d = {}
    for l in open(p):
        m = re.match(r'(\d+) (.*)$', l.strip())
        if m and not m.group(2).startswith('=>'): d[m.group(2)] = d.get(m.group(2), 0) + int(m.group(1))
    return d
i, c, n = rd(sys.argv[1]), rd(sys.argv[2]), int(sys.argv[3])
print("total: interp %.1fM compiled %.1fM" % (sum(i.values())/1e6, sum(c.values())/1e6))
rows = sorted(set(i) | set(c), key=lambda k: -(c.get(k, 0) - i.get(k, 0)))
print("-- compiled spends more in:")
for k in rows[:n]: print("%+12.2fM  %-70.70s  (interp %.2fM, compiled %.2fM)" % ((c.get(k,0)-i.get(k,0))/1e6, k, i.get(k,0)/1e6, c.get(k,0)/1e6))
print("-- compiled spends less in:")
for k in rows[::-1][:n]: print("%+12.2fM  %-70.70s  (interp %.2fM, compiled %.2fM)" % ((c.get(k,0)-i.get(k,0))/1e6, k, i.get(k,0)/1e6, c.get(k,0)/1e6))
PY
