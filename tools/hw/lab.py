#!/usr/bin/env python3
"""hw lab: act on the ULX3S (hwsh CONTRACT.md).  Every acting verb takes the board lock first.

  hw lab restart                         JTAG refresh: the FPGA reloads from flash (~0.2 s)
  hw lab load BITSTREAM                  load a bitstream into SRAM (openFPGALoader -m); never flash
  hw lab serial [--until RE] [--timeout S] [--send TEXT]   capture the console; bounded result
  hw lab raw REF [--from N] [--lines N]  a bounded slice of a stored capture (serial:<id>)
  hw lab lock                            who holds the board, and whether the port is open
  hw lab flash ... / power-cycle         refused, with what to do instead

Machine facts come from the environment or tools/hw/local.toml (untracked): HW_SERIAL (the
console device), HW_BAUD (default 1000000), HW_HOLDER (your session name for the shared board lock,
~/.claude/skills/ulx3s-board; every acting verb acquires it and releases it with a note).  Captures are stored under build/hw/ (untracked).
"""
import argparse
import fcntl
import hashlib
import os
import re
import struct
import subprocess
import sys
import termios
import time
import tomllib

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.environ.get('HWSH_LIB', os.path.expanduser('~/src/hwsh/lib')))
from hwout import HwError, Result, bounded  # noqa: E402
sys.path.insert(0, HERE)
import common  # noqa: E402

FACTS = os.path.join(HERE, 'data', 'ulx3s.toml')
CAP_DIR = os.path.join(ROOT, 'build', 'hw')


def local():
    p = os.path.join(HERE, 'local.toml')
    if os.path.exists(p):
        with open(p, 'rb') as fh: return tomllib.load(fh)
    return {}


def setting(name, default=None):
    return os.environ.get(name) or local().get(name.lower()) or default


def facts():
    with open(FACTS, 'rb') as fh: return tomllib.load(fh)


def serial_dev():
    d = setting('HW_SERIAL')
    if not d:
        raise HwError('HW-E-NO-FACTS', 'no console device configured',
                      'set HW_SERIAL=/dev/cu.usbserial-... or serial = "..." in tools/hw/local.toml (untracked)')
    if not os.path.exists(d):
        raise HwError('HW-E-NO-BOARD', 'console device %s does not exist (board unplugged?)' % d,
                      'check the USB cable; ls /dev/cu.usbserial-*')
    return d


# ---- the lock: the machine's shared ULX3S lease lock (~/.claude/skills/ulx3s-board), so hw lab
# and every other session agree on one holder
LOCK_TOOL = os.path.expanduser(os.environ.get('ULX3S_LOCK_TOOL', '~/.claude/skills/ulx3s-board/ulx3s_lock.py'))


def lock_cmd(*args):
    if not os.path.exists(LOCK_TOOL):
        raise HwError('HW-E-NO-LOCK', 'the shared board lock tool is missing (%s)' % LOCK_TOOL,
                      'install the ulx3s-board skill; hw lab will not touch the board without it')
    return subprocess.run(['python3', '-I', LOCK_TOOL] + list(args), capture_output=True, text=True, timeout=60)


class Lock:
    """Acquire for one verb, release with a note of what the verb left on the board."""
    def __init__(self, verb, minutes=10):
        self.verb, self.minutes, self.left = verb, minutes, None

    def __enter__(self):
        who = setting('HW_HOLDER')
        if not who:
            raise HwError('HW-E-NO-FACTS', 'no lock holder name', 'set HW_HOLDER to your session name exactly as ListAgents shows it')
        r = lock_cmd('acquire', '--who', who, '--purpose', 'hw lab ' + self.verb, '--for', '%dm' % self.minutes)
        if r.returncode:
            st = lock_cmd('status').stdout.strip().splitlines()
            raise HwError('HW-E-BUSY', 'the board is held: %s' % ' / '.join(l.strip() for l in st[:3]),
                          'ulx3s_lock.py request --who %s --reason ... (the polite hand-back); never take it by force' % who)
        self.token = r.stdout.strip().splitlines()[-1]
        return self

    def __exit__(self, *exc):
        note = self.left or ('hw lab %s %s; state unknown' % (self.verb, 'failed' if exc[0] else 'done'))
        lock_cmd('release', '--token', self.token, '--left', note)


def port_users(dev):
    """Processes holding the console device open (picocom, screen, a test): -> [(pid, name)]."""
    r = subprocess.run(['lsof', '-Fpc', dev], capture_output=True, text=True)
    out, pid = [], None
    for line in r.stdout.splitlines():
        if line.startswith('p'): pid = int(line[1:])
        elif line.startswith('c') and pid: out.append((pid, line[1:]))
    return out


