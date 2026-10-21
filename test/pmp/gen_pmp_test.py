#!/usr/bin/env python3
"""Generate test/pmp_test.S: whole-core PMP test (entries 0-7, G = 10) for the strict-BRAM sim
and hardware.  Expected values come from Sail (riscv_sim_RV32 --pmp-count 16 --pmp-grain 10)
running the same instruction sequence.

Phases
  W  WARL: random pmpcfg0/1 (L clear) + pmpaddr0-7 written, everything read back.
  A  Access: random entries 0-6 over a 16-page data window at 0x80100000 (OFF / TOR / NA4 /
     NAPOT, random RWX, random sub-grain address bits), entry 7 = NAPOT RWX over the 1 MB code
     window.  One access per configuration from U, S, or M with MPRV (MPP = U/S): load, store,
     AMO, LR, fetch, or a 32-bit fetch straddling a page boundary.  Recorded: mcause, mtval
     (0xff / 0 sentinels when nothing trapped; an access that succeeds in U/S reaches an ECALL).
  L  Lock: locked NAPOT and TOR entries checked against M-mode accesses, and the writes they
     must ignore (cfg, own addr, the TOR base addr).
  F  Flute-only (not Sail-checked): entries 8-15 are WARL read-only zero here; Sail implements 16.
UART protocol as mul_test.S: 'T', 'M <id> <exp> <got>' per mismatch, 'D'.
usage: gen_pmp_test.py [--n N] [--warl W] [--seed S]"""
import argparse, os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "xbox"))
from gen_bk_test import HEAD as BK_HEAD, TAIL as BK_TAIL
from xbox_vs_sail import SAIL

WIN   = 0x80100000                       # data window: pages 0..15
CODE7 = (0x80000000 >> 2) | ((0x100000 >> 3) - 1)   # entry 7: NAPOT 1 MB code window
CFG7  = 0x1F
ECALL = 0x00000073

def page_addr(p): return WIN + p * 4096

