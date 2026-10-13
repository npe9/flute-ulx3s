#!/usr/bin/env python3
"""Extract the elaboration-time SoC manifest from the bsc log.

The Bluespec design emits lines during elaboration (messageM, from the same
declarative table the AXI fabric decodes):

    MEMMAP <name> <base-hex-8> <size-hex-8> <bus> <decoded|no-slave>
    MEMMAPIRQ <name> <irq> <controller>
    BOARD clk <hz> baud <baud> chip <name> fpga <part> core <isa>

Output JSON:

    {
      "soc": "flute-ulx3s",
      "board": {"clk_hz": 12500000, "baud": 625000,
                "chip": "W9825G6KH-6", "fpga": "LFE5U-85F", "core": "RV32IMAC"},
      "regions": [{"name": "sdram", "base": "0x80000000", "size": "0x02000000",
                   "bus": "axi", "decoded": true}, ...],
      "interrupts": [{"name": "uart0", "source": 0, "controller": "core_external"}]
    }

Usage: soc_manifest.py ELABORATION_LOG OUT_JSON
"""

from __future__ import annotations

import json
import re
import sys

# Lines look like:
#   Compilation message: "SoC_Map.bsv", line 237, column 58: MEMMAP plic 201326592 4194304 reserved no-slave
# (values are decimal; the same line repeats once per elaboration pass, so
# regions are deduped by name and must stay consistent.)
MEMMAP_RE = re.compile(
    r"MEMMAP (\S+) (\d+) (\d+) (\S+) (decoded|no-slave)")
IRQ_RE = re.compile(r"MEMMAPIRQ (\S+) (\d+) (\S+)")
BOARD_RE = re.compile(
    r"BOARD clk (\d+) baud (\d+) chip (\S+) fpga (\S+) core (\S+)")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    log_path, out_path = sys.argv[1], sys.argv[2]

    regions = []
    irqs = []
    board = {}
    warnings = []
    try:
        lines = open(log_path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        print(f"soc_manifest: cannot read {log_path}: {e}", file=sys.stderr)
        return 1

    region_map = {}
    irq_map = {}
    for ln in lines:
        m = MEMMAP_RE.search(ln)
        if m:
            name = m.group(1)
            entry = {
                "name": name,
                "base": "0x%X" % int(m.group(2)),
                "size": "0x%X" % int(m.group(3)),
                "bus": m.group(4),
                "decoded": m.group(5) == "decoded",
            }
            if name in region_map and region_map[name] != entry:
                print(f"soc_manifest: CONFLICTING emissions for {name}",
                      file=sys.stderr)
                return 1
            region_map[name] = entry
            continue
        m = IRQ_RE.search(ln)
        if m:
            irq_map.setdefault(m.group(1), {
                "name": m.group(1),
                "source": int(m.group(2)),
                "controller": m.group(3),
            })
            continue
        m = BOARD_RE.search(ln)
        if m:
            board = {
                "clk_hz": int(m.group(1)),
                "baud": int(m.group(2)),
                "chip": m.group(3),
                "fpga": m.group(4),
                "core": m.group(5),
            }
            continue
        if "MEMMAP WARNING" in ln:
            w = ln.split("MEMMAP WARNING", 1)[1].strip()
            if w not in warnings:
                warnings.append(w)
    regions = list(region_map.values())
    irqs = list(irq_map.values())

    if not regions:
        print("soc_manifest: no MEMMAP lines in the elaboration log — "
              "did the design emit them (messageM in SoC_Map/ULX3S_Top)?",
              file=sys.stderr)
        return 1
    if not board:
        print("soc_manifest: no BOARD line in the elaboration log",
              file=sys.stderr)
        return 1

    doc = {
        "soc": "flute-ulx3s",
        "board": board,
        "regions": regions,
        "interrupts": irqs,
    }
    if warnings:
        doc["warnings"] = warnings

    with open(out_path, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    print(f"soc_manifest: {len(regions)} regions, {len(irqs)} irqs, "
          f"clk={board['clk_hz']} baud={board['baud']} -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