def require_port_free(dev):
    users = [u for u in port_users(dev) if u[0] != os.getpid()]
    if users:
        raise HwError('HW-E-BUSY', 'the console %s is open by %s' % (dev, ', '.join('%s (pid %d)' % (n, p) for p, n in users)),
                      'close that terminal (hw lab never kills it); openFPGALoader shares the FTDI with the console')


def loader(args, timeout=120):
    r = subprocess.run(['openFPGALoader', '-b', 'ulx3s'] + args, capture_output=True, text=True, timeout=timeout)
    tail = [l for l in (r.stdout + r.stderr).splitlines() if l.strip()][-4:]
    if r.returncode:
        raise HwError('HW-E-LOADER', 'openFPGALoader %s failed (exit %d): %s' % (' '.join(args), r.returncode, ' | '.join(tail)),
                      'is the board connected and the port free? hw lab lock')
    return tail


def cmd_restart(a):
    dev = serial_dev()
    slot = facts()['flash']['slot0']
    with Lock('restart') as lk:
        require_port_free(dev)
        t0 = time.time()
        loader(['-r'], timeout=30)
        dt = time.time() - t0
        lk.left = 'restarted (JTAG refresh): flash slot 0 running (%s); safe to reprogram' % slot
    return Result('lab restart', lines=['restarted by JTAG refresh in %.1f s; the FPGA reloaded flash slot 0 (%s)' % (dt, slot)],
                  seconds=round(dt, 2), method='jtag-refresh', loaded=slot)


def md5(p):
    h = hashlib.md5()
    with open(p, 'rb') as fh:
        for b in iter(lambda: fh.read(1 << 20), b''): h.update(b)
    return h.hexdigest()


def cmd_load(a):
    bit = os.path.abspath(a.bitstream)
    if not os.path.exists(bit):
        raise HwError('HW-E-NOT-FOUND', 'no bitstream %s' % a.bitstream, 'build it, or ls bits/ build/*.bit')
    if not bit.endswith('.bit'):
        raise HwError('HW-E-BADREQ', '%s is not a .bit file' % a.bitstream, 'pass the ecppack output (.bit)')
    dev = serial_dev()
    with Lock('load ' + os.path.basename(bit)) as lk:
        require_port_free(dev)
        t0 = time.time()
        loader(['-m', bit])
        dt = time.time() - t0
        lk.left = '%s in SRAM (md5 %s); safe to reprogram' % (os.path.basename(bit), md5(bit))
    return Result('lab load', lines=['loaded %s into SRAM in %.1f s (md5 %s); flash untouched; hw lab restart returns to flash'
                                     % (os.path.relpath(bit, ROOT), dt, md5(bit))],
                  bitstream=os.path.relpath(bit, ROOT), md5=md5(bit), seconds=round(dt, 1), target='sram',
                  _inputs=[bit], _tool='openFPGALoader', _checks=[{'name': 'sram load', 'status': 'pass',
                  'expected': 'loader exit 0', 'observed': 'exit 0 in %.1f s' % dt}])


def open_port(dev, baud):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    at = termios.tcgetattr(fd)
    at[0] = at[1] = at[3] = 0
    at[2] = termios.CREAD | termios.CLOCAL | termios.CS8
    termios.tcsetattr(fd, termios.TCSANOW, at)
    fcntl.ioctl(fd, 0x80045402, struct.pack('I', baud))          # IOSSIOSPEED (macOS): any baud
    return fd


