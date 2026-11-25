#!/usr/bin/env python3
"""hw board: ULX3S board facts as small records (hwsh CONTRACT.md).  Read-only.

  hw board pins [NAME|--grep RE] [--limit N|--all] [--json]   the .lpf: site, IO type, pull, drive
  hw board clock [--json]                                       crystal, PLL options, the promoted clock
  hw board map [ADDR|NAME] [--json]                             the SoC memory map (SoC_Map.bsv)
  hw board state [--json]                                       what is on the board (data/ulx3s.toml)

Every record carries the file:line it was read from.  A fact the sources do not hold is an
error record, not a guess.
"""
import argparse
import os
import re
import sys
import tomllib

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.environ.get('HW_ROOT') or os.path.normpath(os.path.join(HERE, '..', '..'))   # HW_ROOT: tests
sys.path.insert(0, os.environ.get('HWSH_LIB', os.path.expanduser('~/src/hwsh/lib')))
from hwout import HwError, Result, bounded  # noqa: E402
sys.path.insert(0, HERE)
import common  # noqa: E402

FACTS = os.path.join(HERE, 'data', 'ulx3s.toml')
SOC_MAP = os.path.join(ROOT, 'Flute', 'src_Testbench', 'SoC', 'SoC_Map.bsv')


def rel(p):
    return os.path.relpath(p, ROOT)


def facts():
    if not os.path.exists(FACTS):
        raise HwError('HW-E-NO-FACTS', 'no fact file for this board (%s)' % rel(FACTS),
                      'add tools/hw/data/<board>.toml; facts are never guessed')
    with open(FACTS, 'rb') as fh:
        return tomllib.load(fh)


def lpf_path():
    return os.path.join(ROOT, facts()['board']['lpf'])


def read_pins():
    """-> {name: {site, io_type, pull, drive, freq, loc}} from the .lpf (LOCATE + IOBUF + FREQUENCY)."""
    path, pins, wild = lpf_path(), {}, []
    with open(path) as fh:
        for n, line in enumerate(fh, 1):
            line = line.split('#')[0]
            m = re.match(r'\s*LOCATE\s+COMP\s+"([^"]+)"\s+SITE\s+"([^"]+)"', line)
            if m:
                pins.setdefault(m.group(1), {})['site'] = m.group(2)
                pins[m.group(1)]['loc'] = '%s:%d' % (rel(path), n)
                continue
            m = re.match(r'\s*IOBUF\s+PORT\s+"([^"]+)"\s+(.*?);', line)
            if m:
                attrs = {{'IO_TYPE': 'io_type', 'PULLMODE': 'pull', 'DRIVE': 'drive'}.get(k, k.lower()): v
                         for k, v in re.findall(r'(\w+)=(\S+)', m.group(2))}
                if '[*]' in m.group(1): wild.append((m.group(1).replace('[*]', ''), attrs))   # a bus
                else: pins.setdefault(m.group(1), {}).update(attrs)
                continue
            m = re.match(r'\s*FREQUENCY\s+PORT\s+"([^"]+)"\s+([\d.]+)\s*MHZ', line, re.I)
            if m:
                pins.setdefault(m.group(1), {})['freq_mhz'] = float(m.group(2))
    for prefix, attrs in wild:                  # IOBUF PORT "led[*]": every led[i]
        for n, p in pins.items():
            if n.startswith(prefix + '['):
                for k, v in attrs.items(): p.setdefault(k, v)
    return pins


def pin_line(name, p):
    extra = ' '.join('%s=%s' % (k, p[k]) for k in ('io_type', 'pull', 'drive', 'freq_mhz') if k in p)
    return '%s %s %s (%s)' % (name, p.get('site', '?'), extra, p.get('loc', '?'))


def cmd_pins(a):
    pins = read_pins()
    if a.name and not a.grep:
        if a.name not in pins:
            close = [n for n in pins if a.name.lower() in n.lower()][:5]
            raise HwError('HW-E-NOT-FOUND', 'no pin `%s` in %s' % (a.name, rel(lpf_path())),
                          ('did you mean: ' + ', '.join(close)) if close else 'hw board pins --grep RE')
        p = dict(pins[a.name], name=a.name)
        return Result('board pins', lines=[pin_line(a.name, pins[a.name])], pins=[p])
    names = sorted(pins)
    if a.grep:
        rx = re.compile(a.grep, re.I)
        names = [n for n in names if rx.search(n)]
    shown, more = bounded(names, a.limit, a.all, cursor=lambda i: 'pins:%d' % i)
    return Result('board pins', lines=[pin_line(n, pins[n]) for n in shown],
                  pins=[dict(pins[n], name=n) for n in shown], count=len(names), **more)


