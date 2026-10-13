#!/usr/bin/env python3
"""DMI client for the ULX3S UART debug bridge.

Talks to Flute's RISC-V Debug Module (spec v0.13) through the
Uart_DMI_Bridge FPGA module over the same FTDI UART the REPL uses --
no JTAG wires, no external adapter.

The bridge snoops the RX stream for the 8-byte magic
"\xDBSDM\x01\x02\x03\x04"; after that, requests are fixed 6-byte
frames  [op, dmi_addr, data(4, big-endian)]  and responses are framed
6-byte records  [0xDB, status, data(4, big-endian)]  (the 0xDB marker
lets the host resynchronize past console output that flushed ahead of
a response).

Usage:
    python3 dmi.py -p /dev/cu.usbserial-120001 <command> [args]

Commands:
    info                dmstatus / dmcontrol / hartinfo
    halt                halt the hart
    resume              resume the hart
    regs                dump x0..x31 via abstract commands (halts first)
    pc                  print dpc; disassemble around it if a blob is found
    go <addr>           set dpc and resume
    rd  <dm-addr>       raw DMI register read  (hex)
    wr  <dm-addr> <val> raw DMI register write (hex)
    mem <addr> [words]  read words over the system bus (hex, default 16)
    poke <addr> <val>    write a word over the system bus (hex)
    disarm              exit debug mode (console pass-through resumes)

Examples:
    # catch the REPL hang: halt, look at where it is
    python3 dmi.py -p /dev/cu.usbserial-120001 halt pc regs resume

    # memory peek at the UART (16550) registers
    python3 dmi.py -p /dev/cu.usbserial-120001 mem 0x10013000 8

Only one client may hold the serial port at a time; close any
screen/picocom session first.
"""

import argparse
import bisect
import os
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

MAGIC = b"\xdbSDM\x01\x02\x03\x04"

# Debug Module register addresses (RISC-V External Debug Support 0.13)
DM_DMCONTROL = 0x10
DM_DMSTATUS = 0x11
DM_HARTINFO = 0x12
DM_ABSTRACTCS = 0x16
DM_COMMAND = 0x17
DM_DATA0 = 0x04
DM_SBCS = 0x38
DM_SBADDRESS0 = 0x39
DM_SBDATA0 = 0x3C

# abstract command: access register, 32-bit, transfer
AC_READ = (2 << 20) | (1 << 17)
AC_WRITE = (2 << 20) | (1 << 17) | (1 << 16)

CSR_DPC = 0x7B1


