#!/usr/bin/env python3
"""Decode test/ipc_bench.S output from a sim log with TB_TX_TRACE=1: per-kernel cycles, instret, CPI."""
import re, sys
names = {'a': 'alu32', 'b': 'aluc', 'c': 'copy', 'd': 'branchy', 'e': 'calls', 'f': 'chase', 'g': 'poll_io', 'h': 'poll_mem'}
b = bytes(int(m, 16) for m in re.findall(r'tx 0x([0-9a-f]{2}) at', open(sys.argv[1]).read())).decode(errors='replace')
s = b[b.rfind(']\r\n'):]
for m in re.finditer(r'([a-h])([0-9a-f]{8})\r\n([0-9a-f]{8})', s):
    c, n = int(m.group(2), 16), int(m.group(3), 16)
    print(f"{m.group(1)} {names[m.group(1)]:8s} cycles {c:6d} instret {n:5d} CPI {c/n:.2f}")
if not s.rstrip().endswith('D'):
    print("(incomplete: no 'D')")
