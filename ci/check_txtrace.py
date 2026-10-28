#!/usr/bin/env python3
"""Judge a bare-metal T/M/D test (test/cache_test.S, amo_test.S) from a strict-sim log run with
TB_TX_TRACE=1: decode the UART 'tx 0x..' bytes and require the program's output (after the boot
loader's readback line) to be exactly 'T' ... 'D' with no 'M' mismatch reports.
Usage: check_txtrace.py <sim.log>"""
import re, sys

data = open(sys.argv[1], 'rb').read().decode('latin-1')
tx = ''.join(chr(int(h, 16)) for h in re.findall(r'tx (0x[0-9a-fA-F]+)', data))
tail = tx.rsplit(']', 1)[-1].strip()       # boot loader prints "[head : tail]" before jumping
print(f'program output: {tail!r}')
if tail.startswith('T') and tail.endswith('D') and 'M' not in tail:
    print('RESULT: PASS')
    sys.exit(0)
print('RESULT: FAIL')
sys.exit(1)
