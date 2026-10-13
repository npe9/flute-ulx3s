#!/usr/bin/env python3
"""ULX3S Flute SoC — interface conformance test suite.

Programs the FPGA, loads the TempleOS REPL over the UART, and exercises
every interface surface end to end: eval core, observability commands,
trap/fault recovery, the self-describing SoC block, the bus error
monitor, GPIO (via DMI poke), and the RISC-V debug module.  Produces a
PASS/WARN/FAIL inventory with captured output for every failure.

Levels:
  required -- a regression here is a FAIL (exit 1)
  partial  -- known-thin upstream behavior (documented, tracked as WARN)

Usage: python3 scripts/hw_test_suite.py [--quick]
"""

import argparse
import base64
import os
import re
import struct
import subprocess
import sys
import termios
import fcntl
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmi import DMI  # noqa: E402

PORT = '/dev/cu.usbserial-120001'
BAUD = 625000
BITSTREAM = 'build/ulx3s_top.bit'
BLOB = 'templeos/build/ulx3s_repl.blob.bin'
CHUNK = 256

results = []  # (level, name, status, detail)


def record(level, name, status, detail=''):
    results.append((level, name, status, detail))
    mark = {'PASS': 'PASS', 'FAIL': 'FAIL', 'WARN': 'WARN', 'SKIP': 'SKIP'}[status]
    line = f'{mark}  {name}'
    if detail:
        line += f'  -- {detail}'
    print(line, flush=True)


# ---------------------------------------------------------------- UART I/O

def open_port():
    for _ in range(30):
        fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            a = termios.tcgetattr(fd)
            a[0] = a[1] = a[3] = 0
            a[2] = termios.CREAD | termios.CLOCAL | termios.CS8
            termios.tcsetattr(fd, termios.TCSANOW, a)
            fcntl.ioctl(fd, 0x80045402, struct.pack('I', BAUD))
            return fd
        except (termios.error, OSError):
            os.close(fd)
            time.sleep(0.5)
    raise RuntimeError('port not ready')


def drain(fd, t):
    time.sleep(t)
    d = b''
    try:
        while True:
            d += os.read(fd, 65536)
    except (BlockingIOError, OSError):
        pass
    return d


def wait_prompt(fd, timeout=30.0):
    """Read until the REPL prompt goes quiet (ends with '> ')."""
    buf = b''
    t0 = time.time()
    last = time.time()
    while time.time() - t0 < timeout:
        try:
            d = os.read(fd, 4096)
            if d:
                buf += d
                last = time.time()
                if buf.endswith(b'> '):
                    time.sleep(0.4)
                    try:
                        while True:
                            buf += os.read(fd, 65536)
                    except (BlockingIOError, OSError):
                        pass
                    return buf
        except (BlockingIOError, OSError):
            pass
        if time.time() - last > 3.0 and buf.endswith(b'> '):
            return buf
        time.sleep(0.02)
    return buf


def settle(fd, quiet=1.5, cap=90.0):
    """Wait for the console to go quiet (long crash dumps and $HC_DUMP
    framing take seconds; a fixed pre-drain is not enough).  An idle
    console (no bytes for `quiet`) is already settled."""
    buf = b''
    t0 = time.time()
    last = time.time()
    saw = False
    while time.time() - t0 < cap:
        try:
            d = os.read(fd, 4096)
            if d:
                buf += d
                last = time.time()
                saw = True
        except (BlockingIOError, OSError):
            pass
        idle = time.time() - last
        if not saw and idle > quiet:
            return                       # console already idle at a prompt
        if saw and buf.endswith(b'> ') and idle > quiet:
            return                       # drained to a fresh prompt
        time.sleep(0.05)


def send_line(fd, line, timeout=45.0):
    settle(fd)
    os.write(fd, line.encode() + b'\r\n')
    return wait_prompt(fd, timeout).decode('latin-1')


