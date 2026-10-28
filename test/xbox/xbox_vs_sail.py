#!/usr/bin/env python3
"""Unit differential test: Flute's RISCV_XBox (B + Zkn) vs the Sail RISC-V emulator.

Compiles mkRISCV_XBox with bsc (-D ISA_B -D ISA_ZKN) into a scratch dir, drives it from an
iverilog testbench (req -> wait valid -> word) with the same random/edge operand cases as
riscv-formal's tests/sail_bext and tests/sail_kext, and compares rd against Sail
(riscv_sim_RV32) running the same instructions, and that every op has the same latency
(Zkt).  Decode legality (fv_xbox_decode) is covered by the riscv-formal insn / trap checks
on the integrated core.  usage: xbox_vs_sail.py [--n N] [--seed S]"""
import argparse, os, random, re, subprocess, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BSC = os.environ.get("BSC") or subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../scripts/bsc_bin.sh")], capture_output=True, text=True).stdout.strip()
SAIL = os.environ.get("SAIL") or os.path.expanduser("~/src/sail-riscv/c_emulator/riscv_sim_RV32")
R, I, U, A = "r", "i", "u", "a"
OPS = {
    "sh1add": (R, 0b0010000, 0b010, 0x33), "sh2add": (R, 0b0010000, 0b100, 0x33), "sh3add": (R, 0b0010000, 0b110, 0x33),
    "andn": (R, 0b0100000, 0b111, 0x33), "orn": (R, 0b0100000, 0b110, 0x33), "xnor": (R, 0b0100000, 0b100, 0x33),
    "max": (R, 0b0000101, 0b110, 0x33), "maxu": (R, 0b0000101, 0b111, 0x33),
    "min": (R, 0b0000101, 0b100, 0x33), "minu": (R, 0b0000101, 0b101, 0x33),
    "rol": (R, 0b0110000, 0b001, 0x33), "ror": (R, 0b0110000, 0b101, 0x33), "rori": (I, 0b011000, 0b101, 0x13),
    "clz": (U, 0b011000000000, 0b001, 0x13), "ctz": (U, 0b011000000001, 0b001, 0x13),
    "cpop": (U, 0b011000000010, 0b001, 0x13), "sext_b": (U, 0b011000000100, 0b001, 0x13),
    "sext_h": (U, 0b011000000101, 0b001, 0x13), "orc_b": (U, 0b001010000111, 0b101, 0x13),
    "rev8": (U, 0b011010011000, 0b101, 0x13),
    "clmul": (R, 0b0000101, 0b001, 0x33), "clmulh": (R, 0b0000101, 0b011, 0x33), "clmulr": (R, 0b0000101, 0b010, 0x33),
    "bclr": (R, 0b0100100, 0b001, 0x33), "bext": (R, 0b0100100, 0b101, 0x33),
    "binv": (R, 0b0110100, 0b001, 0x33), "bset": (R, 0b0010100, 0b001, 0x33),
    "bclri": (I, 0b010010, 0b001, 0x13), "bexti": (I, 0b010010, 0b101, 0x13),
    "binvi": (I, 0b011010, 0b001, 0x13), "bseti": (I, 0b001010, 0b001, 0x13),
    "pack": (R, 0b0000100, 0b100, 0x33), "packh": (R, 0b0000100, 0b111, 0x33),
    "brev8": (U, 0b011010000111, 0b101, 0x13), "zip": (U, 0b000010001111, 0b001, 0x13),
    "unzip": (U, 0b000010001111, 0b101, 0x13),
    "xperm8": (R, 0b0010100, 0b100, 0x33), "xperm4": (R, 0b0010100, 0b010, 0x33),
    "aes32esi": (A, 0b10001, 0, 0x33), "aes32esmi": (A, 0b10011, 0, 0x33),
    "aes32dsi": (A, 0b10101, 0, 0x33), "aes32dsmi": (A, 0b10111, 0, 0x33),
    "sha256sum0": (U, 0b000100000000, 0b001, 0x13), "sha256sum1": (U, 0b000100000001, 0b001, 0x13),
    "sha256sig0": (U, 0b000100000010, 0b001, 0x13), "sha256sig1": (U, 0b000100000011, 0b001, 0x13),
    "sha512sum0r": (R, 0b0101000, 0, 0x33), "sha512sum1r": (R, 0b0101001, 0, 0x33),
    "sha512sig0l": (R, 0b0101010, 0, 0x33), "sha512sig0h": (R, 0b0101110, 0, 0x33),
    "sha512sig1l": (R, 0b0101011, 0, 0x33), "sha512sig1h": (R, 0b0101111, 0, 0x33),
}
EDGE = [0, 1, 2, 31, 32, 0x7fffffff, 0x80000000, 0xffffffff, 0xfffffffe, 0x80000001, 0x00ff00ff,
        0x12345678, 0x0000ffff, 0xffff0000, 0x00008000, 0x00000080]
RD, RS1, RS2 = 12, 10, 11

