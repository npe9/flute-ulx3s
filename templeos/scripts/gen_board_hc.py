#!/usr/bin/env python3
"""Derive ulx3s_board.hc — the Flute SoC constants for MemMap; — from the
elaboration-time SoC manifest, NOT by parsing Bluespec source.

The manifest (../build/soc-memory-map.json relative to this file's tree) is
emitted by the hardware itself: Bluespec's messageM prints MEMMAP/MEMMAPIRQ
lines from the SAME declarative table the AXI fabric decodes, plus a BOARD
line from mkULX3S_Top (clk/baud/chip/fpga/core).  scripts/soc_manifest.py
extracts them from the bsc elaboration log.  This is the map of the ACTUAL
elaborATED hardware — same config flags as the bitstream.

Also cross-checks the guest map (ulx3s_repl/ulx3s_memmap.hc) against the
manifest and FAILS THE BUILD on drift, and sanity-checks src/Top.v's clock
story.  ISA comes from the BOARD line.  The image extent comes from the
previous build's blob (advisory; may lag one build).

Usage: gen_board_hc.py --manifest build/soc-memory-map.json -o OUT.hc \
         [--prev-blob FILE] [--guest-memmap FILE] [--flute DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

# Upstream guest-map concepts with no entry in this SoC's manifest at all.
UPSTREAM_ONLY_ABSENT = ["virtio", "fw_cfg", "SiFive test", "FB", "UART1",
                        "PRCI", "ETH"]

GUEST_DEF_RE = re.compile(r"#define\s+(MEM_\w+)\s+(0x[0-9A-Fa-f]+|MEM_\w+)")


def parse_guest_defines(path: Path) -> dict:
    out = {}
    if not path.exists():
        return out
    for m in GUEST_DEF_RE.finditer(path.read_text()):
        out[m.group(1)] = m.group(2)
    return out


def resolve_guest(defines: dict, key: str):
    v = defines.get(key)
    if v is None:
        return None
    if v.startswith("0x"):
        return int(v, 16)
    return resolve_guest(defines, v)  # chained define (e.g. MEM_RTC)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True, type=Path,
                    help="build/soc-memory-map.json from the FPGA elaboration")
    ap.add_argument("-o", "--output", required=True, type=Path)
    ap.add_argument("--prev-blob", type=Path, default=None,
                    help="previous build's blob for the advisory image extent")
    ap.add_argument("--guest-memmap", type=Path, default=None)
    ap.add_argument("--flute", type=Path, default=None,
                    help="flute-ulx3s repo root (Top.v sanity check)")
    args = ap.parse_args()

    errors: list[str] = []
    try:
        doc = json.loads(args.manifest.read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"gen_board_hc: cannot read manifest {args.manifest}: {e}",
              file=sys.stderr)
        return 1

    board = doc.get("board") or {}
    regions = {r["name"]: r for r in doc.get("regions", [])}
    irqs = {i["name"]: i for i in doc.get("interrupts", [])}
    for w in doc.get("warnings", []):
        print(f"gen_board_hc: manifest warning: {w}", file=sys.stderr)

    clk = board.get("clk_hz")
    baud = board.get("baud")
    if not clk or not baud:
        errors.append("manifest BOARD line missing clk/baud")

    # Top.v sanity: the elaborated clock must match the oscillator story.
    if args.flute:
        top_v = (args.flute / "src/Top.v")
        if top_v.exists():
            txt = top_v.read_text(errors="replace")
            if "12.5 MHz" not in txt:
                errors.append("src/Top.v no longer mentions 12.5 MHz — "
                              "clock story changed?")
            if str(clk) not in txt.replace("_", "") and clk != 12_500_000:
                errors.append(f"manifest clk {clk} != src/Top.v expectation")

    # Guest map cross-check: the REPL's MEM_* must agree with the
    # elaborated hardware.  Drift here = build failure, not a silent lie.
    guest_path = args.guest_memmap or (Path(__file__).resolve().parent.parent
                                       / "ulx3s_repl" / "ulx3s_memmap.hc")
    guest = parse_guest_defines(Path(guest_path))

    def check(guest_key: str, region: str) -> None:
        g = resolve_guest(guest, guest_key)
        r = regions.get(region)
        if g is None or r is None:
            return
        hw = int(r["base"], 16)
        if g != hw:
            errors.append(f"drift: guest {guest_key}={g:#x} but elaborated "
                          f"{region} base={hw:#x}")

    check("MEM_CLINT", "clint")
    check("MEM_PLIC", "plic")
    check("MEM_UART", "uart0")
    check("MEM_GPIO", "gpio")
    check("MEM_SOC_INFO", "soc_info")
    check("MEM_RAM", "sdram")

    # Derived classification, straight from the manifest fields.
    gpio_present = "gpio" in regions
    plic = regions.get("plic")
    plic_routed = bool(plic and plic["decoded"] and plic["bus"] == "axi")
    uart_irq = irqs.get("uart0", {}).get("source", 0)

    absent = []
    for r in doc.get("regions", []):
        if r["bus"] == "reserved" or (not r["decoded"] and r["bus"] == "axi"):
            absent.append(r["name"] + " (reserved void)")
    absent.extend(UPSTREAM_ONLY_ABSENT)
    absent_list = ", ".join(absent)

    # Advisory image extent from the previous build (documented lag).
    image_end = 0
    image_kb = 0
    if args.prev_blob and args.prev_blob.exists():
        size = args.prev_blob.stat().st_size
        image_end = 0x80000000 + size
        image_kb = size // 1024

    if errors:
        for e in errors:
            print(f"gen_board_hc: {e}", file=sys.stderr)
        print("gen_board_hc: refusing to emit a map that contradicts the "
              "elaborated hardware", file=sys.stderr)
        return 1

    sdram = regions.get("sdram", {})
    sdram_mb = int(sdram.get("size", "0x0"), 16) // (1024 * 1024)
    chip = board.get("chip", "unknown")
    fpga = board.get("fpga", "unknown")
    isa = board.get("core", "RV32")

    L = []
    A = L.append
    A("// ulx3s_board.hc -- GENERATED by scripts/gen_board_hc.py; do not edit.")
    A("// Derived from build/soc-memory-map.json, which the Bluespec design")
    A("// emits at ELABORATION time (messageM) from the same declarative table")
    A("// the AXI fabric decodes -- the map of the actual hardware, not a")
    A("// parsed copy.  The build fails if the guest map drifts from it.")
    A(f"#define ULX3S_FPGA         \"{fpga}\"")
    A(f"#define ULX3S_CORE         \"{isa}\"")
    A(f"#define ULX3S_SYS_CLK_HZ   {clk}")
    A(f"#define ULX3S_BAUD         {baud}")
    A(f"#define ULX3S_SDRAM_CHIP   \"{chip}\"")
    A(f"#define ULX3S_SDRAM_MB     {sdram_mb}")
    for r in doc.get("regions", []):
        nm = r["name"].upper().replace("_", "")   # boot_rom -> BOOTROM
        A(f"#define ULX3S_{nm}_BASE   {r['base']}")
        A(f"#define ULX3S_{nm}_SIZE   {r['size']}")
    A(f"#define ULX3S_UART0_IRQ    {uart_irq}  // {irqs.get('uart0', {}).get('controller', 'core_external')}")
    A(f"#define ULX3S_GPIO_PRESENT {1 if gpio_present else 0}")
    A(f"#define ULX3S_PLIC_ROUTED  {1 if plic_routed else 0}  // manifest: bus={plic['bus'] if plic else '?'}, decoded={plic['decoded'] if plic else '?'}")
    A(f"#define ULX3S_IMAGE_END    0x{image_end:X}  // previous build, advisory")
    A(f"#define ULX3S_IMAGE_KB     {image_kb}")
    A(f"#define ULX3S_ABSENT_LIST  \"{absent_list}\"")
    args.output.write_text("\n".join(L) + "\n")
    print(f"gen_board_hc: wrote {args.output} "
          f"(clk={clk}, baud={baud}, chip={chip}, irq_uart0={uart_irq}, "
          f"plic_routed={plic_routed}, regions={len(doc.get('regions', []))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