def load_blob(fd, blob):
    drain(fd, 2.0)
    os.write(fd, struct.pack('<II', 0x80000000, len(blob)))
    for ci in range((len(blob) + CHUNK - 1) // CHUNK):
        ck = blob[ci * CHUNK:(ci + 1) * CHUNK]
        x = 0
        for b in ck:
            x ^= b
        for _retry in range(8):
            os.write(fd, bytes([ci & 0xFF]) + ck + bytes([x, 0x55]))
            buf = b''
            t0 = time.time()
            ok = False
            while time.time() - t0 < 2.5:
                try:
                    d = os.read(fd, 256)
                    if d:
                        buf += d
                        if b'\x06' in buf:
                            ok = True
                            break
                        if b'\x15' in buf:
                            break
                except (BlockingIOError, OSError):
                    pass
                time.sleep(0.001)
            if ok:
                break
        else:
            raise RuntimeError(f'load failed at chunk {ci}')


def hc_dump_words(fd, addr, n_u32):
    """DumpMem over the REPL; returns list of u32 or None (with retry)."""
    for attempt, timeout in ((1, 30.0), (2, 60.0)):
        out = send_line(fd, f'DumpMem({addr:#x}, {n_u32 * 4}, "t")', timeout)
        m = re.search(r'\$HC_DUMP[^\n]*\n([A-Za-z0-9+/=]+)', out)
        if m:
            raw = base64.b64decode(m.group(1))
            return [int.from_bytes(raw[k:k + 4], 'little')
                    for k in range(0, len(raw), 4)]
        if attempt == 2:
            print(f'    dump debug: {out[-200:]!r}')
    return None


# ---------------------------------------------------------------- checks

def check_repl(level, name, fd, line, expect=(), forbid=('FAULT',),
               timeout=30.0):
    out = send_line(fd, line, timeout)
    missing = [e for e in expect if e not in out]
    bad = [e for e in forbid if e in out]
    if missing or bad:
        detail = ''
        if missing:
            detail += f'missing {missing!r}'
        if bad:
            detail += f' forbidden {bad!r}'
        record(level, name, 'FAIL', detail)
        print(f'    captured: {out[-300:]!r}')
        return None
    record(level, name, 'PASS')
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--quick', action='store_true',
                    help='skip the (long) full Regs; dump test')
    args = ap.parse_args()

    print('== programming FPGA + loading REPL ==', flush=True)
    subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', BITSTREAM],
                   capture_output=True)
    fd = open_port()
    blob = open(BLOB, 'rb').read()
    load_blob(fd, blob)
    boot = b''
    t0 = time.time()
    while time.time() - t0 < 240:
        boot += drain(fd, 2.0)
        if boot.endswith(b'> '):
            break
    if not boot.endswith(b'> '):
        print('REPL never reached a prompt')
        return 1
    print('REPL up.', flush=True)

    # ---------------- A. eval core ----------------
    print('\n== A. eval core ==', flush=True)
    check_repl('required', 'arith precedence', fd, '2+3*4;',
               expect=('ans=', '=14'))
    check_repl('required', 'parens', fd, '(2+3)*4;', expect=('=20',))
    check_repl('required', 'division', fd, '100/7;', expect=('=14',))
    check_repl('required', ' Print literal', fd, 'Print("hello-tst");',
               expect=('hello-tst',))
    r = check_repl('partial', 'Print("%d",expr) I64 pair (hi-half P1)', fd,
                   'Print("%d", 6*7);', expect=(), forbid=('FAULT',))
    if r:
        record('partial', 'Print("%d",expr) I64 pair (hi-half P1)', 'WARN',
               'observed ' + r.strip().split('\r\n')[-2][:60])
    check_repl('required', 'string statement', fd, '"direct-txt";',
               expect=('direct-txt',))
    check_repl('required', 'typed global', fd, 'I64 gv = 40;')
    check_repl('required', 'global readback', fd, 'gv+2;', expect=('=42',))
    check_repl('required', 'fun def + call', fd,
               'I64 Add2(I64 a,I64 b) { return a+b; }')
    r = check_repl('partial', 'multi-arg I64 pair (hi-half P1)',
                   fd, 'Add2(19,23);', expect=('002a',), forbid=())
    if r and '170000002a' not in r:
        record('partial', 'multi-arg I64 pair (hi-half P1)', 'WARN',
               'unexpected: ' + r[-120:].replace('\r', '').replace('\n', '|'))
    check_repl('required', 'void fun', fd, 'U0 Hi2() { Print("hi2-txt"); }')
    check_repl('required', 'void fun call', fd, 'Hi2();', expect=('hi2-txt',))
    r = check_repl('partial', 'for-loop I64 pair (hi-half P1)', fd,
                   'for (I64 i=0;i<3;i++) Print("%d",i);',
                   expect=(), forbid=('FAULT',))
    if r:
        record('partial', 'for-loop I64 pair (hi-half P1)', 'WARN',
               '3 iterations ran; hi-half garbage in %d (P1)')
    check_repl('required', 'asm eval', fd, 'asm { li a0, 42; }')
    check_repl('required', 'Reg after asm', fd, 'Reg("a0");',
               expect=('x10/a0', '002a'))

    # ---------------- B. observability ----------------
    print('\n== B. observability ==', flush=True)
    check_repl('required', 'Sys', fd, 'Sys;',
               expect=('--- uptime ---', '--- mem ---', '--- devices ---',
                       '0xC0000000'))
    check_repl('required', 'Uptime', fd, 'Uptime;', expect=('up ', 'ticks'))
    check_repl('required', 'MemRep', fd, 'MemRep;',
               expect=('--- mem ---', 'heap'))
    check_repl('required', 'IrqRep', fd, 'IrqRep;', expect=('--- irq ---',))
    check_repl('required', 'DevRep', fd, 'DevRep;',
               expect=('--- devices ---', 'RVUart16550'))
    check_repl('required', 'Cnts', fd, 'Cnts;', expect=('dmesg=',))
    check_repl('required', 'DMesg', fd, 'DMesg;',
               expect=('[', '] I boot'))
    check_repl('required', 'Regs', fd, 'Regs;',
               expect=('GPRs at', 'mstatus', 'misa'),
               timeout=60.0 if not args.quick else 30.0)
    check_repl('required', 'Reg a0', fd, 'Reg("a0");', expect=('x10/a0',))
    check_repl('required', 'Reg mstatus', fd, 'Reg("mstatus");',
               expect=('mstatus', 'MIE'))
    check_repl('required', 'Reg misa', fd, 'Reg("misa");',
               expect=('misa', '40101105'))
    r = check_repl('required', 'MemMap live header', fd, 'MemMap;',
                   expect=('SoC info (live @ C0003000): ver=1',
                           'PLIC              RESERVED VOID',
                           'W9825G6KH', 'absent on Flute'))
    if r:
        m = re.search(r'features=0x([0-9A-Fa-f]+) devices=(\d+) buserr=(\d+)',
                      r)
        if m:
            feats = int(m.group(1), 16)
            for bit, nm in ((0, 'uart0'), (2, 'clint'), (3, 'soc_info'),
                            (4, 'buserr_mon')):
                if not (feats >> bit) & 1:
                    record('required', f'features bit {bit} ({nm})',
                           'FAIL', f'features=0x{feats:x}')
                    break
            else:
                record('required', 'features bits (uart/clint/socinfo/buserr)',
                       'PASS', f'features=0x{feats:x} devices={m.group(2)}')
    check_repl('required', 'MemMapDrv', fd, 'MemMapDrv;',
               expect=('RVUart16550', 'fs.hc'))
    check_repl('required', 'Man function page', fd, 'Man("Print");',
               expect=('Print:', 'section'))
    check_repl('required', 'Man topic page', fd, 'Man("CLINT");',
               expect=('CLINT',))
    check_repl('required', 'Sections', fd, 'Sections;',
               expect=('shell/cmds',))
    check_repl('partial', 'FunsList (upstream partial)', fd, 'FunsList;',
               forbid=())
    check_repl('partial', 'Funs picker (upstream partial)', fd,
               'Funs("Print");', forbid=())
    check_repl('required', 'Dir', fd, 'Dir;')
    check_repl('required', 'Pwd', fd, 'Pwd;', expect=('/',))
    check_repl('required', 'help', fd, 'help;',
               expect=('Eval', 'Sys'))
    check_repl('required', 'Tty', fd, 'Tty;', expect=('mode=',))
    check_repl('required', 'VtList', fd, 'VtList;', expect=('repl',))
    check_repl('required', 'LogCount', fd, 'LogCount;',
               expect=('log_count=',))

    # CRLF discipline: every \n in a response must be preceded by \r
    out = send_line(fd, 'Uptime;')
    bare_lf = out.count('\n') - out.count('\r\n')
    if bare_lf == 0 and '\r\n' in out:
        record('required', 'CRLF line discipline', 'PASS')
    else:
        record('required', 'CRLF line discipline', 'FAIL',
               f'{bare_lf} bare LFs')

    # ---------------- C. traps / faults ----------------
    print('\n== C. traps / faults ==', flush=True)
    check_repl('required', 'Fault; dumps + recovers', fd, 'Fault;',
               expect=('*** FAULT', '-- eval aborted, back to the REPL --'),
               forbid=(), timeout=60.0)
    check_repl('required', 'eval works after fault', fd, '1+1;',
               expect=('=2',))
    check_repl('required', 'bad access faults + recovers', fd,
               'DumpMem(0x87001000, 4, "bad");',
               expect=('*** FAULT',), forbid=(), timeout=45.0)
    check_repl('required', 'eval works after bad access', fd, '2+2;',
               expect=('=4',))

    # ---------------- D+E. SoC Info + bus error monitor, via DMI ------------
    # (Registers verified over the DMI system bus: the REPL's $HC_DUMP
    # framing is fs/9P-backed and stalls retrying when no 9P host answers,
    # which is too slow/flaky for a test driver.  MemMap's live probe in
    # section B already covers the REPL-side view.)
    print('\n== D. self-describing SoC (via DMI system bus) ==', flush=True)
    os.close(fd)
    dmi = DMI(PORT, BAUD)
    try:
        dmi.arm()
        # Transport health gate: under heavy console traffic the UART DMI
        # bridge can wedge its system-bus WRITE channel (reads keep
        # working, writes silently drop; pre-existing flakiness, see
        # HANDOFF).  Probe with a GPIO poke; if the write doesn't land,
        # reprogram + reload the REPL and re-arm, up to 2 attempts.
        for attempt in range(3):
            try:
                dmi.mem_write32(0xC0002000, 0x5A)
                time.sleep(0.15)
                g = dmi.mem_read32(0xC0002000) & 0xFF
                dmi.mem_write32(0xC0002000, 0)
                if g == 0x5A:
                    break
                print(f'    DMI write channel wedged (probe {g:#x}); '
                      f'recovery {attempt + 1}', flush=True)
            except Exception as e:
                print(f'    DMI probe exc {type(e).__name__}: {e}; '
                      f'recovery {attempt + 1}', flush=True)
            try:
                dmi.close()
            except Exception:
                pass
            subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', BITSTREAM],
                           capture_output=True)
            fd2 = open_port()
            load_blob(fd2, open(BLOB, 'rb').read())
            t0 = time.time()
            boot = b''
            while time.time() - t0 < 240:
                boot += drain(fd2, 2.0)
                if boot.endswith(b'> '):
                    break
            os.close(fd2)
            dmi = DMI(PORT, BAUD)
            dmi.arm()
        else:
            record('required', 'DMI transport healthy', 'FAIL',
                   'write channel wedged after 2 recoveries')
            raise RuntimeError('DMI transport wedged')

        def dmi_check(name, fn, ok):
            try:
                v = fn()
                record('required', name, 'PASS' if ok(v) else 'FAIL',
                       repr(v)[:60])
            except Exception as e:
                record('required', name, 'FAIL', f'{type(e).__name__}: {e}')

        dmi_check('SoCInfo magic', lambda: dmi.mem_read32(0xC0003000),
                  lambda v: v == 0x464C5331)
        dmi_check('SoCInfo version 1', lambda: dmi.mem_read32(0xC0003004),
                  lambda v: v == 1)
        dmi_check('SoCInfo build date set',
                  lambda: dmi.mem_read32(0xC0003008), lambda v: v != 0)
        dmi_check('SoCInfo features buserr',
                  lambda: dmi.mem_read32(0xC000300C), lambda v: bool(v & 0x10))
        dmi_check('SoCInfo features perf',
                  lambda: dmi.mem_read32(0xC000300C), lambda v: bool(v & 0x80))
        dmi_check('SoCInfo cpu_hz 25M',
                  lambda: dmi.mem_read32(0xC0003010),
                  lambda v: v == 25000000)
        dmi_check('SoCInfo memory 32MB',
                  lambda: dmi.mem_read32(0xC0003018),
                  lambda v: v == 0x2000000)
        dmi_check('SoCInfo device count 7',
                  lambda: dmi.mem_read32(0xC000301C), lambda v: v == 7)
        dmi_check('SoCInfo device table 0x100',
                  lambda: dmi.mem_read32(0xC0003020), lambda v: v == 0x100)

        def _devrom():
            return dmi.mem_read(0xC0003100, 7 * 8)
        rom = None
        try:
            rom = _devrom()
        except Exception as e:
            record('required', 'devROM records', 'FAIL',
                   f'{type(e).__name__}: {e}')
        if rom:
            names = {0: 'boot_rom', 1: 'sdram', 2: 'clint', 3: 'uart0',
                     4: 'gpio', 5: 'plic', 6: 'soc_info'}
            recs = [rom[i * 8:(i + 1) * 8] for i in range(7)]
            byname = {names.get(r[0], str(r[0])): r for r in recs}
            dmi_check('devROM uart0',
                      lambda: byname['uart0'][2] == 0xC0000000
                      and byname['uart0'][4] == 0,
                      lambda v: v)
            dmi_check('devROM clint near-mem bus',
                      lambda: byname['clint'][5], lambda v: v == 2)
            dmi_check('devROM plic reserved bus',
                      lambda: byname['plic'][5], lambda v: v == 4)
            dmi_check('devROM soc_info self',
                      lambda: byname['soc_info'][2] == 0xC0003000,
                      lambda v: v)

        print('\n== E. bus error monitor ==', flush=True)
        base_cnt = dmi.mem_read32(0xC000302C)
        dmi.mem_write32(0xC000303C, 1)          # BUSERR_CLEAR
        clr = dmi.mem_read32(0xC000302C)
        if clr == 0:
            record('required', 'buserr clear (DMI poke)', 'PASS')
        else:
            record('required', 'buserr clear (DMI poke)', 'FAIL',
                   f'count {clr} after clear')
        # provoke a decode error via a system-bus read of unmapped space
        try:
            dmi.mem_read32(0x87001000)
            record('required', 'unmapped DMI read faults', 'FAIL',
                   'no system bus error raised')
        except RuntimeError:
            record('required', 'unmapped DMI read faults', 'PASS')
        cnt = dmi.mem_read32(0xC000302C)
        addr = dmi.mem_read32(0xC0003030)
        st = dmi.mem_read32(0xC0003028)
        ok = (cnt == 1 and addr == 0x87001000 and (st & 1) and not (st & 2))
        record('required', 'buserr captured addr/count/rw', 'PASS' if ok
               else 'FAIL',
               f'count={cnt} addr={addr:#x} status=0x{st:x} (pre={base_cnt})')

        # ---------------- G. performance counters ----------------
        print('\n== G. performance counters ==', flush=True)
        PERF_SEL = [0xC0003040, 0xC0003044, 0xC0003048, 0xC000304C]
        PERF_CNT = [0xC0003080, 0xC0003084, 0xC0003088, 0xC000308C]

        def _cycles_rate():
            dmi.mem_write32(PERF_CNT[0], 0)    # clear (select defaults to 0=cycles)
            a = dmi.mem_read32(PERF_CNT[0])
            time.sleep(1.2)
            b = dmi.mem_read32(PERF_CNT[0])
            return b - a
        dmi_check('perf cycles rate ~25 MHz', _cycles_rate,
                  lambda d: 20_000_000 <= d <= 32_000_000)

        def _retire():
            dmi.mem_write32(PERF_SEL[1], 1)    # counter1 = retired instructions
            dmi.mem_write32(PERF_CNT[1], 0)
            a = dmi.mem_read32(PERF_CNT[1])
            time.sleep(0.5)
            return dmi.mem_read32(PERF_CNT[1]) - a
        dmi_check('perf retire counts (REPL idle loop)', _retire,
                  lambda d: d > 1000)

        def _frozen():
            # invalid select: counter frozen at the write-clear value (0);
            # a running counter would show millions of cycles after 0.3 s
            dmi.mem_write32(PERF_SEL[3], 15)   # invalid code: frozen
            dmi.mem_write32(PERF_CNT[3], 0)    # write-anything clears
            time.sleep(0.3)
            return dmi.mem_read32(PERF_CNT[3])
        dmi_check('perf invalid select freezes counter', _frozen,
                  lambda v: v == 0)

        def _clear():
            dmi.mem_write32(PERF_SEL[3], 0)    # cycles
            dmi.mem_write32(PERF_CNT[3], 0)    # write-anything clears
            a = dmi.mem_read32(PERF_CNT[3])
            time.sleep(0.25)
            b = dmi.mem_read32(PERF_CNT[3])
            return b - a
        dmi_check('perf count write-clear + cycles counting', _clear,
                  lambda d: 3_000_000 <= d <= 10_000_000)
        # restore defaults so later sections see a clean block
        dmi.mem_write32(PERF_SEL[1], 0)
        dmi.mem_write32(PERF_SEL[3], 0)

        # ---------------- F. DMI / debug module ----------------
        print('\n== F. RISC-V debug module ==', flush=True)
        # Flute's abstract command supports GPRs + dpc only (misa/mstatus
        # reads return 'not supported'); REPL Reg("misa") covers those.
        def _dpc():
            dmi.halt()
            v = dmi.read_csr(0x7B1)
            dmi.resume()
            return v
        dmi_check('DMI read dpc (abstract CSR, halted)',
                  _dpc, lambda v: 0x80000000 <= v < 0x82000000)
        dmi_check('DMI system-bus read SoCInfo',
                  lambda: dmi.mem_read32(0xC0003000),
                  lambda v: v == 0x464C5331)
        def _sdram():
            dmi.mem_write32(0x80010000, 0xCAFEBABE)
            return dmi.mem_read32(0x80010000)
        dmi_check('DMI SDRAM poke/readback', _sdram,
                  lambda v: v == 0xCAFEBABE)
        def _gpio():
            dmi.mem_write32(0xC0002000, 0x5A)
            v = dmi.mem_read32(0xC0002000) & 0xFF
            dmi.mem_write32(0xC0002000, 0)
            return v
        dmi_check('GPIO LED write/read (DMI)', _gpio, lambda v: v == 0x5A)
        def _halt():
            dmi.halt()
            h = dmi.halted()
            pc = dmi.read_csr(0x7B1)
            dmi.resume()
            return h, pc
        dmi_check('halt/resume + dpc', _halt,
                  lambda v: v[0] and 0x80000000 <= v[1] < 0x82000000)
        dmi.disarm()
    finally:
        dmi.close()

    # ---------------- summary ----------------
    n_pass = sum(1 for r in results if r[2] == 'PASS')
    n_fail = sum(1 for r in results if r[2] == 'FAIL')
    n_warn = sum(1 for r in results if r[2] == 'WARN')
    n_skip = sum(1 for r in results if r[2] == 'SKIP')
    print(f'\n== summary: {n_pass} PASS, {n_fail} FAIL, {n_warn} WARN, '
          f'{n_skip} SKIP ==')
    return 1 if n_fail else 0


if __name__ == '__main__':
    sys.exit(main())
