#!/usr/bin/env python3
"""esptool to the ULX3S's ESP32 through the FPGA (test/esp32_bridge.bin, lx45c and later).

Programs the bitstream, loads esp32_bridge.bin (ESP32 started in its ROM's download mode, uart0
<-> uart1 bridged), then relays a pty <-> the board's serial port at 1000000 baud.  esptool talks
to the pty: its baud setting there does nothing, and the ESP32 side is fixed at 115200.  It cannot
reset the ESP32 itself (no DTR/RTS path): use --before no_reset --after no_reset, and no baud change.

  python3 scripts/esp32_bridge.py --bit build/lx45d/ulx3s_top.bit -- chip_id
  python3 scripts/esp32_bridge.py --bit ... --serve          # pty at build/esp32-tty until ^C

With esptool arguments it runs build/venv-esptool/bin/esptool.py (or $ESPTOOL) on the pty and exits
with its status.  The bridge keeps running on the board until the next bitstream load.

  python3 scripts/esp32_bridge.py --bit ... --read-flash 0 0x400000 esp32.bin

--read-flash reads in digest-checked pieces (from 16 KB, halved on each failure down to 512 B),
then compares the whole file with the stub's flash MD5.  It was needed at the old 625000 console
rate: on macOS the FT231X ran at 600015 for it (3 MHz / 5) and misread some FPGA -> host zero
bytes.  The console is 1000000 baud since lx46 (3 MHz / 3, 50 MHz / 50: exact on both sides).
"""
import argparse
import os
import pty
import select
import subprocess
import sys
import time
import tty

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hw_test_suite as hw  # noqa: E402

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def write_all(fd, d):
    """the board port is non-blocking: retry until every byte is taken"""
    while d:
        try:
            n = os.write(fd, d)
            d = d[n:]
        except BlockingIOError:
            select.select([], [fd], [], 0.05)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bit', default=hw.BITSTREAM)
    ap.add_argument('--bin', default=os.path.join(R, 'test/esp32_bridge.bin'))
    ap.add_argument('--link', default=os.path.join(R, 'build/esp32-tty'))
    ap.add_argument('--serve', action='store_true', help='keep the pty up until interrupted')
    ap.add_argument('--log', help='append every byte from the board to this file')
    ap.add_argument('--read-flash', nargs=3, metavar=('OFFSET', 'LENGTH', 'FILE'),
                    help='chunked, digest-checked flash read (see above)')
    ap.add_argument('esptool_args', nargs='*')
    a = ap.parse_args()
    r = subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', a.bit], capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-300:] + r.stderr[-300:]); return 1
    fd = hw.open_port()
    try:
        hw.load_blob(fd, open(a.bin, 'rb').read())
    except RuntimeError:                  # seen once right after programming: reload and retry
        subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', a.bit], capture_output=True)
        hw.load_blob(fd, open(a.bin, 'rb').read())
    got = b''
    t0 = time.time()
    while time.time() - t0 < 5 and b'esp32_bridge: ready' not in got:
        got += hw.drain(fd, 0.5)
    if b'esp32_bridge: ready' not in got:
        print('bridge did not start:', got[-200:]); return 1
    m, s = pty.openpty()
    tty.setraw(m)
    name = os.ttyname(s)
    try:
        os.unlink(a.link)
    except FileNotFoundError:
        pass
    os.symlink(name, a.link)
    print(f'esp32 bridge up: {a.link} -> {name}', flush=True)
    child = None
    logf = open(a.log, 'ab') if a.log else None
    if a.read_flash:
        py = os.path.join(R, 'build/venv-esptool/bin/python3')
        child = subprocess.Popen([py, os.path.abspath(__file__), '--_reader', name] + a.read_flash)
    if a.esptool_args and not a.serve:
        tool = os.environ.get('ESPTOOL', os.path.join(R, 'build/venv-esptool/bin/esptool.py'))
        child = subprocess.Popen([tool, '--port', name, '--baud', '115200', '--before', 'no_reset',
                                  '--after', 'no_reset'] + a.esptool_args)
    try:
        while child is None or child.poll() is None:
            rd, _, _ = select.select([m, fd], [], [], 0.2)
            if m in rd:
                try:
                    d = os.read(m, 4096)
                except OSError:
                    d = b''
                if d:
                    write_all(fd, d)
            if fd in rd:
                try:
                    d = os.read(fd, 4096)
                except (BlockingIOError, OSError):
                    d = b''
                if d:
                    if logf:
                        logf.write(d); logf.flush()
                    write_all(m, d)
    except KeyboardInterrupt:
        pass
    finally:
        os.unlink(a.link)
    return child.returncode if child else 0


def reader(port, off, length, out):
    """runs in the esptool venv (spawned by --read-flash)"""
    import hashlib
    from esptool.cmds import detect_chip
    off, length = int(off, 0), int(length, 0)
    esp = detect_chip(port, 115200, 'no_reset').run_stub()
    data = bytearray(); retries = 0; t0 = time.time(); a = off
    size = 0x4000
    while a < off + length:
        n = min(size, off + length - a)
        for _ in range(16):
            try:
                d = esp.read_flash(a, n)
                break
            except Exception:
                retries += 1
                esp.flush_input(); time.sleep(0.1)
                if n > 0x200:                # zero-heavy data fails more: shorter reads
                    n //= 2
        else:
            print(f'read-flash: gave up at {a:#x}'); return 1
        data += d; a += n
        size = min(0x4000, n * 2)
        print(f'\rread-flash: {a - off:#x} / {length:#x}, {retries} retried', end='', flush=True)
    print()
    want = esp.flash_md5sum(off, length)
    got = hashlib.md5(data).hexdigest()
    open(out, 'wb').write(data)
    print(f'read-flash: {len(data)} bytes in {time.time() - t0:.0f} s, md5 {got} '
          f'({"matches" if got == want else "DIFFERS from"} the ESP32\'s {want})')
    return 0 if got == want else 1


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--_reader':
        sys.exit(reader(*sys.argv[2:6]))
    sys.exit(main())
