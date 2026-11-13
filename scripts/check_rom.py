#!/usr/bin/env python3
"""Check that a netlist embeds the boot ROM it was built for.

  python3 scripts/check_rom.py build/lx46/verilog_all.v build/lx46/boot_loader.memhex

Every build writes the shared Flute/src_Testbench/SoC/fn_read_ROM_RV32.bsvi and the gate scripts
`git checkout` it afterwards, so two builds in one tree at once can race and bsc compiles the
committed (Oct 21, 2144-byte) ROM instead: lx43, lx45 and lx45d did.  The netlist keeps the ROM as
two case statements (rg_rd_d0 = even words, rg_rd_d4 = odd, indexed by the 8-byte offset).
"""
import re
import sys


def netlist_rom(path):
    text = open(path).read()
    words = {}
    for lane, d in ((0, '0'), (1, '4')):
        # the second "// register rg_rd_dN" (the first is the declaration) opens its always block
        m = re.search(r'// register rg_rd_d' + d + r'\n\s*always@', text)
        if not m:
            continue
        k = m.start()
        block = text[k:text.index('endcase', k)]
        # bsc merges equal words into one arm, and long label lists wrap:
        # "9'd209, 9'd212,\n  rg_rd_d4$D_IN = 32'hF0EF0200;"
        for labels, val in re.findall(r"((?:9'd\d+,\s*)*9'd\d+):\s*rg_rd_d" + d
                                      + r"\$D_IN = 32'h([0-9A-Fa-f]+);", block):
            for n in re.findall(r"9'd(\d+)", labels):
                words[int(n) * 2 + lane] = int(val, 16)
    return words


def main():
    v, mh = sys.argv[1:3]
    want = [int(x, 16) for x in open(mh).read().split() if not x.startswith('@')]
    got = netlist_rom(v)
    if not got:
        print(f'check_rom: no ROM case statements in {v}'); return 2
    n = max(len(want), max(got) + 1)
    bad = [i for i in range(n) if got.get(i, 0) != (want[i] if i < len(want) else 0)]
    print(f'check_rom: netlist {len(got)} words, memhex {len(want)} words: '
          + ('MATCH' if not bad else f'{len(bad)} words DIFFER (first at {0x1000 + 4 * bad[0]:#x})'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
