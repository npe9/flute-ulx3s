#!/usr/bin/env python3
"""trng_restart: the SP 800-90B 3.1.4 restart test for the Zkr ring-oscillator source, unattended.

A restart is a full FPGA reconfiguration: every flop and ring starts from configuration, but the
board's supply stays up.  (No real power cut here: on 2026-11-16 the hub port the board's US1 is on,
hub 33-3.2 port 2, an RTS5411, turned off its USB data only -- the SoC's uptime kept counting --
so --hub only matters with a hub that switches VBUS; uhubctl's compatibility list names some.)
  --restart refresh  (default) JTAG REFRESH: reload from flash offset 0, which holds the SoC
                     (2026-11-16; backup of the old flash in build/flash_backup); ~3.3 s each.
  --restart sram     openFPGALoader -m <bit>, ~40 s each.
Then loader.py --no-banner test/trng_restart.bin (63 words) and trng_capture: the first 1000
samples -> <out>/NNNN.bits.  The first word is the source's first after its startup window (it
waits unread); the rest follow within a few ms of the program starting, ~3 s after the restart.
Resumable: existing NNNN.bits files are kept.  At the end: <out>/rows.bits (row dataset, 1000 x
1000) for `ea_restart rows.bits 1 <H_I>`.
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trng_capture import capture, bits_of  # noqa: E402

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def log(f, msg):
    line = f'{time.strftime("%H:%M:%S")} {msg}'
    print(line, flush=True)
    f.write(line + '\n')
    f.flush()


def tty_ready(port, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(port):
            try:
                os.close(os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK))
                return True
            except OSError:
                pass
        time.sleep(0.2)
    return False


def fpga(args):
    """openFPGALoader with retries (libusb can miss the FT231X just after the tty reappears)."""
    for k in range(20):
        p = subprocess.run(['openFPGALoader', '-b', 'ulx3s'] + args, capture_output=True, text=True)
        if p.returncode == 0 and 'unable to open' not in p.stdout + p.stderr:
            return k
        time.sleep(0.5)
    raise RuntimeError(f'openFPGALoader: {p.stdout[-200:]}{p.stderr[-200:]}')


def one(a, lf):
    if a.hub:
        hub = ['uhubctl', '-l', a.hub, '-p', str(a.hub_port)]
        subprocess.run(hub + ['-a', 'off'], check=True, capture_output=True)
        time.sleep(a.off)
        subprocess.run(hub + ['-a', 'on'], check=True, capture_output=True)
        if not tty_ready(a.port, 20):
            raise RuntimeError('tty did not come back')
    t = [time.time()]
    k = fpga(['-r'] if a.restart == 'refresh' else ['-m', a.bit])
    t.append(time.time())
    p = subprocess.run([sys.executable, os.path.join(R, 'scripts', 'loader.py'), '--no-banner', '-t', '1',
                        '-p', a.port, a.prog], capture_output=True, text=True, timeout=60)
    if p.returncode:
        raise RuntimeError(f'loader: {p.stdout[-200:]}{p.stderr[-200:]}')
    t.append(time.time())
    hdr, words = capture(a.port, 1000000)
    t.append(time.time())
    one.times = [round(y - x, 1) for x, y in zip(t, t[1:])] + [k]
    bits = bits_of(words)[:1000]
    if len(bits) != 1000:
        raise RuntimeError(f'only {len(bits)} samples')
    return hdr, bits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--count', type=int, default=1000)
    ap.add_argument('--out', default=os.path.join(R, 'build', 'trng', 'restart'))
    ap.add_argument('--bit', default=os.path.join(R, 'build', 'ulx3s_top.bit'))
    ap.add_argument('--prog', default=os.path.join(R, 'test', 'trng_restart.bin'))
    ap.add_argument('--restart', choices=('refresh', 'sram'), default='refresh')
    ap.add_argument('--hub', default=None, help='uhubctl hub location to power-cycle first (only with a hub that switches VBUS)')
    ap.add_argument('--hub-port', type=int, default=2)
    ap.add_argument('--off', type=float, default=3.0, help='seconds without power (--hub)')
    ap.add_argument('-p', '--port', default='/dev/cu.usbserial-120001')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    lf = open(os.path.join(a.out, 'log.txt'), 'a')
    log(lf, f'start: count {a.count}, restart {a.restart}, hub {a.hub}')
    fails = 0
    for i in range(a.count):
        path = os.path.join(a.out, f'{i:04d}.bits')
        if os.path.exists(path):
            continue
        for attempt in range(3):
            try:
                hdr, bits = one(a, lf)
                break
            except (RuntimeError, SystemExit, OSError, subprocess.SubprocessError) as e:
                fails += 1
                log(lf, f'{i:04d} attempt {attempt}: {e}')
        else:
            log(lf, f'{i:04d}: giving up after 3 attempts')
            return 1
        open(path, 'wb').write(bits)
        n, polls, bist, dead, cyc = hdr
        log(lf, f'{i:04d} ones {sum(bits)} polls {polls} failures {bist} dead {dead} '
                f'(fpga / load / capture s, fpga retries: {one.times})')
    rows = b''.join(open(os.path.join(a.out, f'{i:04d}.bits'), 'rb').read() for i in range(a.count))
    open(os.path.join(a.out, 'rows.bits'), 'wb').write(rows)
    log(lf, f'done: {len(rows)} samples in rows.bits, {fails} retried attempts')
    return 0


if __name__ == '__main__':
    sys.exit(main())