def cmd_serial(a):
    dev, baud = serial_dev(), int(setting('HW_BAUD', '1000000'))
    rx = re.compile(a.until.encode()) if a.until else None
    with Lock('serial', minutes=max(2, int(a.timeout // 60) + 2)) as lk:
        lk.left = 'only read the console (%s); board state unchanged' % ('sent %r' % a.send if a.send else 'nothing sent')
        require_port_free(dev)
        fd = open_port(dev, baud)
        try:
            if a.send: os.write(fd, a.send.encode().decode('unicode_escape').encode('latin-1'))
            buf, t0, hit = b'', time.time(), None
            while time.time() - t0 < a.timeout:
                try:
                    d = os.read(fd, 65536)
                    if d:
                        buf += d
                        if rx and hit is None:
                            m = rx.search(buf)
                            if m: hit = m; break
                        continue
                except (BlockingIOError, OSError):
                    pass
                time.sleep(0.01)
        finally:
            os.close(fd)
    os.makedirs(CAP_DIR, exist_ok=True)
    ref = 'serial:%s' % time.strftime('%Y%m%d-%H%M%S')
    with open(os.path.join(CAP_DIR, ref.split(':')[1] + '.log'), 'wb') as fh: fh.write(buf)
    text = buf.decode('latin-1')
    lines = text.splitlines()
    if hit:
        upto = buf[:hit.end()].decode('latin-1').count('\n')
        ctx = lines[max(0, upto - a.context):upto + 1]
        status = 'matched'
    else:
        ctx = lines[-a.context:]
        status = 'timeout' if rx else 'done'
    out = ['%s: %d bytes, %d lines in %.1f s%s (raw: hw lab raw %s)' % (status, len(buf), len(lines), time.time() - t0,
           (' -- /%s/ matched' % a.until) if hit else ((' -- /%s/ not seen' % a.until) if rx else ''), ref)]
    out += ['  | ' + l[:200] for l in ctx]
    res = Result('lab serial', lines=out, match=status == 'matched', bytes=len(buf), raw_ref=ref, context=ctx)
    if rx and not hit:
        res.update(status='error', code='HW-E-TIMEOUT', reason='/%s/ not seen in %g s (%d bytes)' % (a.until, a.timeout, len(buf)),
                   hint='hw lab raw %s for the capture; restart or load first?' % ref)
    return res


def cmd_raw(a):
    m = re.fullmatch(r'serial:([\d-]+)', a.ref)
    p = m and os.path.join(CAP_DIR, m.group(1) + '.log')
    if not p or not os.path.exists(p):
        raise HwError('HW-E-NOT-FOUND', 'no capture %s' % a.ref, 'refs look like serial:YYYYMMDD-HHMMSS (from hw lab serial)')
    with open(p, 'rb') as fh: lines = fh.read().decode('latin-1').splitlines()
    shown = lines[a.start:a.start + a.lines]
    more = a.start + len(shown) < len(lines)
    return Result('lab raw', lines=['  | ' + l[:200] for l in shown] + ([] if not more else []), ref=a.ref,
                  total=len(lines), first=a.start, truncated=more, next=('%s --from %d' % (a.ref, a.start + len(shown))) if more else None)


def cmd_lock(a):
    r = lock_cmd('status')
    st = [l.rstrip() for l in r.stdout.splitlines() if l.strip()]
    holder = None if r.returncode == 0 else (st[0] if st else 'held')
    lines = ['board lock: ' + (st[0] if st else '?')] + ['  ' + l.strip() for l in st[1:6]]
    users = []
    dev = setting('HW_SERIAL')
    if dev and os.path.exists(dev):
        users = port_users(dev)
        lines.append('console: %s' % (', '.join('%s (pid %d)' % (n, pid) for pid, n in users) if users else 'not open'))
    return Result('lab lock', lines=lines, holder=holder or None, port_users=[{'pid': p_, 'name': n} for p_, n in users])


def refuse(code, reason, hint):
    def fn(_): raise HwError(code, reason, hint)
    return fn


def main(argv):
    ap = common.Parser(prog='hw lab')
    ap.add_argument('--json', action='store_true')
    sub = ap.add_subparsers(dest='verb', parser_class=common.Parser)
    def p(v):
        q = sub.add_parser(v); q.add_argument('--json', action='store_true'); return q
    p('restart'); p('lock')
    p('load').add_argument('bitstream')
    s = p('serial')
    s.add_argument('--until'); s.add_argument('--timeout', type=float, default=10.0)
    s.add_argument('--send'); s.add_argument('--context', type=int, default=5)
    r = p('raw'); r.add_argument('ref'); r.add_argument('--from', dest='start', type=int, default=0)
    r.add_argument('--lines', type=int, default=40)
    for v in ('flash', 'power-cycle', 'test'):
        q = p(v); q.add_argument('rest', nargs='*')
    def dispatch(a):
        fn = {'restart': cmd_restart, 'load': cmd_load, 'serial': cmd_serial, 'raw': cmd_raw, 'lock': cmd_lock,
              'flash': refuse('HW-E-FLASH-DENIED', 'hw lab never writes the board\'s flash: flashing and promotion are the user\'s decision',
                              'ask the user; to try a bitstream without flashing it: hw lab load BITSTREAM (SRAM)'),
              'power-cycle': refuse('HW-E-UNSUPPORTED', 'the USB hub port does not cut the board\'s power, so it cannot be power-cycled from here',
                                    'hw lab restart (JTAG refresh: reloads flash); a real power cycle needs the user to unplug it'),
              'test': refuse('HW-E-UNSUPPORTED', 'hw lab test is not implemented yet',
                             'python3 scripts/hw_test_suite.py (the full gate) until it is'),
              }.get(a.verb) or refuse('HW-E-BADREQ', 'hw lab needs a verb: restart, load, serial, raw, lock', 'hw lab lock')
        return fn(a)
    return common.run(dispatch, argv, ap.parse_args, area='lab')


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