class Gen:
    def __init__(s, rnd):
        s.r, s.B, s.n, s.lab, s.const = rnd, [], 0, 0, {}
    def emit(s, *xs): s.B += list(xs)
    def chk(s, reg="a2", const=None):
        if reg != "a2": s.emit(f"mv a2, {reg}")
        if const is not None: s.const[s.n] = const
        s.emit(("CHK", s.n)); s.n += 1
    def label(s):
        s.lab += 1; return f"L{s.lab}"
    def li(s, r, v): s.emit(f"li {r}, {v & 0xffffffff:#x}")

    # ---- PMP programming (entries 0..7)
    def program(s, cfg, addr):
        for i in range(8):
            s.li("t0", addr[i]); s.emit(f"csrw pmpaddr{i}, t0")
        s.li("t0", cfg[0] | cfg[1] << 8 | cfg[2] << 16 | cfg[3] << 24); s.emit("csrw pmpcfg0, t0")
        s.li("t0", cfg[4] | cfg[5] << 8 | cfg[6] << 16 | cfg[7] << 24); s.emit("csrw pmpcfg1, t0")
        s.emit("sfence.vma x0, x0")

    def rand_entry(s, i):
        r = s.r
        a = r.choices(["OFF", "TOR", "NA4", "NAPOT"], [30, 25 if i else 0, 10, 35])[0]
        rwx = r.getrandbits(3)
        if a == "NAPOT":
            k = r.randrange(5); base = r.randrange(16 >> k) << k
            v = (page_addr(base) >> 2) | ((1 << (k + 9)) - 1)
            if k == 0: v = (page_addr(base) >> 2) | r.getrandbits(9) | (1 << 9) * 0   # low 9 bits read as ones
            if r.random() < 0.3: v = (v & ~0x1FF) | r.getrandbits(9)                  # sub-grain noise
        else:
            v = page_addr(r.randrange(17)) >> 2
            if r.random() < 0.5: v |= r.getrandbits(10)                               # masked on read
        A = {"OFF": 0, "TOR": 1, "NA4": 2, "NAPOT": 3}[a]
        return (A << 3) | rwx, v

    def warl(s):
        r = s.r
        cfg = [r.getrandbits(8) & 0x7F for _ in range(8)]
        addr = [r.getrandbits(32) for _ in range(8)]
        s.program(cfg, addr)
        s.emit("csrr a2, pmpcfg0"); s.chk()
        s.emit("csrr a2, pmpcfg1"); s.chk()
        for i in range(8):
            s.emit(f"csrr a2, pmpaddr{i}"); s.chk()

    # ---- one access, results to s6 (mcause) / s7 (mtval)
    def access(s, mode, op, tgt, mprv_pp=None, setup=True, exp=None):
        L = s.label(); R = s.label()
        s.emit(f"la s5, {R}", "li s6, 0xff", "li s7, 0")
        s.li("t3", tgt); s.li("t4", ECALL)
        if op == "straddle":
            s.emit("li t0, 0x0073", "sh t0, -2(t3)", "sh zero, 0(t3)", "fence.i", "addi t3, t3, -2")
        elif setup:
            s.emit("sw t4, 0(t3)", "fence.i")
        insn = {"load": ["lw a2, 0(t3)"], "store": ["sw t4, 0(t3)"],
                "amo": ["amoswap.w a2, t4, (t3)"], "lr": ["lr.w a2, (t3)"],
                "fetch": ["jalr x0, 0(t3)"], "straddle": ["jalr x0, 0(t3)"]}[op]
        if mode == "M":         # MPRV with MPP = mprv_pp: data accesses checked as that mode
            s.emit("li t0, 0x1800", "csrc mstatus, t0")
            s.li("t0", (mprv_pp << 11) | (1 << 17)); s.emit("csrs mstatus, t0")
            s.emit(*insn)
            s.emit("li t0, 0x20000", "csrc mstatus, t0", f"j {R}")
        else:
            pp = {"U": 0, "S": 1}[mode]
            s.emit("li t0, 0x1800", "csrc mstatus, t0")
            if pp: s.li("t0", pp << 11); s.emit("csrs mstatus, t0")
            s.emit(f"la t0, {L}", "csrw mepc, t0", "mret", f"{L}:", *insn, "ecall")
        s.emit(f"{R}:")
        s.chk("s6", const=exp and exp[0]); s.chk("s7", const=exp and exp[1])

    def access_case(s):
        r = s.r
        cfg = [0] * 8; addr = [0] * 8
        for i in range(7):
            cfg[i], addr[i] = s.rand_entry(i)
        cfg[7], addr[7] = CFG7, CODE7
        s.program(cfg, addr)
        mode = r.choices(["U", "S", "M"], [45, 35, 20])[0]
        if mode == "M":
            op = r.choice(["load", "store", "amo", "lr"]); pp = r.randrange(2)
        else:
            op = r.choices(["load", "store", "amo", "lr", "fetch", "straddle"], [30, 25, 10, 5, 20, 10])[0]; pp = None
        if op == "straddle":
            tgt = page_addr(r.randrange(1, 17))
        else:
            tgt = page_addr(r.randrange(17)) + 4 * r.randrange(1024)
        s.access(mode, op, tgt, pp)

    def lock_phase(s):
        s.program([0] * 7 + [CFG7], [0] * 7 + [CODE7])
        addr = [0] * 8; cfg = [0] * 8
        addr[4] = page_addr(8) >> 2; addr[5] = page_addr(10) >> 2
        addr[6] = (page_addr(3) >> 2) | 0x1FF
        cfg[5] = 0x80 | 0x08 | 0x3                 # TOR [page 8, page 10) RW, locked
        cfg[6] = 0x80 | 0x18 | 0x1                 # NAPOT page 3 R, locked
        cfg[7], addr[7] = CFG7, CODE7
        s.program(cfg, addr)
        for i in (1,):                              # cfg readback
            s.emit("csrr a2, pmpcfg1"); s.chk()
        # M-mode against locked entries (M has no MPRV here: write a "mode" of M by direct access)
        for op, p in [("store", 3), ("load", 3), ("amo", 3), ("load", 9), ("store", 9), ("amo", 9),
                      ("load", 12), ("store", 12)]:
            s.m_direct(op, page_addr(p) + 8)
        s.m_fetch(page_addr(9) + 16); s.m_fetch(page_addr(3) + 16); s.m_fetch(page_addr(12) + 16)
        # writes that must be ignored (locked cfg, locked addr, TOR base of a locked TOR entry)
        s.li("t0", CFG7 << 24 | 0x1F); s.emit("csrw pmpcfg1, t0")     # entry 4 changes; 5, 6 locked; 7 kept
        s.emit("csrr a2, pmpcfg1"); s.chk()
        for i in (3, 4, 5, 6):
            s.li("t0", 0x12345678); s.emit(f"csrw pmpaddr{i}, t0", f"csrr a2, pmpaddr{i}"); s.chk()
        # U still governed by the locked entries
        for op, p in [("load", 3), ("store", 3), ("load", 9), ("fetch", 9), ("load", 12)]:
            s.access("U", op, page_addr(p) + 24, setup=False)      # targets written before the lock

    def wide_phase(s):
        # Regions whose end is at or beyond 2^34 (the riscv-tests env uses NAPOT pmpaddr0 = -1):
        # entry 0 alone, matched first, so it governs the U code fetch as well.
        # (X is always set: a no-X region over the code window faults the U code itself, whose
        # mtval is a label address that differs between the Sail and Flute builds.)
        # NAPOT pmpaddr 0xFFFFFFFF / 0x7FFFFFFF (2^35 / 2^34-byte regions; priv spec: all-ones is
        # the 2^(XLEN+3)-byte range): this Sail (af5c2f2, May 2024) computes len = mask + 1 in
        # xlen bits, which wraps to an empty range, so those expectations come from the spec
        # (X set, so the U code runs: a permitted access reaches the ECALL -> 8 / 0).
        for cfg0, a0 in [(0x1F, 0xFFFFFFFF), (0x1D, 0xFFFFFFFF), (0x1D, 0x7FFFFFFF),
                         (0x1D, 0x3FFFFFFF), (0x1F, 0x1FFFFFFF), (0x1F, 0x3FFFFFFF),
                         (0x0D, 0xFFFFFFFF), (0x0F, 0xFFFFFC00)]:
            cfg = [cfg0] + [0] * 6 + [CFG7]; addr = [a0] + [0] * 6 + [CODE7]
            s.program(cfg, addr)
            spec = (cfg0 >> 3) & 3 == 3 and a0 in (0xFFFFFFFF, 0x7FFFFFFF)
            for op, p in [("load", 5), ("store", 6), ("fetch", 7)]:
                tgt = page_addr(p) + 32
                exp = None
                if spec:
                    ok = {"load": cfg0 & 1, "store": cfg0 & 2, "fetch": cfg0 & 4}[op]
                    exp = (8, 0) if ok else ({"load": 5, "store": 7}[op], tgt)
                s.access("U", op, tgt, exp=exp)

    def m_direct(s, op, tgt):
        R = s.label()
        s.emit(f"la s5, {R}", "li s6, 0xff", "li s7, 0")
        s.li("t3", tgt); s.li("t4", ECALL)
        s.emit({"load": "lw a2, 0(t3)", "store": "sw t4, 0(t3)", "amo": "amoswap.w a2, t4, (t3)"}[op])
        s.emit(f"{R}:"); s.chk("s6"); s.chk("s7")

    def m_fetch(s, tgt):
        R = s.label()
        s.emit(f"la s5, {R}", "li s6, 0xff", "li s7, 0")
        s.li("t3", tgt); s.li("t4", ECALL)
        s.emit("li t0, 0x1800", "csrc mstatus, t0")      # (the M-mode store below is allowed: page 9 RW, 3/12 not W-locked? see Sail)
        s.emit("jalr x0, 0(t3)", f"{R}:"); s.chk("s6"); s.chk("s7")

    def flute_only(s):
        # entries 8-15: read-only zero on Flute (Sail implements 16 entries: not Sail-checked)
        s.li("t0", 0x1F1F1F1F); s.emit("csrw pmpcfg2, t0", "csrr a2, pmpcfg2"); s.chk(const=0)
        s.li("t0", -1); s.emit("csrw pmpaddr8, t0", "csrr a2, pmpaddr8"); s.chk(const=0)
        s.emit("csrw pmpaddr15, t0", "csrr a2, pmpaddr15"); s.chk(const=0)

