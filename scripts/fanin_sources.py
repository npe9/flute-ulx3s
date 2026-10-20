#!/usr/bin/env python3
"""Which registers can combinationally reach a set of endpoints?

  fanin_sources.py <yosys.json> <sink-cell-regex> [--port D|...] [--group N]

Sinks: input pins of cells whose name matches the regex (sequential cells:
data/address/enable pins; combinational cells are walked through).  Walks the
combinational fan-in back to sequential outputs (TRELLIS_FF Q, DP16KD/PDPW16KD
DO*, TRELLIS_DPR16X4 DO) and prints the source registers grouped by hierarchy
prefix (first N dotted components after top.soc_top.core.cpu).  P&R-free check
that a pipeline cut really removed a dependence.
"""
import json, re, sys, collections, argparse
ap = argparse.ArgumentParser()
ap.add_argument('json'); ap.add_argument('sink')
ap.add_argument('--group', type=int, default=2)
ap.add_argument('--show', default=None, help='regex: list matching source cells')
ap.add_argument('--port', default=None, help='regex: only sink input pins whose name matches (e.g. CE, DI, M)')
a = ap.parse_args()
d = json.load(open(a.json))
top = [m for m in d['modules'].values() if 'top' in m.get('attributes', {})]
mod = top[0] if top else max(d['modules'].values(), key=lambda m: len(m.get('cells', {})))
SEQ = ('TRELLIS_FF', 'DP16KD', 'PDPW16KD', 'TRELLIS_DPR16X4', 'DPR16X4C')
driver = {}            # bit -> (cell, type)
cells = mod['cells']
for cn, c in cells.items():
    for p, dirn in c.get('port_directions', {}).items():
        if dirn == 'output':
            for b in c['connections'][p]:
                if isinstance(b, int): driver[b] = (cn, c['type'])
sinkre = re.compile(a.sink)
start = []
for cn, c in cells.items():
    if sinkre.search(cn):
        for p, dirn in c.get('port_directions', {}).items():
            if dirn == 'input' and p not in ('CLK', 'CLKA', 'CLKB', 'CLKR', 'CLKW', 'WCK') \
                    and (a.port is None or re.fullmatch(a.port, p)):
                start += [b for b in c['connections'][p] if isinstance(b, int)]
if not start: sys.exit('no sink cells match')
seen_bits, seen_cells, srcs = set(), set(), collections.Counter()
stack = list(start); srccells = set()
while stack:
    b = stack.pop()
    if b in seen_bits: continue
    seen_bits.add(b)
    if b not in driver: continue
    cn, ty = driver[b]
    if ty.startswith(SEQ):
        srccells.add(cn); continue
    if cn in seen_cells: continue
    seen_cells.add(cn)
    c = cells[cn]
    for p, dirn in c.get('port_directions', {}).items():
        if dirn == 'input':
            stack += [x for x in c['connections'][p] if isinstance(x, int)]
def grp(n):
    n = re.sub(r'^top\.soc_top\.core\.cpu\.', 'cpu.', n)
    n = re.sub(r'^top\.soc_top\.', 'soc.', n)
    parts = re.split(r'\.', n)
    g = '.'.join(parts[:a.group + 1])
    return re.sub(r'(_TRELLIS|_LUT4|_PFUMX|\$).*', '', g)
for cn in srccells: srcs[grp(cn)] += 1
print(f'sinks matching {a.sink!r}: {len(start)} pins; comb cells walked {len(seen_cells)}; source cells {len(srccells)}')
for g, n in srcs.most_common(): print(f'  {n:6d}  {g}')
if a.show:
    for cn in sorted(srccells):
        if re.search(a.show, cn): print('   ', cn)
