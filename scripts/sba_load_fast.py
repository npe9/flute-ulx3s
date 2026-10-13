#!/usr/bin/env python3
"""Fast pipelined SBA image loader.

The bridge is strictly request/response, but the host can pipeline:
send K requests back-to-back, then read K responses.  At 625000 baud a
single request costs ~1 ms of Python/UART round trip; pipelined K=32 the
same path sustains ~30x that rate.

Flow: halt -> pipelined SBA write (autoincrement) -> pipelined readback
verify -> rewrite any bad words (up to 4 rounds) -> set dpc + resume.

Usage:
    python3 sba_load_fast.py <image> [-p PORT] [-a ADDR] [--no-go]
"""

import argparse
import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from dmi import (DMI, DM_SBCS, DM_SBADDRESS0, DM_SBDATA0,
                 open_serial, read_exact, MAGIC)

SBCS_CFG = (2 << 17) | (1 << 20) | 0x7000     # 32-bit, readonaddr, clear sberror
SBCS_AI = SBCS_CFG | (1 << 16)                  # + autoincrement (writes)


class Pipe:
    """Pipelined DMI request stream over an armed bridge."""

    def __init__(self, dmi, window=32):
        self.d = dmi
        self.fd = dmi.fd
        self.window = window
        self.buf = b""
        self.pending = 0

    def _pump(self):
        """Read whatever is available into self.buf."""
        import os, select
        while True:
            r, _, _ = select.select([self.fd], [], [], 0)
            if not r:
                return
            c = os.read(self.fd, 65536)
            if not c:
                return
            self.buf += c

    def _take(self):
        """Extract one 0xDB-framed response record."""
        while True:
            i = self.buf.find(b"\xdb")
            if i >= 0 and len(self.buf) >= i + 6:
                rec = self.buf[i:i + 6]
                self.buf = self.buf[i + 6:]
                return rec[1], struct.unpack(">I", rec[2:])[0]
            import os, select
            r, _, _ = select.select([self.fd], [], [], 2.0)
            if not r:
                raise TimeoutError("pipeline starved")
            c = os.read(self.fd, 65536)
            if not c:
                raise TimeoutError("port closed")
            self.buf += c

    def wr_n(self, addr, val):
        self.d.write_console(bytes([ord("w"), addr & 0x7F])
                             + struct.pack(">I", val & 0xFFFFFFFF))
        self.pending += 1
        if self.pending >= self.window:
            self.flush()

    def flush(self):
        while self.pending:
            st, _ = self._take()
            if st != 0:
                raise RuntimeError(f"bridge status {st:#x}")
            self.pending -= 1

    def rd(self, addr):
        """Single read with pipeline drained (for correctness)."""
        self.flush()
        self.d.write_console(bytes([ord("r"), addr & 0x7F])
                             + struct.pack(">I", 0))
        while True:
            st, v = self._take()
            if st == 0:
                return v
            if st != 2:
                raise RuntimeError(f"bridge status {st:#x}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("image")
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("-b", "--baud", type=int, default=625000)
    ap.add_argument("-a", "--addr", default="0x80000000")
    ap.add_argument("--no-go", action="store_true")
    ap.add_argument("--window", type=int, default=32)
    args = ap.parse_args()

    addr = int(args.addr, 16)
    data = open(args.image, "rb").read()
    assert len(data) % 4 == 0
    n = len(data) // 4
    words = struct.unpack(f"<{n}I", data)

    dmi = DMI(args.port, args.baud)
    try:
        dmi.arm()
        dmi.halt()
        pipe = Pipe(dmi, args.window)

        def write_block(base, count):
            dmi.wr(DM_SBCS, SBCS_AI)
            dmi.wr(DM_SBADDRESS0, addr + 4 * base)
            for i in range(base, base + count):
                pipe.wr_n(DM_SBDATA0, words[i])
            pipe.flush()

        t0 = time.monotonic()
        CH = 16384
        for base in range(0, n, CH):
            write_block(base, min(CH, n - base))
            done = min(base + CH, n)
            rate = done / (time.monotonic() - t0)
            print(f"[sba] write {done * 100 // n}% "
                  f"({time.monotonic() - t0:.0f}s, {rate:.0f} w/s)",
                  file=sys.stderr, flush=True)

        # verify-all, pipelined: readondata+autoincrement means one
        # DMI read per word after priming.
        def verify_all():
            dmi.wr(DM_SBCS, SBCS_AI | (1 << 15))   # + readondata? no:
            # this DM reads via readonaddr instead; per-word: wr addr,
            # rd data  -> 2 ops.  Use pipelining on the pair.
            bad = []
            dmi.wr(DM_SBCS, SBCS_CFG)
            for i in range(n):
                dmi.write_console(bytes([ord("w"), DM_SBADDRESS0])
                                  + struct.pack(">I", addr + 4 * i))
                dmi.write_console(bytes([ord("r"), DM_SBDATA0])
                                  + struct.pack(">I", 0))
                pipe.pending += 2
                if pipe.pending >= pipe.window:
                    # drain: expect alternating (w-ack, r-data) but both
                    # are 6-byte records; status 0 + data
                    got = []
                    while pipe.pending:
                        st, v = pipe._take()
                        if st != 0:
                            raise RuntimeError(f"bridge {st:#x}")
                        got.append(v)
                        pipe.pending -= 1
                    # got = [ack(w), data(r)] pairs
                    for j in range(0, len(got), 2):
                        pass  # ack consumed; data handled below
            pipe.flush()
            return bad

        # Simpler correct verify: per word rd() is slow; instead do the
        # interleaved pipeline manually here.
        def verify_all2():
            bad = []
            dmi.wr(DM_SBCS, SBCS_CFG)
            i = 0
            W = pipe.window // 2
            while i < n:
                batch = min(W, n - i)
                for k in range(batch):
                    dmi.write_console(bytes([ord("w"), DM_SBADDRESS0])
                                      + struct.pack(">I", addr + 4 * (i + k)))
                    dmi.write_console(bytes([ord("r"), DM_SBDATA0])
                                      + struct.pack(">I", 0))
                pipe.pending += 2 * batch
                vals = []
                while pipe.pending:
                    st, v = pipe._take()
                    if st != 0:
                        raise RuntimeError(f"bridge {st:#x}")
                    vals.append(v)
                    pipe.pending -= 1
                # pairs: (write-ack 0, read-data word)
                for k in range(batch):
                    w_ack, got = vals[2 * k], vals[2 * k + 1]
                    if got != words[i + k]:
                        bad.append((i + k, got))
                i += batch
            return bad

        t0 = time.monotonic()
        for round_ in range(4):
            bad = verify_all2()
            print(f"[sba] verify round {round_}: {len(bad)} bad "
                  f"({time.monotonic() - t0:.0f}s)", file=sys.stderr, flush=True)
            if not bad:
                break
            # rewrite bad words (single ops, correctness over speed)
            dmi.wr(DM_SBCS, SBCS_CFG)
            for i, _ in bad:
                dmi.wr(DM_SBADDRESS0, addr + 4 * i)
                dmi.wr(DM_SBDATA0, words[i])
            for i, got in bad[:8]:
                print(f"    word {i}: got {got:#010x} exp {words[i]:#010x}",
                      file=sys.stderr)

        if not args.no_go:
            dmi.write_csr(0x7B1, addr)
            dmi.resume()
            print("[sba] go!", file=sys.stderr)
    finally:
        dmi.close()


if __name__ == "__main__":
    main()
