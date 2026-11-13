#!/usr/bin/env python3
"""Decode sim/spdif_ut's runs.txt like an S/PDIF receiver and check it against samples.txt.
   Cells from timing alone (run length / cell time, cell time = 1134 / 128 clocks), preambles by
   their 3-cell runs, biphase-mark bits, parity, V/U, the 192-frame block (B), channel status."""
import sys
period = 1134; cell = period / 128
sfq = int(sys.argv[1], 0) if len(sys.argv) > 1 else 2
runs = [tuple(map(int, l.split())) for l in open('runs.txt')]
want = [int(l, 16) for l in open('samples.txt')]
cells = []
bad = 0
for lv, n in runs[1:]:                         # the first run is the idle line before enable
    k = round(n / cell)
    if not 1 <= k <= 3 or abs(n - k * cell) > 1.5:
        print(f'run of {n} clocks is not 1-3 cells'); bad += 1; continue
    cells += [lv] * k
pats = {'B': [1,1,1,0,1,0,0,0], 'M': [1,1,1,0,0,0,1,0], 'W': [1,1,1,0,0,1,0,0]}
i = 0; subs = []
while i + 64 <= len(cells):
    base = 1 - cells[i]                         # the preamble's first cell is a transition
    p = [c ^ base for c in cells[i:i + 8]]
    kind = [k for k, v in pats.items() if v == p]
    if not kind:
        i += 1; continue
    bits = []
    for s in range(4, 32):
        a, b = cells[i + 2 * s], cells[i + 2 * s + 1]
        prev = cells[i + 2 * s - 1]
        if a == prev: print(f'no transition at slot {s} start'); bad += 1
        bits.append(int(a != b))
    subs.append((kind[0], bits)); i += 64
print(f'decode: {len(cells)} cells, {len(subs)} subframes, {bad} timing/biphase errors')
# pair into frames: B/M then W
frames = []
for k in range(0, len(subs) - 1):
    if subs[k][0] in 'BM' and subs[k + 1][0] == 'W':
        frames.append((subs[k], subs[k + 1]))
for (kl, bl), (kr, br) in frames:
    for b in (bl, br):
        if sum(b) % 2: print('odd parity'); bad += 1; break
        if b[24] or b[25]: print('V or U set'); bad += 1; break
smp = [((sum(b[8 + j] << j for j in range(16))), (sum(c[8 + j] << j for j in range(16)))) for (_, b), (_, c) in frames]
got = [r << 16 | l for l, r in smp]
nz = [g for g in got if g]
start = next((k for k, g in enumerate(got) if g == want[0]), None)
if start is None:
    print('FAIL: first sample never seen'); sys.exit(1)
seq = got[start:start + len(want)]
mism = sum(1 for a, b in zip(seq, want) if a != b)
print(f'samples: {len(want)} pushed, {len(seq)} decoded in order from frame {start}, {mism} differ')
bpos = [k for k, ((kl, _), _) in enumerate(frames) if kl == 'B']
gaps = sorted(set(b - a for a, b in zip(bpos, bpos[1:])))
print(f'B preambles at frames {bpos[:4]}..., spacing {gaps}')
if gaps != [192]: bad += 1
# channel status from the left subframes of the first full block
cs = []
if len(bpos) >= 2:
    cs = [frames[bpos[0] + k][0][1][26] for k in range(192)]
    code = sum(cs[24 + j] << j for j in range(4))
    others = sum(cs) - sum(cs[24:28])
    print(f'channel status: SFREQ {code:04b} (want {sfq:04b}), {others} other bits set')
    if code != sfq or others: bad += 1
ok = bad == 0 and mism == 0 and len(seq) == len(want)
print('spdif_ut:', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
