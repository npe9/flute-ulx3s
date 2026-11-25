#!/usr/bin/env python3
"""hw fw: RISC-V firmware builds and ELF files as small records (hwsh CONTRACT.md).

  hw fw build [--cwd DIR] -- CMD...      run a build; typed diagnostics (gcc/as/ld/make), deduplicated;
                                          full output kept as fwlog:<sha12> (hw raw)
  hw fw diags LOG                        the same diagnostics from a saved build log
  hw fw sections ELF                     sections: address, size, flags; total text/data/bss
  hw fw symbols ELF [--grep RE] [--sort size|addr]   functions/objects: address, size, kind
  hw fw disasm ELF FUNC|ADDR [--source] [--limit N]  one function (bounded, cursor)
  hw fw addr ELF PC...                   function + file:line for a PC (mepc, a trap dump, a trace)
  hw fw csr NAME [VALUE]                 a CSR's address and fields; with VALUE, each field decoded
  hw raw fwlog:SHA12:LA-B                a slice of a saved build output

Tools: $HW_RISCV_PREFIX (default riscv64-unknown-elf-) binutils.  ELF answers are cached by the
file's content.  A build that exits non-zero or reports an error is `status: fail`, exit 1.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.environ.get('HWSH_LIB', os.path.expanduser('~/src/hwsh/lib')))
sys.path.insert(0, HERE)
from hwout import HwError, bounded  # noqa: E402
import common  # noqa: E402
import pnr  # noqa: E402  (cache helpers)
import timing  # noqa: E402  (run wrapper)
from csrs import CSRS, decode as csr_decode  # noqa: E402

PREFIX = os.environ.get('HW_RISCV_PREFIX', 'riscv64-unknown-elf-')
LOGS = os.path.join(pnr.CACHE, '..', 'fw')

RX_GCC = re.compile(r'^(?P<file>[^:\s][^:]*):(?P<line>\d+):(?:(?P<col>\d+):)? (?P<sev>fatal error|error|warning|note): '
                    r'(?P<msg>.*?)(?: \[(?P<code>-W[^\]]+|-f[^\]]+)\])?$')
RX_AS = re.compile(r'^(?P<file>[^:\s][^:]*):(?P<line>\d+): (?P<sev>Error|Warning|Fatal error): (?P<msg>.*)$')
RX_LD_REF = re.compile(r'^(?P<file>[^:\s][^:]*):(?:(?P<line>\d+):)?\((?P<sect>[^)+]+)\+(?P<off>0x[0-9a-f]+)\): (?P<msg>(?:undefined reference|'
                       r'relocation truncated|multiple definition|first defined)[^\n]*)$')
RX_LD = re.compile(r'^(?P<tool>\S*ld(?:\.bfd)?): (?P<msg>.*)$')
RX_MAKE = re.compile(r'^(?P<tool>g?make(?:\[\d+\])?): \*\*\* (?P<msg>.*)$')


def tool(name):
    p = shutil.which(PREFIX + name)
    if not p:
        raise HwError('HW-E-FW-NO-TOOL', '%s%s not on PATH' % (PREFIX, name),
                      'install the RISC-V binutils or set HW_RISCV_PREFIX')
    return p


def run_tool(argv, timeout=60):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise HwError('HW-E-TIMEOUT', '%s timed out after %ds' % (os.path.basename(argv[0]), timeout))
    if r.returncode:
        raise HwError('HW-E-FW-TOOL', '%s failed: %s' % (os.path.basename(argv[0]), r.stderr.strip()[:300]),
                      'is it an ELF file for this target?')
    return r.stdout


def elf(path):
    if not os.path.exists(path):
        raise HwError('HW-E-NOT-FOUND', 'no such file: %s' % path)
    with open(path, 'rb') as fh:
        if fh.read(4) != b'\x7fELF':
            raise HwError('HW-E-FW-NOT-ELF', '%s is not an ELF file' % path,
                          'a .bin has no symbols: pass the .elf built next to it')
    return path


def cached(path, key, fn):
    s = pnr.sha256(path)
    cf = os.path.join(LOGS, '%s-%s.json' % (key, s))
    try:
        return json.load(open(cf)), True
    except (OSError, ValueError):
        v = fn()
        pnr._atomic_write(cf, json.dumps(v, separators=(',', ':')))
        return v, False


# ---------------------------------------------------------------- diagnostics
def parse_diags(text, ref):
    out, ctx = [], None
    for i, l in enumerate(text.split('\n'), 1):
        l = l.rstrip()
        d = None
        m = RX_GCC.match(l)
        if m:
            sev = {'fatal error': 'error'}.get(m.group('sev'), m.group('sev'))
            d = {'code': m.group('code') or 'gcc-' + sev, 'severity': sev, 'file': m.group('file'),
                 'line': int(m.group('line')), 'col': int(m.group('col')) if m.group('col') else None,
                 'message': m.group('msg'), 'tool': 'gcc'}
        elif RX_AS.match(l):
            m = RX_AS.match(l)
            d = {'code': 'as-' + m.group('sev').split()[-1].lower(), 'severity': 'error' if 'rror' in m.group('sev') else
                 'warning', 'file': m.group('file'), 'line': int(m.group('line')), 'col': None,
                 'message': m.group('msg'), 'tool': 'as'}
        elif RX_LD_REF.match(l):
            m = RX_LD_REF.match(l)
            d = {'code': 'ld-' + m.group('msg').split()[0], 'severity': 'note' if 'first defined' in l else 'error',
                 'file': m.group('file'), 'line': int(m.group('line')) if m.group('line') else None, 'col': None,
                 'message': m.group('msg') + (' (in %s)' % ctx if ctx else ''), 'tool': 'ld'}
        elif RX_MAKE.match(l):
            m = RX_MAKE.match(l)
            d = {'code': 'make-error', 'severity': 'error', 'file': None, 'line': None, 'col': None,
                 'message': m.group('msg'), 'tool': 'make'}
        elif RX_LD.match(l):
            m = RX_LD.match(l)
            msg = m.group('msg')
            fm = re.match(r"(.+?): in function `([^']+)':$", msg)
            if fm:
                ctx = fm.group(2)
                continue
            if msg.startswith('warning:'):
                sev, msg = 'warning', msg[8:].strip()
            elif re.search(r'overflowed by|cannot find|undefined|error|will not fit|multiple definition', msg):
                sev = 'error'
            else:
                continue
            code = 'ld-region-overflow' if 'overflowed by' in msg else 'ld-' + sev
            d = {'code': code, 'severity': sev, 'file': None, 'line': None, 'col': None, 'message': msg, 'tool': 'ld'}
        if d:
            d['raw_ref'] = '%s:L%d-%d' % (ref, i, i + 2)
            d['_line'] = i
            out.append(d)
    # dedupe: the same message at the same place (headers included from many files) counts once
    seen, uniq = {}, []
    for d in out:
        k = (d['code'], d['file'], d['line'], d['message'])
        if k in seen:
            seen[k]['count'] += 1
            continue
        d['count'] = 1
        seen[k] = d
        uniq.append(d)
    for d in uniq:
        d.pop('_line')
    order = {'error': 0, 'warning': 1, 'note': 2}
    uniq.sort(key=lambda d: order.get(d['severity'], 3))
    return uniq


def save_log(text):
    s = hashlib.sha256(text.encode()).hexdigest()
    p = os.path.join(LOGS, 'log-%s.txt' % s)
    if not os.path.exists(p):
        pnr._atomic_write(p, text)
    return 'fwlog:' + s[:12], p


def diag_answer(cmd, text, rc_build, extra):
    ref, _ = save_log(text)
    ds = parse_diags(text, ref)
    errs = [d for d in ds if d['severity'] == 'error']
    warns = [d for d in ds if d['severity'] == 'warning']
    shown, more = bounded(ds, extra.pop('limit'), extra.pop('all'))
    failed = bool(errs) or (rc_build not in (None, 0))
    head = '%s: %s, %d error(s), %d warning(s)%s; full output %s' % (
        cmd, 'FAILED' if failed else 'ok', len(errs), len(warns),
        '' if rc_build is None else ', exit %d' % rc_build, ref)
    lines = [head]
    for d in shown:
        where = ('%s:%s' % (d['file'], d['line']) if d['line'] else d['file']) if d['file'] else d['tool']
        lines.append('  %s %s %s: %s%s' % (d['severity'], d['code'], where, d['message'][:200],
                                           ' (x%d)' % d['count'] if d['count'] > 1 else ''))
    if failed and not errs:
        lines.append('  no diagnostic matched; read the end of the output: hw raw %s:L%d-%d' % (
            ref, max(1, text.count('\n') - 15), text.count('\n') + 1))
    return dict(cmd=cmd, status='fail' if failed else 'ok', exit=rc_build, errors=len(errs), warnings=len(warns),
                diagnostics=shown, raw=ref, lines=lines, _diagnostics=ds, **more, **extra)


def cmd_build(a):
    argv = a.command
    if argv and argv[0] == '--':
        argv = argv[1:]
    if not argv:
        raise HwError('HW-E-BADREQ', 'no build command', 'hw fw build -- make -C sw')
    try:
        r = subprocess.run(argv, cwd=a.cwd, capture_output=True, text=True, timeout=a.timeout, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        raise HwError('HW-E-NOT-FOUND', 'no such command: %s' % argv[0])
    except subprocess.TimeoutExpired:
        raise HwError('HW-E-TIMEOUT', 'build timed out after %ds' % a.timeout, '--timeout SECONDS')
    return diag_answer('fw build', r.stdout + r.stderr, r.returncode, {'limit': a.limit, 'all': a.all,
                                                                      'argv': argv})


def cmd_diags(a):
    if not os.path.exists(a.log):
        raise HwError('HW-E-NOT-FOUND', 'no such file: %s' % a.log)
    return diag_answer('fw diags', open(a.log, errors='replace').read(), None, {'limit': a.limit, 'all': a.all,
                                                                                '_inputs': [a.log]})


def cmd_raw(a):
    try:
        _, sha12, rng = a.ref.split(':', 2)
        lo, hi = (int(x) for x in rng.lstrip('L').split('-'))
    except ValueError:
        raise HwError('HW-E-BADREQ', 'bad raw ref `%s`' % a.ref, 'refs look like fwlog:<sha12>:L<a>-<b>')
    hits = [f for f in (os.listdir(LOGS) if os.path.isdir(LOGS) else []) if f.startswith('log-' + sha12)]
    if not hits:
        raise HwError('HW-E-NOT-FOUND', 'no saved build output %s' % sha12, 'rerun hw fw build')
    lines = open(os.path.join(LOGS, hits[0]), errors='replace').read().split('\n')[lo - 1:hi]
    shown, more = bounded(lines, a.limit, a.all, cursor=lambda i: 'fwlog:%s:L%d-%d' % (sha12, lo + i, hi))
    return {'cmd': 'fw raw', 'ref': a.ref, 'text': shown, 'lines': shown, 'cached': True, **more}


# ---------------------------------------------------------------- ELF
def sections_of(path):
    out = run_tool([tool('readelf'), '-S', '-W', path])
    secs = []
    for l in out.split('\n'):
        m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+\S+\s+(\S*)', l)
        if m and m.group(1) != 'NULL' and m.group(2) != 'NULL':
            secs.append({'name': m.group(1), 'type': m.group(2), 'addr': int(m.group(3), 16),
                         'size': int(m.group(5), 16), 'flags': m.group(6)})
    return secs


def cmd_sections(a):
    secs, cached_ = cached(elf(a.elf), 'sections', lambda: sections_of(a.elf))
    alloc = [s for s in secs if 'A' in s['flags']]
    text = sum(s['size'] for s in alloc if 'X' in s['flags'])
    bss = sum(s['size'] for s in alloc if s['type'] == 'NOBITS')
    data = sum(s['size'] for s in alloc) - text - bss
    shown, more = bounded(alloc, a.limit, a.all)
    lines = ['%s: text %d, data %d, bss %d bytes; loaded %#x..%#x' % (
        timing.label(a.elf), text, data, bss, min((s['addr'] for s in alloc), default=0),
        max((s['addr'] + s['size'] for s in alloc), default=0))]
    lines += ['  %-20s %#010x %8d %s' % (s['name'], s['addr'], s['size'], s['flags']) for s in shown]
    return dict(cmd='fw sections', elf=timing.label(a.elf), text=text, data=data, bss=bss, sections=shown,
                cached=cached_, lines=lines, **more, _inputs=[a.elf])


def symbols_of(path):
    out = run_tool([tool('nm'), '-S', '-n', path])
    syms = []
    for l in out.split('\n'):
        m = re.match(r'([0-9a-f]+) (?:([0-9a-f]+) )?(\w) (\S+)$', l)
        if m:
            syms.append({'name': m.group(4), 'addr': int(m.group(1), 16),
                         'size': int(m.group(2), 16) if m.group(2) else None, 'kind': m.group(3)})
    return syms


KIND = {'T': 'func', 't': 'func', 'D': 'data', 'd': 'data', 'B': 'bss', 'b': 'bss', 'R': 'rodata', 'r': 'rodata',
        'A': 'abs', 'a': 'abs', 'W': 'weak', 'w': 'weak'}


def cmd_symbols(a):
    syms, cached_ = cached(elf(a.elf), 'symbols', lambda: symbols_of(a.elf))
    if a.grep:
        rx = re.compile(a.grep)
        syms = [s for s in syms if rx.search(s['name'])]
    if a.sort == 'size':
        syms = sorted(syms, key=lambda s: -(s['size'] or 0))
    shown, more = bounded(syms, a.limit, a.all, cursor=lambda i: '--from %d' % i)
    lines = ['  %#010x %7s %-6s %s' % (s['addr'], s['size'] if s['size'] is not None else '-',
                                       KIND.get(s['kind'], s['kind']), s['name']) for s in shown]
    if not syms:
        raise HwError('HW-E-NOT-FOUND', 'no symbol matches `%s`' % a.grep, 'hw fw symbols ELF --sort size')
    return dict(cmd='fw symbols', elf=timing.label(a.elf), count=len(syms),
                symbols=[dict(s, kind=KIND.get(s['kind'], s['kind'])) for s in shown], cached=cached_,
                lines=['%s: %d symbols%s' % (timing.label(a.elf), len(syms), ' matching ' + a.grep if a.grep else '')]
                + lines, **more)


def lookup(path, what):
    syms, _ = cached(path, 'symbols', lambda: symbols_of(path))
    funcs = [s for s in syms if s['kind'] in 'Tt']
    if re.match(r'^(0x)?[0-9a-fA-F]+$', what) and not any(s['name'] == what for s in syms):
        pc = int(what, 16)
        best = None
        for s in funcs:
            if s['addr'] <= pc and (best is None or s['addr'] >= best['addr']):
                best = s
        return pc, best
    hit = [s for s in funcs if s['name'] == what] or [s for s in syms if s['name'] == what]
    if not hit:
        import difflib
        near = ([s['name'] for s in funcs if what.lower() in s['name'].lower()] +
                difflib.get_close_matches(what, [s['name'] for s in funcs], 5))[:5]
        raise HwError('HW-E-NOT-FOUND', 'no function `%s`' % what,
                      'similar: %s' % ', '.join(near) if near else 'hw fw symbols ELF --grep RE')
    return hit[0]['addr'], hit[0]


def cmd_disasm(a):
    elf(a.elf)
    pc, sym = lookup(a.elf, a.what)
    if sym is None:
        raise HwError('HW-E-NOT-FOUND', 'no function contains %#x' % pc, 'hw fw sections ELF')
    start = sym['addr']
    stop = start + (sym['size'] or 0x200)
    argv = [tool('objdump'), '-d', '--no-show-raw-insn', '--start-address=%#x' % start,
            '--stop-address=%#x' % stop, a.elf]
    if a.source:
        argv.insert(2, '-S')
    out = run_tool(argv)
    body = [l for l in out.split('\n') if re.match(r'\s*[0-9a-f]+:\t', l) or (a.source and l and not
            l.startswith(('Disassembly', a.elf)) and 'file format' not in l)]
    body = [re.sub(r'\s+', ' ', l.strip()) for l in body]
    shown, more = bounded(body[a.start:], a.limit, a.all, cursor=lambda i: '--from %d' % (a.start + i))
    lines = ['%s %s @ %#x, %s bytes, %d lines%s' % (timing.label(a.elf), sym['name'], start,
             sym['size'] if sym['size'] else '? (no size: first 512)', len(body),
             '' if pc == start else '; %#x is +%#x' % (pc, pc - start))] + shown
    return dict(cmd='fw disasm', function=sym['name'], addr=start, size=sym['size'], insns=shown, lines=lines,
                cached=False, **more)


def cmd_addr(a):
    elf(a.elf)
    out = run_tool([tool('addr2line'), '-f', '-i', '-C', '-e', a.elf] + ['%#x' % int(p, 16) for p in a.pcs])
    # without -a, each pc gives function/file:line pairs (several when inlined); split by our own lookup
    raw = out.strip().split('\n')
    recs, lines = [], []
    k = 0
    for p in a.pcs:
        pc, sym = lookup(a.elf, p if p.lower().startswith('0x') else '0x' + p)
        fn, loc = (raw[k], raw[k + 1]) if k + 1 < len(raw) else ('??', '??:0')
        k += 2
        m = re.match(r'(.*):(\?|\d+)', loc)
        r = {'pc': pc, 'symbol': sym and sym['name'], 'offset': pc - sym['addr'] if sym else None,
             'function': None if fn == '??' else fn,
             'file': None if not m or m.group(1) == '??' else m.group(1),
             'line': int(m.group(2)) if m and m.group(2).isdigit() else None}
        recs.append(r)
        lines.append('%#010x %s+%s %s' % (pc, r['symbol'] or '?', hex(r['offset']) if r['offset'] is not None else '?',
                                         '%s:%s' % (r['file'], r['line']) if r['file'] else '(no line info: built without -g)'))
    return dict(cmd='fw addr', pcs=recs, lines=lines, cached=False)


def cmd_csr(a):
    key = a.name.lower()
    c = CSRS.get(key)
    if c is None:
        byaddr = {v['addr']: k for k, v in CSRS.items()}
        try:
            key = byaddr.get(int(a.name, 16))
        except ValueError:
            key = None
        c = CSRS.get(key)
    if c is None:
        raise HwError('HW-E-NOT-FOUND', 'unknown CSR `%s`' % a.name, 'known: ' + ', '.join(sorted(CSRS)))
    if a.value is None:
        lines = ['%s %#05x %s: %s' % (key, c['addr'], c.get('priv', ''), c['desc'])]
        lines += ['  [%s] %s%s' % (f['bits'], f['name'], ': ' + f['desc'] if f.get('desc') else '') for f in c.get('fields', [])]
        return dict(cmd='fw csr', csr=key, addr=c['addr'], desc=c['desc'], fields=c.get('fields', []), lines=lines,
                    cached=True)
    try:
        v = int(a.value, 0) if a.value.lower().startswith('0x') or a.value.isdigit() else int(a.value, 16)
    except ValueError:
        raise HwError('HW-E-BADREQ', 'bad value `%s`' % a.value, 'hex like 0x4014112f')
    fields, summary = csr_decode(key, v)
    lines = ['%s = %#010x: %s' % (key, v, summary)]
    lines += ['  %-10s [%s] = %s%s' % (f['name'], f['bits'], f['value'], ' (%s)' % f['meaning'] if f.get('meaning') else '')
              for f in fields if f['value'] or f.get('always')]
    return dict(cmd='fw csr', csr=key, addr=c['addr'], value=v, fields=fields, summary=summary, lines=lines,
                cached=True)


def parse(argv):
    p = common.Parser(prog='hw fw', add_help=False)
    p.add_argument('--json', action='store_true')
    sub = p.add_subparsers(dest='verb', required=True, parser_class=common.Parser)

    def lim(sp, n=20):
        sp.add_argument('--limit', type=int, default=n)
        sp.add_argument('--all', action='store_true')
        sp.add_argument('--json', action='store_true')
    s = sub.add_parser('build'); s.add_argument('--cwd'); s.add_argument('--timeout', type=int, default=1800)
    lim(s); s.add_argument('command', nargs='...'); s.set_defaults(fn=cmd_build)
    s = sub.add_parser('diags'); s.add_argument('log'); lim(s); s.set_defaults(fn=cmd_diags)
    s = sub.add_parser('sections'); s.add_argument('elf'); lim(s, 30); s.set_defaults(fn=cmd_sections)
    s = sub.add_parser('symbols'); s.add_argument('elf'); s.add_argument('--grep'); s.add_argument(
        '--sort', choices=('addr', 'size'), default='addr'); lim(s); s.set_defaults(fn=cmd_symbols)
    s = sub.add_parser('disasm'); s.add_argument('elf'); s.add_argument('what'); s.add_argument('--source', action='store_true')
    s.add_argument('--from', dest='start', type=int, default=0); lim(s, 40); s.set_defaults(fn=cmd_disasm)
    s = sub.add_parser('addr'); s.add_argument('elf'); s.add_argument('pcs', nargs='+'); lim(s); s.set_defaults(fn=cmd_addr)
    s = sub.add_parser('csr'); s.add_argument('name'); s.add_argument('value', nargs='?'); lim(s); s.set_defaults(fn=cmd_csr)
    s = sub.add_parser('raw'); s.add_argument('ref'); lim(s, 40); s.set_defaults(fn=cmd_raw)
    return p.parse_args(argv)


if __name__ == '__main__':
    sys.exit(timing.run(sys.argv[1:], area='fw', parser=parse, doc=__doc__))
