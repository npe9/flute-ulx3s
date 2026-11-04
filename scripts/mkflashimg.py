#!/usr/bin/env python3
"""Build a boot-image blob for the configuration flash (read by the boot ROM, boot/boot_loader.c).

The blob is written at flash offset 0x400000 (above the bitstream, which needs < 2.4 MB):
    openFPGALoader -b ulx3s -f --file-type raw -o 0x400000 build/flash.bin

Layout (little-endian u32s), offsets relative to 0x400000:
  0x000  directory (one 4 KB sector, so switching the default rewrites only this sector):
         magic "FLBD", version 1, count, default, wait_ms, sckdiv, 0, 0,
         then count x 32-byte entries: flash_off (absolute), len, dst, entry, sum_a, sum_b,
         name[8]
  0x1000 images, each starting on a 4 KB boundary, zero-padded to a word
sum: over the image as little-endian words (zero-padded), a += w, b += a (mod 2^32).
sckdiv: SPI clock = clk / (2 * (sckdiv + 1)); the boot ROM reads the directory at 3.

usage: mkflashimg.py [--default N] [--wait-ms MS] [--sckdiv D] [--hex OUT.hex] -o OUT.bin
                     --image NAME=FILE[@DST[,ENTRY]] ...
(DST defaults to 0x80000000, ENTRY to DST.)  --hex writes the blob for the sim flash model
(+flash_image=OUT.hex: one byte per line, @<absolute flash offset> lines)."""
import argparse, struct, sys

BASE = 0x400000
MAGIC = 0x44424C46
SECTOR = 0x1000

def fsum(data):
    a = b = 0
    for (w,) in struct.iter_unpack("<I", data):
        a = (a + w) & 0xFFFFFFFF
        b = (b + a) & 0xFFFFFFFF
    return a, b

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", action="append", required=True)
    ap.add_argument("--default", type=int, default=0)
    ap.add_argument("--wait-ms", type=int, default=3000)
    ap.add_argument("--sckdiv", type=int, default=3)
    ap.add_argument("--hex")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    if not 0 < len(a.image) <= 8: sys.exit("1..8 images")
    if not 0 <= a.default < len(a.image): sys.exit("--default out of range")
    if not 0 <= a.sckdiv < 4096: sys.exit("--sckdiv out of range")
    entries, body = [], bytearray()
    for spec in a.image:
        name, rest = spec.split("=", 1)
        fn, _, addrs = rest.partition("@")
        dst, _, ent = addrs.partition(",")
        dst = int(dst, 0) if dst else 0x80000000
        ent = int(ent, 0) if ent else dst
        if dst % 4: sys.exit(f"{name}: dst must be word aligned")
        data = open(fn, "rb").read()
        padded = data + b"\0" * (-len(data) % 4)
        off = BASE + SECTOR + len(body)
        sa, sb = fsum(padded)
        nm = name.encode()[:8].ljust(8, b"\0")
        entries.append(struct.pack("<6I", off, len(data), dst, ent, sa, sb) + nm)
        body += padded + b"\xff" * (-len(padded) % SECTOR)
        print(f"  {name:8s} flash {off:#08x} len {len(data):#x} dst {dst:#010x} entry {ent:#010x} sum {sa:08x} {sb:08x}")
    d = struct.pack("<8I", MAGIC, 1, len(entries), a.default, a.wait_ms, a.sckdiv, 0, 0) + b"".join(entries)
    blob = d + b"\xff" * (SECTOR - len(d)) + bytes(body)
    while blob.endswith(b"\xff" * SECTOR): blob = blob[:-SECTOR]
    if BASE + len(blob) > 16 << 20: sys.exit(f"blob ends at {BASE + len(blob):#x}, past the 16 MB flash")
    open(a.out, "wb").write(blob)
    print(f"{a.out}: {len(blob)} bytes at flash {BASE:#x}..{BASE + len(blob):#x}, default {a.default}, wait {a.wait_ms} ms, sckdiv {a.sckdiv}")
    if a.hex:
        with open(a.hex, "w") as f:
            f.write(f"@{BASE:x}\n")
            f.writelines(f"{b:02x}\n" for b in blob)

if __name__ == "__main__":
    main()
