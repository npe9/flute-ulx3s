#!/usr/bin/env python3
"""hw lab: act on the ULX3S (hwsh CONTRACT.md).  Every acting verb takes the board lock first.

  hw lab restart                         JTAG refresh: the FPGA reloads from flash (~0.2 s)
  hw lab load BITSTREAM                  load a bitstream into SRAM (openFPGALoader -m); never flash
  hw lab serial [--until RE] [--timeout S] [--send TEXT] [--restart]
                                         capture the console; bounded result.  --restart: JTAG refresh
                                         and open the console right after it, under one lock
  hw lab test SUITE BITSTREAM [--pnr LOG] [--force] [--env K=V]
                                         run a hardware test (suite | cache | amo | blob FILE) on a
                                         bitstream loaded to SRAM; one check record per test
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


def open_port_after_refresh(dev, baud, budget=2.0):
    """The FTDI's JTAG cannot be claimed while the console is open, so the console can only be opened
    after openFPGALoader exits; retry until the driver gives the tty back.  -> (fd, seconds waited)."""
    t0 = time.time()
    while True:
        try:
            return open_port(dev, baud), time.time() - t0
        except OSError:
            if time.time() - t0 > budget:
                raise HwError('HW-E-NO-BOARD', 'console %s did not reopen within %.1f s of the refresh' % (dev, budget),
                              'hw lab lock; the board may still be enumerating')
            time.sleep(0.002)


def cmd_serial(a):
    dev, baud = serial_dev(), int(setting('HW_BAUD', '1000000'))
    rx = re.compile(a.until.encode()) if a.until else None
    gap = None
    with Lock('serial' + (' --restart' if a.restart else ''), minutes=max(2, int(a.timeout // 60) + 2)) as lk:
        sent = 'sent %r' % a.send if a.send else 'nothing sent'
        lk.left = 'only read the console (%s); board state unchanged' % sent
        require_port_free(dev)
        if a.restart:
            slot = facts()['flash']['slot0']
            lk.left = 'restarted (JTAG refresh): flash slot 0 running (%s); read the console (%s); safe to reprogram' % (slot, sent)
            t_ref = time.time()
            loader(['-r'], timeout=30)
            fd, gap = open_port_after_refresh(dev, baud)
            gap = time.time() - t_ref if gap is not None else None
        else:
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
    if gap is not None:
        out.append('  restarted; console open %.0f ms after the refresh began (output before that is lost: the FTDI '
                   'cannot hold JTAG and the tty at once)' % (gap * 1000))
    out += ['  | ' + l[:200] for l in ctx]
    res = Result('lab serial', lines=out, match=status == 'matched', bytes=len(buf), raw_ref=ref, context=ctx,
                 restart_gap_ms=round(gap * 1000) if gap is not None else None)
    if rx and not hit:
        res.update(status='error', code='HW-E-TIMEOUT', reason='/%s/ not seen in %g s (%d bytes)' % (a.until, a.timeout, len(buf)),
                   hint='hw lab raw %s for the capture; restart or load first?' % ref)
    return res

# ---- hw lab test: the hardware gates as check records
MIN_MARGIN = 10.0          # percent, post-route, every clock (AGENTS.md rule 7: double-digit margin before a bench)
SUITES = {
    'suite': 'scripts/hw_test_suite.py: TempleOS REPL interface suite (eval, observability, traps, SoC info, buserr, DMI)',
    'cache': 'test/cache_test.bin via scripts/loader.py --no-banner right after the SRAM load (T, M<mismatch>..., D)',
    'amo':   'test/amo_test.bin, same way and protocol',
    'blob':  'any T/M/D-protocol blob FILE, same way',
}
BOOT = r"""
import os, runpy, sys
root, dev, baud, bit, which = sys.argv[1:6]
sys.path.insert(0, os.path.join(root, 'scripts'))
os.chdir(root)
import hw_test_suite as H
H.PORT, H.BAUD, H.BITSTREAM = dev, int(baud), bit
if which == 'suite':
    sys.argv = ['hw_test_suite.py'] + sys.argv[6:]
    sys.exit(H.main())