def cmd_clock(a):
    f, recs, lines = facts(), [], []
    pins = read_pins()
    clk = [(n, p) for n, p in pins.items() if 'freq_mhz' in p]
    for n, p in clk:
        recs.append({'kind': 'crystal', 'pin': n, 'mhz': p['freq_mhz'], 'loc': p['loc']})
        lines.append('crystal %s MHz on %s %s (%s)' % (p['freq_mhz'], n, p.get('site'), p['loc']))
    mk = os.path.join(ROOT, 'Makefile')
    with open(mk) as fh:
        text = fh.read().split('\n')
    default, cond = None, None
    for n, line in enumerate(text, 1):
        m = re.match(r'SYS_PLL\s*\?=\s*(\S+)', line)
        if m: default = m.group(1); recs.append({'kind': 'default', 'SYS_PLL': default, 'loc': 'Makefile:%d' % n})
        m = re.match(r'(?:else\s+)?ifeq\s*\(\$\(SYS_PLL\),\s*(\w+)\)', line)
        if m: cond = m.group(1); continue
        m = re.search(r'-D SYS_CLK_HZ=(\d+)', line)
        if m and cond:
            recs.append({'kind': 'pll', 'SYS_PLL': cond, 'hz': int(m.group(1)), 'loc': 'Makefile:%d' % n})
            lines.append('SYS_PLL=%s -> %.6g MHz system clock (Makefile:%d)' % (cond, int(m.group(1)) / 1e6, n))
            cond = None
    if default == '0':
        lines.append('SYS_PLL default 0 -> the crystal clock, no PLL')
    return Result('board clock', lines=lines, clocks=recs)


def read_map():
    """-> [{name, base, size, lim, ifdef, loc}] from SoC_Map.bsv's <name>_addr_base/_size."""
    out, stack, base = [], [], {}
    with open(SOC_MAP) as fh:
        for n, line in enumerate(fh, 1):
            s = line.strip()
            m = re.match(r'`(ifdef|ifndef)\s+(\w+)', s)
            if m: stack.append(('!' if m.group(1) == 'ifndef' else '') + m.group(2)); continue
            if s.startswith('`else') and stack:
                stack[-1] = stack[-1][1:] if stack[-1].startswith('!') else '!' + stack[-1]; continue
            if s.startswith('`endif') and stack: stack.pop(); continue
            m = re.match(r"Fabric_Addr\s+(\w+?)_addr_(base|size)\s*=\s*'h_?([0-9A-Fa-f_]+)\s*;", s)
            if not m: continue
            name, kind, val = m.group(1), m.group(2), int(m.group(3).replace('_', ''), 16)
            if kind == 'base':
                base[name] = (val, n, list(stack))
            elif name in base:
                b, bn, st = base.pop(name)
                out.append({'name': name, 'base': b, 'size': val, 'lim': b + val,
                            'ifdef': st, 'loc': '%s:%d' % (rel(SOC_MAP), bn)})
    return sorted(out, key=lambda r: r['base'])


def map_line(r):
    cond = (' [if %s]' % ' && '.join(r['ifdef'])) if r['ifdef'] else ''
    return '0x%08x-0x%08x %-22s %s%s (%s)' % (r['base'], r['lim'] - 1, r['name'], size(r['size']), cond, r['loc'])


def size(n):
    for u, d in (('M', 1 << 20), ('K', 1 << 10)):
        if n % d == 0 and n >= d: return '%d%sB' % (n // d, u)
    return '%dB' % n


def cmd_map(a):
    rows = read_map()
    if a.what:
        try:
            addr = int(a.what, 0)
            rows = [r for r in rows if r['base'] <= addr < r['lim']]
            if not rows:
                raise HwError('HW-E-NOT-FOUND', 'no device at 0x%08x in %s' % (addr, rel(SOC_MAP)),
                              'hw board map (the whole map)')
        except ValueError:
            rows = [r for r in rows if a.what.lower() in r['name'].lower()]
            if not rows:
                raise HwError('HW-E-NOT-FOUND', 'no map entry matching `%s`' % a.what, 'hw board map')
    shown, more = bounded(rows, a.limit, a.all, cursor=lambda i: 'map:%d' % i)
    note = 'entries marked [if X] exist only in builds that define X (the SoC profile)'
    return Result('board map', lines=[map_line(r) for r in shown] + ([note] if any(r['ifdef'] for r in shown) else []),
                  map=shown, **more)


def cmd_state(a):
    f, lines = facts(), []
    b = f.get('board', {})
    lines.append('%s: %s, %s' % (b.get('name'), b.get('fpga'), b.get('sdram')))
    lines.append('flash slot 0: %s (backup %s)' % (f['flash']['slot0'], f['flash']['backup']))
    lines.append('flash writes: never by hw lab (the user decides)')
    lines.append('restart: %s (power cannot be cut from here)' % f['restart']['method'])
    lines.append('read-only: %s; refused images: %s' % (', '.join(f['readonly']['devices']), ', '.join(f['readonly']['images'])))
    return Result('board state', lines=lines, facts=f, loc=rel(FACTS))


def main(argv):
    ap = common.Parser(prog='hw board')
    ap.add_argument('--json', action='store_true')
    sub = ap.add_subparsers(dest='verb', parser_class=common.Parser)
    for v in ('pins', 'clock', 'map', 'state'):
        p = sub.add_parser(v)
        p.add_argument('--json', action='store_true')
        p.add_argument('--limit', type=int, default=20)
        p.add_argument('--all', action='store_true')
        if v == 'pins':
            p.add_argument('name', nargs='?')
            p.add_argument('--grep')
        if v == 'map':
            p.add_argument('what', nargs='?')
    def dispatch(a):
        fn = {'pins': cmd_pins, 'clock': cmd_clock, 'map': cmd_map, 'state': cmd_state}.get(a.verb)
        if fn is None:
            def fn(_):
                raise HwError('HW-E-BADREQ', 'hw board needs a verb: pins, clock, map, state', 'hw board pins --grep led')
        return fn(a)
    return common.run(dispatch, argv, ap.parse_args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