def enc(name, imm):
    kind, top, f3, opc = OPS[name]
    if kind == R: return (top << 25) | (RS2 << 20) | (RS1 << 15) | (f3 << 12) | (RD << 7) | opc
    if kind == A: return ((imm & 3) << 30) | (top << 25) | (RS2 << 20) | (RS1 << 15) | (RD << 7) | opc
    if kind == I: return (top << 26) | ((imm & 31) << 20) | (RS1 << 15) | (f3 << 12) | (RD << 7) | opc
    return (top << 20) | (RS1 << 15) | (f3 << 12) | (RD << 7) | opc

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=50)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--keep")
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    pick = lambda: rnd.choice(EDGE) if rnd.random() < 0.4 else rnd.getrandbits(32)
    cs = [(n, pick(), pick(), rnd.getrandbits(5)) for n in OPS for _ in range(a.n)]
    work = a.keep or tempfile.mkdtemp(prefix="xbox_"); os.makedirs(work, exist_ok=True)
    # Sail
    L = [".section .text.init", ".globl _start", "_start:", "  la s1, begin_signature"]
    for n, v1, v2, imm in cs:
        L += [f"  li a0, {v1:#x}", f"  li a1, {v2:#x}", f"  .word 0x{enc(n, imm):08x}", "  sw a2, 0(s1)", "  addi s1, s1, 4"]
    L += ["  li t0, 1", "  la t1, tohost", "  sw t0, 0(t1)", "1: j 1b", ".section .data", ".align 6", ".globl tohost",
          "tohost: .dword 0", ".globl fromhost", "fromhost: .dword 0", ".align 4", ".globl begin_signature",
          "begin_signature:", f"  .fill {len(cs)}, 4, 0xdeadbeef", ".globl end_signature", "end_signature:", ""]
    open(f"{work}/t.S", "w").write("\n".join(L))
    open(f"{work}/l.ld", "w").write("OUTPUT_ARCH(riscv)\nENTRY(_start)\nSECTIONS {\n . = 0x80000000;\n"
                                    " .text.init : { *(.text.init) }\n . = ALIGN(0x1000);\n .data : { *(.data) }\n}\n")
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imac_zicsr", "-mabi=ilp32", "-nostdlib", "-nostartfiles",
                    "-T", f"{work}/l.ld", "-o", f"{work}/t.elf", f"{work}/t.S"], check=True)
    subprocess.run([SAIL, "-V", "-l", "5000000", "--test-signature", f"{work}/t.sig", f"{work}/t.elf"], capture_output=True)
    ref = [int(x, 16) for x in open(f"{work}/t.sig").read().split()]
    # XBox
    core = ":".join(f"{ROOT}/Flute/src_Core/{d}" for d in ("CPU", "ISA", ""))
    r = subprocess.run([BSC, "-u", "-verilog", "-g", "mkRISCV_XBox", "-D", "RV32", "-D", "ISA_B", "-D", "ISA_ZKN",
                        "-p", f"+:{core}", "-bdir", work, "-vdir", work, "-info-dir", work,
                        f"{ROOT}/Flute/src_Core/CPU/RISCV_XBox.bsv"], capture_output=True, text=True)
    if r.returncode: print(r.stdout[-3000:], r.stderr[-3000:]); sys.exit(2)
    tb = ["module tb; reg CLK = 0, RST_N = 0; reg [31:0] instr, v1, v2; reg en = 0;",
          "  wire valid; wire [31:0] word; integer k;",
          "  mkRISCV_XBox x (.CLK(CLK), .RST_N(RST_N), .req_instr(instr), .req_v1(v1), .req_v2(v2), .EN_req(en),",
          "                  .valid(valid), .word(word));",
          "  always #5 CLK = !CLK;",
          "  task run(input [31:0] i, input [31:0] a, input [31:0] b); begin",
          "    @(negedge CLK); instr = i; v1 = a; v2 = b; en = 1; @(negedge CLK); en = 0;",
          "    k = 0; while (!valid && k < 10) begin @(negedge CLK); k = k + 1; end",
          "    $display(\"R %08x %0d\", word, k);", "  end endtask",
          "  initial begin #12 RST_N = 1;"]
    for n, v1, v2, imm in cs:
        tb.append(f"    run(32'h{enc(n, imm):08x}, 32'h{v1:08x}, 32'h{v2:08x});")
    tb += ["    $finish; end", "endmodule"]
    open(f"{work}/tb.v", "w").write("\n".join(tb))
    subprocess.run(["iverilog", "-o", f"{work}/tb.vvp", f"{work}/tb.v", f"{work}/mkRISCV_XBox.v"], check=True)
    out = [l.split() for l in subprocess.run(["vvp", "-n", f"{work}/tb.vvp"], capture_output=True, text=True).stdout.splitlines()
           if l.startswith("R ")]
    assert len(out) == len(cs) == len(ref), (len(out), len(cs), len(ref))
    bad = 0; per = {}; lat = set()
    for (n, v1, v2, imm), o, rf in zip(cs, out, ref):
        w, k = int(o[1], 16), int(o[2]); lat.add(k)
        ok = w == rf
        per.setdefault(n, [0, 0])[0 if ok else 1] += 1
        if not ok:
            if bad < 20: print(f"MISMATCH {n} rs1={v1:08x} rs2={v2:08x} imm={imm}: sail {rf:08x} xbox {w:08x}")
            bad += 1
    diff = "  ".join(f"{k}:{v[0]}/{sum(v)}" for k, v in per.items() if v[1])
    print("  ops with mismatches: " + (diff or "none"))
    print(f"  result latency (cycles after req, all ops): {sorted(lat)}  -- Zkt: must be a single value")
    ok = bad == 0 and len(lat) == 1
    print(f"{'PASS' if ok else 'FAIL'}: {len(cs)} cases over {len(OPS)} ops, {bad} mismatches (Sail vs RISCV_XBox)")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