# T/M/D blobs: SRAM load, then the loader at once (the flash boot directory autoboots after ~3 s
# unless a UART byte arrives, so test/run_cache_test.py's 3 s drain is too slow on lx49c+ bitstreams)
import subprocess
r = subprocess.run(['openFPGALoader', '-b', 'ulx3s', '-m', bit], capture_output=True, text=True)
print('program rc=', r.returncode, flush=True)
if r.returncode:
    print(r.stdout + r.stderr); sys.exit(3)
r = subprocess.run([sys.executable, os.path.join(root, 'scripts', 'loader.py'), '--no-banner', '-p', dev, '-b', baud,
                    '-t', '20', sys.argv[6]], capture_output=True, text=True, timeout=180)
print('loader rc=', r.returncode)
print(r.stderr)
print('--- program output ---')
print(r.stdout)
"""


def find_pnr(bit, explicit):
    if explicit:
        return explicit
    d, b = os.path.dirname(bit), os.path.basename(bit)
    m = re.search(r'(?:^|[-_.])s(\d+)\.bit$', b)
    cands = [os.path.join(d, 'pnr-s%s.log' % m.group(1))] if m else []
    if not m:
        cands = sorted(f for f in (os.path.join(d, x) for x in os.listdir(d)) if re.search(r'pnr-s\d+\.log$', f))
        cands = cands if len(cands) == 1 else []       # several seeds and no seed in the name: ambiguous
    return next((c for c in cands if os.path.exists(c)), None)


def margin_of(log):
    import pnr
    rec, _ = pnr.load(log)
    stage, st, complete = pnr.final_stage(rec)
    if not complete:
        raise HwError('HW-E-MARGIN', '%s never routed: no post-route Fmax to trust' % os.path.relpath(log, ROOT),
                      'route the build first, or --force')
    cl = [(round(100.0 * (f['mhz'] - f['target_mhz']) / f['target_mhz'], 1), f) for f in st['fmax']]
    return min(cl, key=lambda x: x[0]) if cl else (None, None)


def parse_suite(text, ref):
    checks, lines = [], text.split('\n')
    for i, l in enumerate(lines, 1):
        m = re.match(r'^(PASS|FAIL|WARN|SKIP)  (.+?)(?:  -- (.*))?$', l)
        if m:
            obs = m.group(1) + (': ' + m.group(3) if m.group(3) else '')
            if i < len(lines) and lines[i].startswith('    captured:'):
                obs += ' | ' + lines[i].strip()[:200]
            checks.append({'name': m.group(2).strip(), 'status': m.group(1).lower(), 'expected': 'PASS',
                           'observed': obs[:400], 'raw_ref': '%s --from %d --lines 3' % (ref, i - 1)})
    summ = re.search(r'== summary: (\d+) PASS, (\d+) FAIL, (\d+) WARN, (\d+) SKIP ==', text)
    if not summ:
        why = next((l for l in lines if 'never reached' in l or 'Traceback' in l or 'Error' in l), 'no summary line')
        checks.append({'name': 'suite completed', 'status': 'fail', 'expected': '== summary: ... ==',
                       'observed': why.strip()[:300], 'raw_ref': ref})
    return checks


def parse_tmd(text, ref, name):
    m = re.search(r'program rc= (-?\d+)', text)
    if m and m.group(1) != '0':
        raise HwError('HW-E-LOADER', 'openFPGALoader failed (rc %s) before the test ran' % m.group(1),
                      'hw lab raw %s; hw lab lock' % ref)
    if 'Traceback' in text or not re.search(r'loader rc= 0', text):
        why = [l for l in text.split('\n') if l.strip()][-1:] or ['no output']
        raise HwError('HW-E-LAB-HARNESS', 'the loader did not deliver the test image: %s' % why[0][:200],
                      'hw lab raw %s (a harness failure, not a test verdict)' % ref)
    out = text.split('--- program output ---', 1)[1] if '--- program output ---' in text else ''
    # drop the loader's repair-window word dump ([xxxxxxxx ... : ...]) and its own messages
    prog = '\n'.join(l for l in out.replace('\r', '').split('\n')
                     if not l.startswith('loader:') and not re.match(r'^\[[0-9a-f ]+:[0-9a-f ]+\]$', l.strip()))
    mism = re.findall(r'M ?[0-9a-fA-F]+ [0-9a-fA-F]+ [0-9a-fA-F]+', prog)
    ok = prog.strip().startswith('T') and 'D' in prog and not mism
    obs = 'T seen' if 'T' in prog else 'no T'
    obs += ', D seen' if 'D' in prog else ', no D'
    if mism:
        obs += ', %d mismatch line(s): %s' % (len(mism), ' '.join(mism[:3]))
    return [{'name': name, 'status': 'pass' if ok else 'fail', 'expected': 'T, no M lines, D',
             'observed': obs + ' | program output: %r' % prog.strip()[:120], 'raw_ref': ref}]


def sha256f(p):
    h = hashlib.sha256()
    with open(p, 'rb') as fh:
        for b in iter(lambda: fh.read(1 << 20), b''): h.update(b)
    return h.hexdigest()


def cmd_test(a):
    if a.suite not in SUITES:
        raise HwError('HW-E-BADREQ', 'no suite `%s`' % a.suite, 'suites: ' + '; '.join('%s = %s' % kv for kv in SUITES.items()))
    bit = os.path.abspath(a.bitstream)
    if not os.path.exists(bit) or not bit.endswith('.bit'):
        raise HwError('HW-E-NOT-FOUND', 'no bitstream %s (.bit)' % a.bitstream, 'ls bits/ build/*/*.bit')
    blob = None
    if a.suite == 'blob':
        if not a.blob:
            raise HwError('HW-E-BADREQ', 'blob needs FILE', 'hw lab test blob BIT --blob test/x.bin')
        blob = os.path.abspath(a.blob)
    elif a.suite in ('cache', 'amo'):
        blob = os.path.join(ROOT, 'test', '%s_test.bin' % a.suite)
    ro = facts()['readonly']
    if blob and os.path.basename(blob) in ro['images']:
        raise HwError('HW-E-DENIED', '%s writes a read-only device (%s)' % (os.path.basename(blob), ', '.join(ro['devices'])),
                      'never run it on the board; the read-only variant is the *_test.bin without _w')
    if blob and not os.path.exists(blob):
        raise HwError('HW-E-NOT-FOUND', 'no test image %s' % os.path.relpath(blob, ROOT), 'build it first')
    log = find_pnr(bit, a.pnr)
    if log is None:
        if not a.force:
            raise HwError('HW-E-MARGIN', 'no nextpnr log found for %s, so its timing margin is unknown'
                          % os.path.relpath(bit, ROOT), '--pnr LOG (its post-route log), or --force')
        worst = None
    else:
        mg, f = margin_of(log)
        worst = {'margin_pct': mg, 'clock': f and f['clock'], 'mhz': f and f['mhz'], 'pnr': os.path.relpath(log, ROOT)}
        if mg is not None and mg < MIN_MARGIN and not a.force:
            raise HwError('HW-E-MARGIN', '%s: %s %.2f MHz is only %+.1f%% over its %g MHz target (< %g%%, AGENTS.md rule 7)'
                          % (os.path.relpath(log, ROOT), f['clock'], f['mhz'], mg, f['target_mhz'], MIN_MARGIN),
                          'a thin-margin bitstream can fail on silicon; pick a seed with >= 10%, or --force')
    env = dict(os.environ)
    for kv in a.env or []:
        k, _, v = kv.partition('=')
        if not k.startswith(('EXPECT_', 'HW_', 'TB_')):
            raise HwError('HW-E-BADREQ', '--env %s: only EXPECT_*, HW_*, TB_* settings' % k)
        env[k] = v
    dev, baud = serial_dev(), int(setting('HW_BAUD', '1000000'))
    argv = ['python3', '-c', BOOT, ROOT, dev, str(baud), bit, a.suite]
    if a.suite == 'suite' and a.quick:
        argv.append('--quick')
    if blob:
        argv.append(blob)
    digest, sha = md5(bit), sha256f(bit)
    os.makedirs(CAP_DIR, exist_ok=True)
    rid = time.strftime('%Y%m%d-%H%M%S')
    ref = 'serial:' + rid
    with Lock('test %s %s' % (a.suite, os.path.basename(bit)), minutes=int(a.timeout // 60) + 5) as lk:
        require_port_free(dev)
        lk.left = '%s in SRAM (md5 %s) after hw lab test %s; safe to reprogram' % (os.path.basename(bit), digest, a.suite)
        t0 = time.time()
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=a.timeout, env=env, stdin=subprocess.DEVNULL)
            text, rc = r.stdout + r.stderr, r.returncode
        except subprocess.TimeoutExpired as e:
            text = (e.stdout or b'').decode('latin-1') if isinstance(e.stdout, bytes) else (e.stdout or '')
            rc = None
        dt = time.time() - t0
    with open(os.path.join(CAP_DIR, rid + '.log'), 'w') as fh:
        fh.write(text)
    if rc is None:
        raise HwError('HW-E-TIMEOUT', 'hw lab test %s timed out after %ds' % (a.suite, a.timeout),
                      'hw lab raw %s; --timeout SECONDS' % ref)
    checks = parse_suite(text, ref) if a.suite == 'suite' else parse_tmd(text, ref, a.suite if a.suite != 'blob'
                                                                           else os.path.basename(blob))
    n = {k: sum(1 for c in checks if c['status'] == k) for k in ('pass', 'fail', 'warn', 'skip')}
    status = 'fail' if n['fail'] else 'ok'
    lines = ['%s on %s (md5 %s): %d pass, %d fail, %d warn, %d skip in %.0f s%s; raw %s' % (
        a.suite, os.path.relpath(bit, ROOT), digest, n['pass'], n['fail'], n['warn'], n['skip'], dt,
        '' if worst is None else '; margin %+.1f%% (%s)' % (worst['margin_pct'], worst['clock']), ref)]
    order = {'fail': 0, 'warn': 1, 'skip': 2, 'pass': 3}
    # a test is never rerun to page its answer: the rest is in the stored output and in hw state
    shown, more = bounded(sorted(checks, key=lambda c: order[c['status']]), a.limit, a.all,
                          cursor=lambda i: 'hw lab raw %s --lines 200 (all %d checks; also hw state)' % (ref, len(checks)))
    lines += ['  %s %s: %s' % (c['status'].upper(), c['name'], c['observed'][:160]) for c in shown if c['status'] != 'pass']
    if a.force:
        lines.append('  --force: the margin / unknown-margin refusal was overridden')
    return Result('lab test', lines=lines, status=status, suite=a.suite, bitstream=os.path.relpath(bit, ROOT), md5=digest,
                  sha256=sha, margin=worst, forced=bool(a.force), counts=n, checks=shown, raw_ref=ref, **more,
                  _inputs=[bit] + ([blob] if blob else []), _checks=checks, _tool=a.suite,
                  _assumptions='bitstream in SRAM; board state is whatever the suite leaves')



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
    s.add_argument('--restart', action='store_true')
    t = p('test'); t.add_argument('suite'); t.add_argument('bitstream'); t.add_argument('--blob')
    t.add_argument('--pnr'); t.add_argument('--force', action='store_true'); t.add_argument('--quick', action='store_true')
    t.add_argument('--env', action='append'); t.add_argument('--timeout', type=float, default=1800)
    t.add_argument('--limit', type=int, default=20); t.add_argument('--all', action='store_true')
    r = p('raw'); r.add_argument('ref'); r.add_argument('--from', dest='start', type=int, default=0)
    r.add_argument('--lines', type=int, default=40)
    for v in ('flash', 'power-cycle'):
        q = p(v); q.add_argument('rest', nargs='*')
    def dispatch(a):
        fn = {'restart': cmd_restart, 'load': cmd_load, 'serial': cmd_serial, 'raw': cmd_raw, 'lock': cmd_lock,
              'test': cmd_test,
              'flash': refuse('HW-E-FLASH-DENIED', 'hw lab never writes the board\'s flash: flashing and promotion are the user\'s decision',
                              'ask the user; to try a bitstream without flashing it: hw lab load BITSTREAM (SRAM)'),
              'power-cycle': refuse('HW-E-UNSUPPORTED', 'the USB hub port does not cut the board\'s power, so it cannot be power-cycled from here',
                                    'hw lab restart (JTAG refresh: reloads flash); a real power cycle needs the user to unplug it'),
              }.get(a.verb) or refuse('HW-E-BADREQ', 'hw lab needs a verb: restart, load, serial, raw, lock', 'hw lab lock')
        return fn(a)
    return common.run(dispatch, argv, ap.parse_args, area='lab')


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
