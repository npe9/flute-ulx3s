#!/usr/bin/env python3
"""Load an image into SDRAM over the DMI system bus (SBA), verify it,
and optionally start it.

This path bypasses the UART bootloader entirely: it needs no boot ROM
cooperation, is immune to the Mac FTDI driver's mid-stream packet
losses, and every word can be read back for verification.  It is slower
than the UART stream (~15 min for a 2.9 MB image) but deterministic.

Usage:
    python3 sba_load.py <image> [-p PORT] [-a ADDR] [--go] [--verify-all]

    --go          set dpc to ADDR and resume after the load
    --verify-all  read back every word (doubles the time); default
                  verifies entry, tail, and 64 random samples
"""

import argparse
import random
import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from dmi import DMI, DM_SBCS, DM_SBADDRESS0, DM_SBDATA0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("-b", "--baud", type=int, default=625000)
    ap.add_argument("-a", "--addr", default="0x80000000")
    ap.add_argument("--go", action="store_true")
    ap.add_argument("--verify-all", action="store_true")
    args = ap.parse_args()

    addr = int(args.addr, 16)
    data = open(args.image, "rb").read()
    assert len(data) % 4 == 0, "image must be word-aligned"
    n_words = len(data) // 4
    words = struct.unpack(f"<{n_words}I", data)

    dmi = DMI(args.port, args.baud)
    try:
        dmi.arm()
        dmi.halt()
        print(f"[sba_load] halted; writing {n_words} words to {addr:#x}",
              file=sys.stderr)

        # 32-bit accesses, autoincrement on write.
        dmi.wr(DM_SBCS, (2 << 17) | (1 << 16) | 0x7000)
        t0 = time.monotonic()
        CHUNK = 8192    # words per sbaddress reload
        for base in range(0, n_words, CHUNK):
            dmi.wr(DM_SBADDRESS0, addr + 4 * base)
            for w in words[base:base + CHUNK]:
                dmi.wr(DM_SBDATA0, w)
            done = min(base + CHUNK, n_words)
            rate = done / (time.monotonic() - t0)
            print(f"[sba_load] {done * 100 // n_words}% "
                  f"({time.monotonic() - t0:.0f}s, {rate:.0f} words/s)",
                  file=sys.stderr)

        print("[sba_load] verifying (full)...", file=sys.stderr)
        for round_ in range(4):
            dmi.wr(DM_SBCS, (2 << 17) | 0x7000)
            bad_idx = []
            t0 = time.monotonic()
            for i in range(n_words):
                dmi.wr(DM_SBADDRESS0, addr + 4 * i)
                dmi.rd(0x11)
                got = dmi.rd(DM_SBDATA0)
                if got != words[i]:
                    bad_idx.append(i)
            print(f"[sba_load] verify round {round_}: {len(bad_idx)} bad "
                  f"({time.monotonic() - t0:.0f}s)", file=sys.stderr)
            if not bad_idx:
                break
            # rewrite the bad words
            dmi.wr(DM_SBCS, (2 << 17) | 0x7000)
            for i in bad_idx:
                dmi.wr(DM_SBADDRESS0, addr + 4 * i)
                dmi.wr(DM_SBDATA0, words[i])
            print(f"[sba_load] rewrote {len(bad_idx)} words", file=sys.stderr)
        bad = len(bad_idx) if bad_idx else 0

        if args.go and bad == 0:
            dmi.write_csr(0x7B1, addr)      # dpc = entry
            dmi.resume()
            print("[sba_load] go!", file=sys.stderr)
        elif args.go:
            print("[sba_load] NOT starting: image verify failed", file=sys.stderr)
            dmi.halt()
    finally:
        dmi.close()


if __name__ == "__main__":
    main()
