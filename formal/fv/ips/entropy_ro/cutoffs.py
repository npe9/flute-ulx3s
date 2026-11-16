#!/usr/bin/env python3
"""cutoffs: the SP 800-90B 4.4 health-test cutoffs for the Zkr source, from first principles, and a
check that the checker (entropy_ro_wb.sv, FV_REAL) uses them.

  H = 0.5 bits of min-entropy per sample (the design's assumption), alpha = 2^-20 (90B's
  recommended false-positive rate), binary samples, APT window W = 1024 (90B 4.4.2 for binary).
  RCT (4.4.1): C = 1 + ceil(-log2(alpha) / H).
  APT (4.4.2): C = 1 + critbinom(W, 2^-H, 1 - alpha): the smallest c - 1 with
               P(Binomial(W, 2^-H) <= c - 1) >= 1 - alpha.
"""
import math, re, sys
from math import comb

H, LOG2_ALPHA, W = 0.5, -20, 1024
rct = 1 + math.ceil(-LOG2_ALPHA / H)
p = 2.0 ** -H
cdf, k = 0.0, -1
while cdf < 1 - 2.0 ** LOG2_ALPHA:
    k += 1
    cdf += comb(W, k) * p ** k * (1 - p) ** (W - k)
apt = 1 + k
print(f'RCT cutoff {rct}, APT cutoff {apt} (window {W})')
wb = open(__file__.rsplit('/', 1)[0] + '/entropy_ro_wb.sv').read()
real = wb[wb.index('`ifdef FV_REAL'):wb.index('`else')]
got = {m.group(1): int(m.group(2)) for m in re.finditer(r'`define ES_(\w+) (\d+)', real)}
want = {'DEC': 8, 'RCT': rct, 'APT': apt, 'W': W}
if got != want:
    sys.exit(f'cutoffs: entropy_ro_wb.sv FV_REAL defines {got}, expected {want}')
print('cutoffs: entropy_ro_wb.sv FV_REAL matches')
