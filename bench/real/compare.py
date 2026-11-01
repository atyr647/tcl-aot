# compare.py <name> <interp.txt> <compiled.txt>: one line per benchmark, interpreted us, compiled us, speedup, and whether the results differ
import re, sys
def read(p):
    r = {}
    for line in open(p, errors='replace'):
        m = re.match(r'BENCH \S+ \{(.*?)\} (\S+) ?(.*)$', line.rstrip('\n'))
        if m: r[m.group(1)] = (m.group(2), m.group(3))
    return r
name, i, c = sys.argv[1], read(sys.argv[2]), read(sys.argv[3])
for d, (it, ir) in i.items():
    if d not in c: print('%-14s %-40.40s %10s %10s  (missing in compiled run)' % (name, d, it, '-')); continue
    ct, cr = c[d]
    flag = '  RESULT DIFFERS' if ir != cr else ''
    if it.isdigit() and ct.isdigit() and int(ct) > 0: print('%-14s %-40.40s %10s %10s %7.2fx%s' % (name, d, it, ct, int(it) / int(ct), flag))
    else: print('%-14s %-40.40s %10s %10s%s' % (name, d, it, ct, flag))
