#!/usr/bin/env python3
"""Resolve the Repl_Boot_Tb DMI dump: symbol lookup + disassembly context.

Usage: python3 scripts/sim_catch.py [logfile]
Reads dpc/mepc/mcause/mtval and register values printed by the TB,
looks each up in templeos/build/ulx3s_repl.map (offsets + 0x80000000),
and disassembles around the addresses from the blob.
"""

import bisect
import re
import subprocess
import sys

LOG = sys.argv[1] if len(sys.argv) > 1 else "build/sim-repl.log"
MAP = "templeos/build/ulx3s_repl.map"
BLOB = "templeos/build/ulx3s_repl.blob.bin"
BASE = 0x80000000

syms = []
for ln in open(MAP):
    m = re.match(r"\s*([0-9a-f]+)\s+(\S+)", ln)
    if m:
        syms.append((int(m.group(1), 16) + BASE, m.group(2)))
syms.sort()


def lookup(addr):
    i = bisect.bisect_right(syms, (addr, chr(0x10FFFF))) - 1
    if i < 0:
        return None
    base, name = syms[i]
    return name, addr - base


def disas(addr, n=12):
    off = addr - BASE
    if off < 0 or off > 2873440:
        return None
    out = subprocess.run(
        ["riscv64-unknown-elf-objdump", "-b", "binary", "-m", "riscv:rv32",
         "-D", f"--adjust-vma={BASE:#x}",
         f"--start-address={BASE + (off & ~3):#x}",
         f"--stop-address={BASE + (off & ~3) + 4 * n:#x}", BLOB],
        capture_output=True, text=True, timeout=15).stdout
    return "\n".join(l for l in out.splitlines() if re.match(r"\s*[0-9a-f]+:", l))


def show(tag, addr):
    loc = lookup(addr)
    where = f"{loc[0]}+{loc[1]:#x}" if loc else "?"
    print(f"{tag} = {addr:#010x}   ({where})")
    d = disas(addr)
    if d:
        print(d)
    print()


log = open(LOG, errors="replace").read()

for tag in ("DPC", "mepc", "mcause", "mtval"):
    m = re.search(rf"\[tb\] {tag}\s* = ([0-9a-f]{{8}})", log)
    if m:
        v = int(m.group(1), 16)
        if tag == "mcause":
            print(f"{tag} = {v:#010x}   (interrupt={v >> 31}, code={v & 0x7fffffff:#x})")
        else:
            show(tag, v)

regs = re.findall(r"\[tb\] x(\d+) = ([0-9a-f]{8})", log)
if regs:
    print("-- registers (nonzero, symbol-resolved) --")
    for n, v in regs:
        v = int(v, 16)
        if v and int(n) not in (1,):   # ra usually noise
            loc = lookup(v)
            note = f"  <- {loc[0]}+{loc[1]:#x}" if loc else ""
            print(f"  x{int(n):<2} = {v:#010x}{note}")
