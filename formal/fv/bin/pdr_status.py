# formal/fv/bin/pdr_status.py <sby task dir, e.g. build/fv/mmu_cache_tiny/safet/safet>: per-assert PDR status (P proved / - open), with source line
import json, re, sys, os
f = sys.argv[1]
d = json.load(open(os.path.join(f, 'model/design_aiger.ywa')))
log = open(os.path.join(f, 'logfile.txt'), errors='replace').read()
proved = {int(m) for m in re.findall(r'Proved output (\d+)', log)}
srcs = {}
for i, a in enumerate(d['asserts']):
    m = re.search(r'assert_(\w+?)_sv_(\d+)_', a[-1])
    fn, ln = (m.group(1) + '.sv', int(m.group(2))) if m else ('?', 0)
    if fn not in srcs:
        p = os.path.join(f, 'src', fn)
        srcs[fn] = open(p).read().split('\n') if os.path.exists(p) else []
    txt = srcs[fn][ln - 1].strip()[:70] if 0 < ln <= len(srcs[fn]) else ''
    print('P' if i in proved else '-', i, fn, ln, txt)
