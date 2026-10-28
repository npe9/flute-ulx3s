#!/usr/bin/env python3
"""Board test of the debug-module system bus (plan item 6) with Linux running.

Boots Linux, then over the UART DMI bridge, while the hart keeps running:
  1. reads REGION bytes of OpenSBI text at 0x80000000 with 32-bit sysbus reads and
     compares them with the payload file (OpenSBI text is PMP-protected from S/U-mode
     and never written at runtime, so the file is the reference);
  2. rewrites the same values back (no change to memory, so Linux is unaffected) as
     32-bit words, as bytes (sbaccess=0, every lane), and as 16-word autoincrement
     blocks (64 B, one Mem_Controller line), checking sberror / sbbusyerror;
  3. reads the region again and compares;
  4. distinct-value writes to SCRATCH (the padding after OpenSBI text inside its 256 KiB
     M-mode-only text region, 0x80036000-0x8003ffff on the current payload: Linux maps it
     nomap and OpenSBI never touches it): an address-derived pattern written as 64 B
     autoincrement blocks, then a second pattern over it as bytes, halfwords and words in
     a shuffled order, a reread checked against a host-side model, then zeroed again;
  5. disarms the bridge and waits for TICKS more Linux ticks with no panic.

PASS: no mismatches, no sysbus errors, Linux keeps ticking.

Usage: sysbus_board.py <fw_payload.bin> [-p port] [--region BYTES] [--log FILE]
Program the FPGA first.  Holds the serial port for the whole run.
"""
import argparse, os, re, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ndmreset_board as nb                             # noqa: E402
dmimod = nb.dmimod
BASE = 0x80000000
SCRATCH = 0x80038000          # inside the payload's zero padding (checked in main)
SCRATCH_BYTES = 0x4000


def sb_cfg(d, access, readonaddr, autoincr):
    sbcs = (access << 17) | 0x7000 | (1 << 22)         # clear sberror (W1C) and sbbusyerror (W1C)
    if readonaddr:
        sbcs |= 1 << 20
    if autoincr:
        sbcs |= 1 << 16
    d.wr(dmimod.DM_SBCS, sbcs)


def sb_check(d, where):
    sbcs = d.rd(dmimod.DM_SBCS)
    if (sbcs >> 12) & 7 or (sbcs >> 22) & 1 or (sbcs >> 21) & 1:
        raise RuntimeError("sysbus %s: sbcs=%#x (sberror=%d busyerror=%d busy=%d)"
                           % (where, sbcs, (sbcs >> 12) & 7, (sbcs >> 22) & 1, (sbcs >> 21) & 1))


def read_words(d, addr, n):
    sb_cfg(d, 2, True, False)
    out = []
    for i in range(n):
        d.wr(dmimod.DM_SBADDRESS0, addr + 4 * i)       # starts the fabric read
        out.append(d.rd(dmimod.DM_SBDATA0))
    sb_check(d, "read32 %#x" % addr)
    return out


def compare(ref, got, base, what):
    bad = [(i, r, g) for i, (r, g) in enumerate(zip(ref, got)) if r != g]
    for i, r, g in bad[:8]:
        print("  %s mismatch @%#x: file %08x  sysbus %08x" % (what, base + 4 * i, r, g))
    return len(bad)


def write_block(d, addr, words):
    sb_cfg(d, 2, False, True)
    d.wr(dmimod.DM_SBADDRESS0, addr)
    for w in words:
        d.wr(dmimod.DM_SBDATA0, w)
    sb_check(d, "block %#x" % addr)


