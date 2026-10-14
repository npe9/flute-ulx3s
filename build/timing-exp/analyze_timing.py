#!/usr/bin/env python3
"""analyze_timing.py — summarize a nextpnr detailed-timing JSON report.

Usage: analyze_timing.py <report.json> [--n N] [--src]

For each of the top-N critical paths:
  total delay, logic vs routing split, endpoint FFs (start = first
  clk-to-q cell, end = last segment's 'to' cell), the heaviest nets
  (routing segments >= --minnet ns, default 1.5) with their
  build/verilog_all.v source lines, and a guessed RTL role from cell
  name heuristics (regfile / dcache / icache / shim / mbox / etc).

The --src flag additionally prints the verilog_all.v source line for
every heavy net (best-effort BSV tracing aid).
"""
import json, sys, re, argparse, collections

ap = argparse.ArgumentParser()
ap.add_argument('report')
ap.add_argument('--n', type=int, default=8)
ap.add_argument('--minnet', type=float, default=1.5)
ap.add_argument('--src', action='store_true')
a = ap.parse_args()

r = json.load(open(a.report))
print('fmax:', {k: f"achieved {v['achieved']:.3f} MHz (constraint {v['constraint']})"
              for k, v in r['fmax'].items()})
cps = r['critical_paths']
print(f'critical paths in report: {len(cps)}')

ROLE = [
    (r'gpr_regfile', 'GPR regfile'),
    (r'stage2_mbox', 'M-box (intDiv)'),
    (r'intDiv', 'M-box (intDiv)'),
    (r'dcache\.ram', 'dcache RAM'),
    (r'icache\.ram', 'icache RAM'),
    (r'ram_cword', 'cache cword RAM'),
    (r'ram_state_and_ctag', 'cache tag RAM'),
    (r'stageF_branch_predictor', 'branch predictor'),
    (r'shim', 'near-mem shim'),
    (r'rg_out_', 'step9 presentation regs'),
    (r'stage1', 'CPU stage1'),
    (r'stage2', 'CPU stage2'),
    (r'stage3', 'CPU stage3'),
    (r'imem', 'imem iface'),
    (r'dmem', 'dmem iface'),
    (r'soc_top', 'SoC'),
    (r'sdram', 'SDRAM ctrl'),
]

def role(name):
    hits = [lbl for pat, lbl in ROLE if re.search(pat, name)]
    return hits[0] if hits else '?'

for i, p in enumerate(cps[:a.n]):
    segs = p['path']
    total = sum(s['delay'] for s in segs)
    logic = sum(s['delay'] for s in segs if s['type'] == 'logic')
    rout = sum(s['delay'] for s in segs if s['type'] == 'routing')
    clkq = sum(s['delay'] for s in segs if s['type'] == 'clk-to-q')
    start = segs[0]['from']['cell']
    end = segs[-1]['to']['cell']
    print(f'\n=== path {i}: {total:6.2f} ns ({1e3/total:6.2f} MHz)  '
          f'logic {logic:5.2f} + routing {rout:5.2f} + clkq {clkq:4.2f} ===')
    print(f'  start: {start}')
    print(f'  end  : {end}')
    print(f'  roles: {role(start)} -> {role(end)}')
    # heavy nets, with per-net cumulative
    nets = collections.OrderedDict()
    for s in segs:
        if s['type'] == 'routing' and s['delay'] >= a.minnet:
            key = s.get('net', s['from']['cell'])
            nets.setdefault(key, {'delay': 0.0, 'srcs': set(),
                                  'to': s['to']['cell']})
            nets[key]['delay'] += s['delay']
            for sr in s.get('sources', []):
                nets[key]['srcs'].add(sr)
    top = sorted(nets.items(), key=lambda kv: -kv[1]['delay'])[:12]
    print('  heaviest nets:')
    for name, d in top:
        print(f'    {d["delay"]:5.2f} ns  {name}')
        print(f'              -> {d["to"]}')
        if a.src:
            for sr in sorted(d['srcs'])[:4]:
                print(f'              src {sr}')
