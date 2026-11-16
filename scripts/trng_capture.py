#!/usr/bin/env python3
"""trng_capture: read the seed words test/trng_dump.bin captured on the board and write them for the
SP 800-90B estimators (notes/linux-isa-plan.md item 8).

Board flow (the boot ROM's load window is short): openFPGALoader -m <bit>, then at once
  scripts/loader.py --no-banner test/trng_dump.bin   (the program then waits for 'g')
  scripts/trng_capture.py <out_prefix>
Writes <out_prefix>.words (u16le, as received) and <out_prefix>.bits (one sample per byte, 0 / 1,
in sample order: each word's bit 15 first), and prints the header counts.
"""
import argparse
import os
import select
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from loader import open_serial  # noqa: E402


def read_exact(fd, n, timeout):
    buf = bytearray()
    end = time.time() + timeout
    while len(buf) < n:
        left = end - time.time()
        if left <= 0:
            raise SystemExit(f'trng_capture: timeout after {len(buf)} of {n} bytes')
        r, _, _ = select.select([fd], [], [], left)
        if r:
            buf += os.read(fd, n - len(buf))
    return bytes(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('-p', '--port', default='/dev/cu.usbserial-120001')
    ap.add_argument('-b', '--baud', type=int, default=1000000)
    a = ap.parse_args()
    fd = open_serial(a.port, a.baud)
    os.write(fd, b'g')
    # sync on the "TRNG" marker (anything the program printed before is skipped)
    win = b''
    end = time.time() + 30
    while not win.endswith(b'TRNG'):
        if time.time() > end:
            raise SystemExit(f'trng_capture: no TRNG marker (got {win[-32:]!r})')
        win = (win + read_exact(fd, 1, 30))[-64:]
    n, polls, bist, dead, cyc = struct.unpack('<5I', read_exact(fd, 20, 10))
    print(f'words {n}  polls {polls}  failures (BIST after data) {bist}  dead polls {dead}  '
          f'cycles {cyc} ({cyc / 50e6:.3f} s at 50 MHz, {cyc / max(n, 1):.1f} per word)')
    data = read_exact(fd, 2 * n, 60 + 2 * n * 10 / a.baud * 2)
    words = struct.unpack(f'<{n}H', data)
    open(a.out + '.words', 'wb').write(data)
    bits = bytes((w >> (15 - i)) & 1 for w in words for i in range(16))
    open(a.out + '.bits', 'wb').write(bits)
    ones = sum(bits)
    print(f'{len(bits)} samples, ones {ones / len(bits):.4f}; wrote {a.out}.words / .bits')


if __name__ == '__main__':
    main()