TRAP = ["", ".align 2", "trap:", "  csrr s6, mcause", "  csrr s7, mtval",
        "  li t0, 0x1800", "  csrs mstatus, t0", "  li t0, 0x20000", "  csrc mstatus, t0",
        "  csrw mepc, s5", "  mret"]

def build(g, nwarl, n, seed):
    g.emit("la t0, trap", "csrw mtvec, t0")
    for _ in range(nwarl): g.warl()
    for _ in range(n): g.access_case()
    # m_fetch targets must hold an ECALL: written while the window is still unlocked
    g.program([0] * 7 + [CFG7], [0] * 7 + [CODE7])
    for p in (9, 3, 12):
        for off in (16, 24):
            g.li("t3", page_addr(p) + off); g.li("t4", ECALL); g.emit("sw t4, 0(t3)")
    g.emit("fence.i")
    g.wide_phase()
    g.program([0] * 7 + [CFG7], [0] * 7 + [CODE7])
    for p in (9, 3, 12):
        for off in (16, 24):
            g.li("t3", page_addr(p) + off); g.li("t4", ECALL); g.emit("sw t4, 0(t3)")
    g.emit("fence.i")
    g.lock_phase()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--warl", type=int, default=30)
    ap.add_argument("--seed", type=int, default=11)
    a = ap.parse_args()
    g = Gen(random.Random(a.seed))
    build(g, a.warl, a.n, a.seed)
    nsail = g.n
    # Sail program: signature stores in place of the checks
    L = [".section .text.init", ".globl _start", ".option norvc", "_start:", "  la s1, begin_signature"]
    for x in g.B:
        L += ["  sw a2, 0(s1)", "  addi s1, s1, 4"] if isinstance(x, tuple) else ["  " + x]
    L += ["  li t0, 1", "  la t1, tohost", "  sw t0, 0(t1)", "1: j 1b"] + TRAP
    L += [".section .data", ".align 6", ".globl tohost", "tohost: .dword 0", ".globl fromhost", "fromhost: .dword 0",
          ".align 4", ".globl begin_signature", "begin_signature:", f"  .fill {nsail}, 4, 0xdeadbeef",
          ".globl end_signature", "end_signature:", ""]
    work = tempfile.mkdtemp(prefix="pmp_")
    open(f"{work}/t.S", "w").write("\n".join(L))
    open(f"{work}/l.ld", "w").write("OUTPUT_ARCH(riscv)\nENTRY(_start)\nSECTIONS {\n . = 0x80000000;\n"
                                    " .text.init : { *(.text.init) }\n . = ALIGN(0x1000);\n .data : { *(.data) }\n}\n")
    subprocess.run(["riscv64-unknown-elf-gcc", "-march=rv32imac_zicsr_zifencei", "-mabi=ilp32", "-nostdlib",
                    "-nostartfiles", "-T", f"{work}/l.ld", "-o", f"{work}/t.elf", f"{work}/t.S"], check=True)
    subprocess.run([SAIL, "-V", "-l", "20000000", "--pmp-count", "16", "--pmp-grain", "10",
                    "--test-signature", f"{work}/t.sig", f"{work}/t.elf"], capture_output=True)
    ref = [int(x, 16) for x in open(f"{work}/t.sig").read().split()]
    assert len(ref) >= nsail and 0xdeadbeef not in ref[:nsail], (work, len(ref), nsail)
    g.flute_only()
    ref = ref[:nsail] + [None] * (g.n - nsail)
    for i, v in g.const.items(): ref[i] = v
    out = [BK_HEAD.replace("Zba/Zbb/Zbc/Zbs + Zbkb/Zbkx/Zkne/Zknd/Zknh test (XBox integration gate)",
                           "PMP test (entries 0-7, G=10)")
                  .replace("test/xbox/gen_bk_test.py", "test/pmp/gen_pmp_test.py --pmp-count 16 --pmp-grain 10")
                  .replace("# {n} op checks ({per} per op, {nops} ops) + bypass chains + rd=x0 + misa.",
                           f"# {g.n} checks: {a.warl} WARL rounds, {a.n} access cases, wide regions, lock phase, entries 8-15 RO-zero (seed {a.seed}).")]
    out.append("    li s9, 0\n    la t0, trap\n    csrw mtvec, t0")
    for x in g.B[2:]:
        if isinstance(x, tuple):
            i = x[1]
            out += [f"    li   t0, {ref[i]:#010x}", f"    li   s4, {i:#x}", "    jal  ra, chk"]
        elif x.endswith(":"):
            out.append(x)
        else:
            out.append("    " + x)
    # tohost (ISA harness, sim/isa_bram): 1 = pass, (mismatches << 1) | 1 = fail
    tail = BK_TAIL.replace("    beq  a2, t0, 1f\n    mv   s5, ra", "    beq  a2, t0, 1f\n    addi s9, s9, 1\n    mv   s5, ra")
    assert tail != BK_TAIL
    tail = tail.replace("    li   t0, 'D'\n", "    li   t0, 1\n    beqz s9, 8f\n    slli t0, s9, 1\n    ori  t0, t0, 1\n8:  la   t1, tohost\n    sw   t0, 0(t1)\n    li   t0, 'D'\n", 1)
    assert "tohost" in tail
    out.append(tail)
    out += ["    " + t if t and not t.endswith(":") and not t.startswith(".") else t for t in TRAP]
    out += ["", "    .section .tohost, \"aw\"", "    .align 6", "    .globl tohost", "tohost: .dword 0", "    .globl fromhost", "fromhost: .dword 0"]
    dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pmp_test.S")
    open(dst, "w").write("\n".join(out) + "\n")
    traps = sum(1 for i in range(0, nsail) if ref[i] not in (0xff, 0) and i >= 10 * a.warl)
    print(f"wrote {os.path.normpath(dst)}: {g.n} checks ({nsail} from Sail); work {work}")

if __name__ == "__main__":
    main()