def open_serial(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    baud_const = {
        9600: termios.B9600,
        19200: termios.B19200,
        38400: termios.B38400,
        57600: termios.B57600,
        115200: termios.B115200,
    }.get(baud)
    attrs = termios.tcgetattr(fd)
    if baud_const is not None:
        attrs[4] = attrs[5] = baud_const
    else:
        attrs[4] = attrs[5] = termios.B115200
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[2] &= ~termios.CSIZE
    attrs[2] |= termios.CS8
    attrs[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
    attrs[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN)
    attrs[0] &= ~(termios.IXON | termios.IXOFF | termios.ICRNL | termios.INLCR | termios.IGNCR)
    attrs[1] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    if baud_const is None:
        import fcntl
        IOSSIOSPEED = 0x80045402
        fcntl.ioctl(fd, IOSSIOSPEED, struct.pack("I", baud))
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_exact(fd, n, timeout):
    buf = b""
    deadline = time.monotonic() + timeout
    while len(buf) < n:
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError(f"timed out after {len(buf)}/{n} bytes")
        r, _, _ = select.select([fd], [], [], left)
        if not r:
            continue
        chunk = os.read(fd, n - len(buf))
        if not chunk:
            raise TimeoutError("serial port closed")
        buf += chunk
    return buf


class DMI:
    def __init__(self, port, baud=625000):
        self.fd = open_serial(port, baud)
        self.armed = False
        self.buf = b""

    def close(self):
        if self.armed:
            try:
                self.disarm()
            except Exception:
                pass
        os.close(self.fd)

    # -- bridge framing -------------------------------------------------

    def arm(self):
        os.write(self.fd, MAGIC)
        self.armed = True
        # Validate: dmstatus low nibble is the version (2 = spec 0.13).
        for _ in range(3):
            try:
                st = self.rd(DM_DMSTATUS)
                if st & 0xF:
                    return st
            except TimeoutError:
                pass
            os.write(self.fd, MAGIC)
        raise RuntimeError(
            "no response from debug bridge -- is the bridge bitstream "
            "flashed? is another program holding the port?"
        )

    def req(self, op, addr, data, _reattempts=2):
        os.write(self.fd, bytes([op, addr & 0x7F]) + struct.pack(">I", data & 0xFFFFFFFF))
        try:
            return self._response(op, 2.0)
        except TimeoutError:
            if _reattempts <= 0:
                raise
            # The bridge can drop out of DMI mode under host CPU UART
            # traffic (observed after ~10 ops with the REPL running).
            # Re-announce the magic and retry the request once; stale
            # response frames are harmless (0xDB resync in _response).
            time.sleep(0.05)
            os.write(self.fd, MAGIC)
            time.sleep(0.05)
            return self.req(op, addr, data, _reattempts - 1)

    def _response(self, op, timeout_s):
        deadline = time.monotonic() + timeout_s
        while True:
            # Responses are 0xDB-marked 6-byte records; console output
            # may flush ahead of them, so scan rather than assume
            # alignment.
            i = self.buf.find(b"\xdb")
            if i >= 0 and len(self.buf) >= i + 6:
                frame = self.buf[i:i + 6]
                self.buf = self.buf[i + 6:]
                status = frame[1]
                val = struct.unpack(">I", frame[2:])[0]
                if status == 0:
                    return val
                if status == 2:
                    raise RuntimeError(f"bridge rejected op {op:#x}")
                # stray 0xDB in console output: keep scanning
                continue
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("debug bridge not responding")
            r, _, _ = select.select([self.fd], [], [], left)
            if r:
                chunk = os.read(self.fd, 4096)
                if not chunk:
                    raise TimeoutError("serial port closed")
                self.buf += chunk

    # -- console pass-through ------------------------------------------------
    #
    # Console bytes that arrived interleaved with DMI responses are
    # stranded in self.buf; any console reading MUST go through here so
    # buffered bytes are not lost.

    def read_console(self, timeout, idle=0.5):
        """Return console bytes received within `timeout` seconds.

        Once the first byte arrives, returns after `idle` seconds of
        silence (or when `timeout` elapses), so callers don't burn the
        whole window when the output they want has already landed.
        """
        deadline = time.monotonic() + timeout
        out = b""
        quiet_deadline = None
        while True:
            if self.buf:
                out += self.buf
                self.buf = b""
                quiet_deadline = time.monotonic() + idle
            if quiet_deadline is not None and time.monotonic() >= quiet_deadline:
                return out
            left = deadline - time.monotonic()
            if left <= 0:
                return out
            if quiet_deadline is not None:
                left = min(left, quiet_deadline - time.monotonic())
            r, _, _ = select.select([self.fd], [], [], max(left, 0.001))
            if not r:
                if quiet_deadline is not None and time.monotonic() >= quiet_deadline:
                    return out
                if time.monotonic() >= deadline:
                    return out
                continue
            chunk = os.read(self.fd, 4096)
            if not chunk:
                return out
            out += chunk

    def write_console(self, data):
        # O_NONBLOCK fd: os.write may short-write once the driver
        # buffer fills; loop with select backpressure until everything
        # is accepted.
        mv = memoryview(data)
        while mv:
            try:
                n = os.write(self.fd, mv)
            except BlockingIOError:
                n = 0
            if n:
                mv = mv[n:]
            else:
                select.select([], [self.fd], [], 0.05)

    def disarm(self):
        self.req(ord("q"), 0, 0)
        self.armed = False

    # -- raw DMI ---------------------------------------------------------

    def rd(self, addr):
        return self.req(ord("r"), addr, 0)

    def wr(self, addr, val):
        self.req(ord("w"), addr, val)

    # -- run control -----------------------------------------------------

    def halted(self):
        return bool(self.rd(DM_DMSTATUS) & 0x100)   # anyhalted

    def running(self):
        return bool(self.rd(DM_DMSTATUS) & 0x800)   # anyrunning (bit 11)

    def halt(self, timeout=2.0):
        self.wr(DM_DMCONTROL, 0x80000001)           # haltreq | dmactive
        deadline = time.monotonic() + timeout
        while not self.halted():
            if time.monotonic() > deadline:
                raise TimeoutError("hart did not halt")
            time.sleep(0.01)

    def resume(self, timeout=2.0):
        self.wr(DM_DMCONTROL, 0x40000001)           # resumereq | dmactive
        deadline = time.monotonic() + timeout
        while True:
            st = self.rd(DM_DMSTATUS)
            if st & 0x10000:                        # anyresumeack
                return
            if time.monotonic() > deadline:
                raise TimeoutError("hart did not resume")

    # -- abstract commands (need halted hart) ----------------------------

    def abstract(self, write, regno, value=0):
        self.wr(DM_ABSTRACTCS, 0x700)               # clear cmderr (W1C)
        if write:
            self.wr(DM_DATA0, value)
        self.wr(DM_COMMAND, (AC_WRITE if write else AC_READ) | regno)
        deadline = time.monotonic() + 2.0
        while True:
            cs = self.rd(DM_ABSTRACTCS)
            if not (cs & 0x1000):                   # busy
                break
            if time.monotonic() > deadline:
                raise TimeoutError("abstract command stuck busy")
        err = (cs >> 8) & 7
        if err:
            raise RuntimeError(f"abstract command error {err} (regno {regno:#x})")
        return self.rd(DM_DATA0)

    def read_gpr(self, n):
        return self.abstract(False, 0x1000 + n)

    def write_gpr(self, n, value):
        self.abstract(True, 0x1000 + n, value)

    def read_csr(self, csr):
        return self.abstract(False, csr)

    def write_csr(self, csr, value):
        self.abstract(True, csr, value)

    # -- system bus -------------------------------------------------------
    #
    # This Debug Module initiates a fabric READ by *writing* sbaddress0
    # with sbcs.sbreadonaddr set (reading sbdata0 alone just returns the
    # previous value).  Writes are initiated by writing sbdata0.

    def _sb_config(self, autoincr=False, readonaddr=True):
        # sbaccess=2 (32-bit) | sbreadonaddr | sbautoincrement |
        # clear sberror (W1C 7)
        sbcs = (2 << 17) | (0x7000)
        if readonaddr:
            sbcs |= 1 << 20
        if autoincr:
            sbcs |= 1 << 16
        self.wr(DM_SBCS, sbcs)

    def _sb_error(self):
        return (self.rd(DM_SBCS) >> 12) & 7

    def mem_read32(self, addr):
        self._sb_config()
        self.wr(DM_SBADDRESS0, addr)      # triggers the fabric read
        self.rd(DM_DMSTATUS)              # ~200us round trip: read completes
        val = self.rd(DM_SBDATA0)
        err = self._sb_error()
        if err:
            raise RuntimeError(f"system bus error {err} at {addr:#x}")
        return val

    def mem_read(self, addr, words):
        out = []
        self._sb_config()
        for i in range(words):
            self.wr(DM_SBADDRESS0, addr + 4 * i)   # triggers the fabric read
            self.rd(DM_DMSTATUS)                   # ~200us: read completes
            val = self.rd(DM_SBDATA0)
            err = self._sb_error()
            if err:
                raise RuntimeError(f"system bus error {err} at {addr + 4 * i:#x}")
            out.append(val)
        return out

    def mem_write32(self, addr, val):
        self._sb_config(readonaddr=False)
        self.wr(DM_SBADDRESS0, addr)
        self.wr(DM_SBDATA0, val)          # write is initiated here
        err = self._sb_error()
        if err:
            raise RuntimeError(f"system bus error {err} at {addr:#x}")


ABI = [
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
]


class SymbolMap:
    """Loads the AOT blob map (addr name lines, runtime base 0x80000000)."""

    def __init__(self, path):
        self.syms = []
        try:
            with open(path) as f:
                for ln in f:
                    m = re.match(r"\s*([0-9a-f]+)\s+(\S+)", ln)
                    if m:
                        self.syms.append((int(m.group(1), 16) + 0x80000000, m.group(2)))
            self.syms.sort()
        except OSError:
            pass

    def lookup(self, addr):
        if not self.syms:
            return None
        idx = bisect.bisect_right(self.syms, (addr, chr(0x10FFFF))) - 1
        if idx < 0:
            return None
        base, name = self.syms[idx]
        return name, addr - base


def disassemble(pc, words):
    blob = b"".join(struct.pack("<I", w) for w in words)
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(blob)
        path = f.name
    try:
        out = subprocess.run(
            ["riscv64-unknown-elf-objdump", "-b", "binary", "-m", "riscv",
             "-D", f"--adjust-vma={pc:#x}", path],
            capture_output=True, text=True, timeout=10,
        ).stdout
        return "\n".join(
            ln for ln in out.splitlines()
            if re.match(r"\s*[0-9a-f]+:", ln)
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    finally:
        os.unlink(path)


def cmd_info(dmi):
    st = dmi.rd(DM_DMSTATUS)
    ctrl = dmi.rd(DM_DMCONTROL)
    hartinfo = dmi.rd(DM_HARTINFO)
    print(f"dmstatus   = {st:#010x}  version={st & 0xf} "
          f"{'HALTED' if st & 0x100 else ''}{'RUNNING' if st & 0x800 else ''}")
    print(f"dmcontrol  = {ctrl:#010x}  haltreq={bool(ctrl & 0x80000000)} "
          f"ndmreset={bool(ctrl & 2)} dmactive={bool(ctrl & 1)}")
    print(f"hartinfo   = {hartinfo:#010x}")


def cmd_regs(dmi, restore):
    was_running = dmi.running()
    if was_running:
        dmi.halt()
    print(f"{'reg':>4}  {'abi':>4}  {'value':>10}")
    for n in range(32):
        print(f"x{n:<3}  {ABI[n]:>4}  {dmi.read_gpr(n):#010x}")
    pc = dmi.read_csr(CSR_DPC)
    print(f"dpc (saved pc) = {pc:#010x}")
    if restore and was_running:
        dmi.resume()
        print("(hart resumed)")


def cmd_pc(dmi, symmap):
    was_running = dmi.running()
    if was_running:
        dmi.halt()
    pc = dmi.read_csr(CSR_DPC)
    loc = symmap.lookup(pc) if symmap else None
    where = f"{loc[0]}+{loc[1]:#x}" if loc else "?"
    print(f"dpc = {pc:#010x}   ({where})")
    try:
        words = dmi.mem_read(pc & ~3, 16)
        dis = disassemble(pc & ~3, words)
        if dis:
            print(dis)
    except RuntimeError as e:
        print(f"(disassembly unavailable: {e})")
    if was_running:
        dmi.resume()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--port", default="/dev/cu.usbserial-120001")
    ap.add_argument("-b", "--baud", type=int, default=625000)
    ap.add_argument("--map", default=os.path.join(
        os.path.dirname(__file__), "..", "templeos", "build", "ulx3s_repl.map"))
    ap.add_argument("--stay", action="store_true",
                    help="leave the hart halted after regs/pc (default: restore)")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    if not args.command:
        ap.print_help()
        return 1

    dmi = DMI(args.port, args.baud)
    try:
        dmi.arm()

        cmd, rest = args.command[0], args.command[1:]
        if cmd == "info":
            cmd_info(dmi)
        elif cmd == "halt":
            dmi.halt()
            print("halted")
        elif cmd == "resume":
            dmi.resume()
            print("resumed")
        elif cmd == "go":
            addr = int(rest[0], 16)
            was_running = dmi.running()
            if was_running:
                dmi.halt()
            dmi.write_csr(CSR_DPC, addr)
            dmi.resume()
            print(f"dpc = {addr:#x}, resumed")
        elif cmd == "regs":
            cmd_regs(dmi, restore=not args.stay)
        elif cmd == "pc":
            symmap = SymbolMap(args.map)
            cmd_pc(dmi, symmap)
        elif cmd == "rd":
            print(f"{dmi.rd(int(rest[0], 16)):#010x}")
        elif cmd == "wr":
            dmi.wr(int(rest[0], 16), int(rest[1], 16))
            print("ok")
        elif cmd == "poke":
            addr = int(rest[0], 16)
            val = int(rest[1], 16)
            dmi.mem_write32(addr, val)
            print(f"{addr:#010x} <- {val:#010x}")
        elif cmd == "mem":
            addr = int(rest[0], 16)
            n = int(rest[1], 16) if len(rest) > 1 else 16
            for i, w in enumerate(dmi.mem_read(addr, n)):
                print(f"{addr + 4 * i:#010x}: {w:#010x}")
        elif cmd == "disarm":
            dmi.disarm()
            print("disarmed")
        else:
            print(f"unknown command: {cmd}", file=sys.stderr)
            return 1
        return 0
    finally:
        dmi.close()


if __name__ == "__main__":
    sys.exit(main())