def scratch_test(d, payload):
    import random
    off = SCRATCH - BASE
    if payload[off:off + SCRATCH_BYTES].strip(b"\0") or off + SCRATCH_BYTES > 0x40000:
        print("[sysbus] scratch region is not payload padding; skipped"); return 1
    n = SCRATCH_BYTES // 4
    rnd = random.Random(0x5B5B)
    model = bytearray(SCRATCH_BYTES)
    if any(read_words(d, SCRATCH, n)):
        print("[sysbus] scratch region not zero before the test"); return 1
    # pass 1: 64 B blocks of an address-derived pattern
    for line in range(n // 16):
        ws = [((SCRATCH + 64 * line + 4 * k) * 0x9E3779B1 ^ 0xA5A5A5A5) & 0xFFFFFFFF for k in range(16)]
        write_block(d, SCRATCH + 64 * line, ws)
        model[64 * line:64 * line + 64] = struct.pack("<16I", *ws)
    # pass 2: mixed-size overwrites in random order over the first 2 KiB
    ops = []
    for a in range(0, 2048, 4):
        kind = rnd.choice(("w", "h", "b"))
        if kind == "w":
            ops.append((a, 4))
        elif kind == "h":
            ops += [(a, 2), (a + 2, 2)]
        else:
            ops += [(a + i, 1) for i in range(4)]
    rnd.shuffle(ops)
    for a, size in ops:
        v = rnd.getrandbits(8 * size)
        sb_cfg(d, {1: 0, 2: 1, 4: 2}[size], False, False)
        d.wr(dmimod.DM_SBADDRESS0, SCRATCH + a)
        d.wr(dmimod.DM_SBDATA0, v)
        model[a:a + size] = v.to_bytes(size, "little")
    sb_check(d, "mixed writes")
    ref = list(struct.unpack("<%dI" % n, bytes(model)))
    m = compare(ref, read_words(d, SCRATCH, n), SCRATCH, "scratch")
    print("[sysbus] scratch %d B: %d block + %d mixed-size writes, %d mismatches"
          % (SCRATCH_BYTES, n // 16, len(ops), m), flush=True)
    for line in range(n // 16):
        write_block(d, SCRATCH + 64 * line, [0] * 16)
    z = sum(1 for w in read_words(d, SCRATCH, n) if w)
    if z:
        print("[sysbus] scratch not zero after cleanup: %d words" % z)
    return m + z


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("--region", type=lambda s: int(s, 0), default=0x4000)
    ap.add_argument("--ticks", type=int, default=5)
    ap.add_argument("--log", default="sysbus_board.log")
    args = ap.parse_args()
    payload = open(args.image, "rb").read()
    n = args.region // 4
    ref = list(struct.unpack("<%dI" % n, payload[:args.region]))
    log = open(args.log, "wb")

    d = dmimod.DMI(args.port)
    err = nb.boot(d.fd, payload, args.ticks, log)
    print("[sysbus] boot:", err or "ok", flush=True)
    if err:
        return 1
    fails = 0
    t0 = time.time()
    try:
        nb.arm_checked(d)
        print("[sysbus] sbcs=%#x dmstatus=%#x" % (d.rd(dmimod.DM_SBCS), d.rd(dmimod.DM_DMSTATUS)))
        if not (d.rd(dmimod.DM_DMSTATUS) >> 11) & 1:        # allrunning
            print("[sysbus] hart is not running"); fails += 1
        got = read_words(d, BASE, n)
        m = compare(ref, got, BASE, "read32"); fails += m
        print("[sysbus] read32 %d words: %d mismatches (%.1fs)" % (n, m, time.time() - t0), flush=True)

        # 32-bit same-value writes: every 4th word
        sb_cfg(d, 2, False, False)
        for i in range(0, n, 4):
            d.wr(dmimod.DM_SBADDRESS0, BASE + 4 * i)
            d.wr(dmimod.DM_SBDATA0, ref[i])
        sb_check(d, "write32")
        # byte writes, every lane, of words 1, 5, 9 ...
        sb_cfg(d, 0, False, False)
        for i in range(1, n, 4 * 8):
            for b in range(4):
                d.wr(dmimod.DM_SBADDRESS0, BASE + 4 * i + b)
                d.wr(dmimod.DM_SBDATA0, (ref[i] >> (8 * b)) & 0xFF)
        sb_check(d, "write8")
        # byte reads, every lane, of the same words
        sb_cfg(d, 0, True, False)
        mb = 0
        for i in range(1, n, 4 * 8):
            for b in range(4):
                d.wr(dmimod.DM_SBADDRESS0, BASE + 4 * i + b)
                g = d.rd(dmimod.DM_SBDATA0) & 0xFF
                if g != (ref[i] >> (8 * b)) & 0xFF:
                    mb += 1
                    if mb <= 8:
                        print("  read8 mismatch @%#x: %02x vs %02x" % (BASE + 4 * i + b, g, (ref[i] >> (8 * b)) & 0xFF))
        sb_check(d, "read8"); fails += mb
        # 64-byte autoincrement blocks (one line), every 4th line
        for line in range(0, n // 16, 4):
            a = BASE + 64 * line
            sb_cfg(d, 2, False, True)
            d.wr(dmimod.DM_SBADDRESS0, a)
            for k in range(16):
                d.wr(dmimod.DM_SBDATA0, ref[16 * line + k])
            sb_check(d, "block %#x" % a)
        got = read_words(d, BASE, n)
        m = compare(ref, got, BASE, "reread32"); fails += m
        print("[sysbus] writes + reread: %d mismatches, read8 %d (%.1fs)" % (m, mb, time.time() - t0), flush=True)
        fails += scratch_test(d, payload)
        print("[sysbus] scratch done (%.1fs)" % (time.time() - t0), flush=True)
        if not (d.rd(dmimod.DM_DMSTATUS) >> 11) & 1:
            print("[sysbus] hart is not running after the test"); fails += 1
        d.disarm()
    except Exception as e:                              # noqa: BLE001
        print("[sysbus] FAIL: %s" % (e,)); return 1
    # Linux must keep ticking: wait for a tick past the last one seen
    buf = b""
    end = time.time() + 60
    ticks = []
    while time.time() < end and len(set(ticks)) < args.ticks + 1:
        pat, b = nb.wait_for(d.fd, [b"fp ok"], 5, log)
        if pat is not None and pat != b"fp ok":
            print("[sysbus] bad output: %r" % (pat,)); return 1
        ticks += re.findall(rb"tick (\d+) ", b)
    print("[sysbus] ticks after test: %s" % sorted({int(t) for t in ticks})[-3:])
    if len(set(ticks)) < 2:
        print("[sysbus] Linux stopped ticking"); fails += 1
    print("[sysbus] %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
