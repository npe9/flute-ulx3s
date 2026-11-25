#!/usr/bin/env python3
"""hw place: where nextpnr put the design, from a placed/routed JSON (`nextpnr-ecp5 ... --write F.json`).

  hw place summary FILE                          cells per type, the used grid, the top-level blocks
  hw place modules FILE [--depth N] [--under P]  per hierarchy prefix: logic cells, centroid, bbox, spread
  hw place location FILE NAME                    the cells of one signal/instance (collapsed names) or a prefix
  hw place compare A B [--depth N] [--under P]   which blocks moved, A -> B (centroid shift, cell count)
  hw place congestion | route                    not available (HW-E-UNSUPPORTED; see hint)

Generalizes build/placediag/cent.py.  The (cell, type, x, y) table is cached by file content in
~/.cache/hwsh/pnr/place-<sha>.json, so a 160 MB JSON is parsed once.  Coordinates are nextpnr
tile X/Y (ECP5-85: EBR rows at y=22/46/70/82).  Fanout lives in `hw netlist loads`.
"""
import json
import math
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.environ.get('HWSH_LIB', os.path.expanduser('~/src/hwsh/lib')))
sys.path.insert(0, HERE)
from hwout import HwError, bounded  # noqa: E402
import pnr  # noqa: E402
import timing  # noqa: E402  (shared run wrapper)
import common  # noqa: E402

LOGIC = ('TRELLIS_COMB', 'TRELLIS_FF', 'TRELLIS_SLICE')
TABLE_VERSION = 1
WRITE_HINT = ('write one with: nextpnr-ecp5 <same flags> --no-route --write placed.json  '
              '(see build/placediag/run.sh); a routed run takes --write too')


def table(path):
    if not os.path.exists(path):
        raise HwError('HW-E-NOT-FOUND', 'no such file: %s' % path, WRITE_HINT)
    sha = pnr.sha256(path)
    cf = os.path.join(pnr.CACHE, 'place-%s.json' % sha)
    try:
        t = json.load(open(cf))
        if t.get('v') == TABLE_VERSION:
            return t, True
    except (OSError, ValueError):
        pass
    try:
        d = json.load(open(path))
    except ValueError as e:
        raise HwError('HW-E-PLACE-FORMAT', '%s is not JSON: %s' % (path, e), WRITE_HINT)
    cells = []
    for mod in (d.get('modules') or {}).values():
        for name, c in mod.get('cells', {}).items():
            bel = (c.get('attributes') or {}).get('NEXTPNR_BEL')
            m = re.match(r'X(\d+)/Y(\d+)/(\S+)', bel or '')
            if m:
                cells.append([name, c['type'], int(m.group(1)), int(m.group(2)), m.group(3)])
    if not cells:
        raise HwError('HW-E-PLACE-UNPLACED', '%s has no placed cells (no NEXTPNR_BEL): a yosys netlist, '
                      'not a nextpnr --write output' % path, WRITE_HINT)
    t = {'v': TABLE_VERSION, 'sha12': sha[:12], 'creator': d.get('creator'), 'cells': cells}
    pnr._atomic_write(cf, json.dumps(t, separators=(',', ':')))
    return t, False


def prefix(name, depth):
    parts = name.split('.')
    return '.'.join(parts[:depth]) if len(parts) > depth else '.'.join(parts[:-1]) or '(top)'


def stats(cells):
    n = len(cells)
    xs = [c[2] for c in cells]
    ys = [c[3] for c in cells]
    cx, cy = sum(xs) / n, sum(ys) / n
    sd = math.sqrt(sum((x - cx) ** 2 + (y - cy) ** 2 for x, y in zip(xs, ys)) / n)
    return {'n': n, 'centroid': [round(cx, 1), round(cy, 1)], 'bbox': [min(xs), min(ys), max(xs), max(ys)],
            'spread': round(sd, 1)}


def groups(t, depth, under):
    g = {}
    for c in t['cells']:
        if c[1] not in LOGIC:
            continue
        if under and not c[0].startswith(under):
            continue
        g.setdefault(prefix(c[0], depth), []).append(c)
    return g


def fmt_stat(name, s):
    return '%-48s %6d cells  at (%5.1f,%5.1f)  bbox %s  spread %.1f' % (
        name, s['n'], s['centroid'][0], s['centroid'][1], tuple(s['bbox']), s['spread'])


def cmd_summary(a):
    t, cached = table(a.file)
    by = {}
    for c in t['cells']:
        by[c[1]] = by.get(c[1], 0) + 1
    xs = [c[2] for c in t['cells']]
    ys = [c[3] for c in t['cells']]
    top = sorted(((k, stats(v)) for k, v in groups(t, 2, None).items()), key=lambda kv: -kv[1]['n'])
    shown, more = timing.page(top, a)
    lines = ['%s: %d placed cells, grid x %d..%d y %d..%d; %s' % (
        timing.label(a.file), len(t['cells']), min(xs), max(xs), min(ys), max(ys),
        ', '.join('%s %d' % kv for kv in sorted(by.items(), key=lambda kv: -kv[1])[:8]))]
    lines += [fmt_stat(k, s) for k, s in shown]
    return dict(cmd='place summary', file=timing.label(a.file), cells_by_type=by, grid=[min(xs), min(ys), max(xs), max(ys)],
                blocks=[dict(prefix=k, **s) for k, s in shown], cached=cached, lines=lines, **more,
                _inputs=[a.file], _tool='nextpnr-ecp5')


def cmd_modules(a):
    t, cached = table(a.file)
    rows = sorted(((k, stats(v)) for k, v in groups(t, a.depth, a.under).items()), key=lambda kv: -kv[1]['n'])
    if not rows:
        raise HwError('HW-E-NOT-FOUND', 'no logic cells under `%s`' % a.under, 'hw place summary FILE lists the blocks')
    shown, more = timing.page(rows, a)
    return dict(cmd='place modules', file=timing.label(a.file), depth=a.depth, under=a.under,
                modules=[dict(prefix=k, **s) for k, s in shown], cached=cached,
                lines=[fmt_stat(k, s) for k, s in shown], **more)


def cmd_location(a):
    t, cached = table(a.file)
    exact = [c for c in t['cells'] if pnr.collapse(c[0]) == a.name]
    under = exact or [c for c in t['cells'] if c[0].startswith(a.name)]
    if not under:
        raise HwError('HW-E-NOT-FOUND', 'no cell named or prefixed `%s`' % a.name,
                      'names are yosys hierarchical names, e.g. top.soc_top.core.cpu.gpr_regfile')
    s = stats(under)
    kinds = {}
    for c in under:
        kinds[c[1]] = kinds.get(c[1], 0) + 1
    cells = [{'cell': c[0], 'type': c[1], 'x': c[2], 'y': c[3], 'bel': c[4]} for c in under]
    shown, more = timing.page(cells, a)
    lines = [fmt_stat(a.name + (' (signal)' if exact else ' (prefix)'), s),
             '  types: ' + ', '.join('%s %d' % kv for kv in sorted(kinds.items(), key=lambda kv: -kv[1]))]
    lines += ['  %s %s X%d/Y%d/%s' % (pnr.collapse(c['cell']), c['type'], c['x'], c['y'], c['bel']) for c in shown[:5]]
    return dict(cmd='place location', file=timing.label(a.file), match='signal' if exact else 'prefix', **s,
                types=kinds, cells=shown, cached=cached, lines=lines, **more)


def cmd_compare(a):
    ta, ca = table(a.a)
    tb, cb = table(a.b)
    ga, gb = groups(ta, a.depth, a.under), groups(tb, a.depth, a.under)
    rows = []
    for k in set(ga) | set(gb):
        sa = stats(ga[k]) if k in ga else None
        sb = stats(gb[k]) if k in gb else None
        shift = (round(math.hypot(sb['centroid'][0] - sa['centroid'][0], sb['centroid'][1] - sa['centroid'][1]), 1)
                 if sa and sb else None)
        rows.append({'prefix': k, 'a': sa, 'b': sb, 'shift': shift,
                     'delta_n': (sb['n'] if sb else 0) - (sa['n'] if sa else 0)})
    rows.sort(key=lambda r: (r['shift'] is None, -(r['shift'] or 0), -abs(r['delta_n'])))
    shown, more = timing.page(rows, a)
    lines = ['%s -> %s (depth %d%s), biggest centroid moves first' % (
        timing.label(a.a), timing.label(a.b), a.depth, ', under ' + a.under if a.under else '')]
    for r in shown:
        if r['a'] and r['b']:
            lines.append('  %-46s moved %5.1f  (%5.1f,%5.1f)->(%5.1f,%5.1f)  cells %+d  spread %.1f->%.1f' % (
                r['prefix'], r['shift'], *r['a']['centroid'], *r['b']['centroid'], r['delta_n'],
                r['a']['spread'], r['b']['spread']))
        else:
            lines.append('  %-46s only in %s (%d cells)' % (r['prefix'], 'A' if r['a'] else 'B', (r['a'] or r['b'])['n']))
    return dict(cmd='place compare', a=timing.label(a.a), b=timing.label(a.b), modules=shown, cached=ca and cb,
                lines=lines, **more)


def cmd_unsupported(a):
    if a.verb == 'fanout':
        raise HwError('HW-E-UNSUPPORTED', 'fanout is a netlist question', 'hw netlist loads NETLIST.json NET')
    raise HwError('HW-E-UNSUPPORTED', 'place %s is planned, not available' % a.verb,
                  'routing congestion: rerun nextpnr with --router2-heatmap PREFIX (router2 only); '
                  'per-net route: not in the --write JSON. Placement density: hw place modules')


def parse(argv):
    p = common.Parser(prog='hw place', add_help=False)
    p.add_argument('--json', action='store_true')
    sub = p.add_subparsers(dest='verb', required=True, parser_class=common.Parser)

    def lim(sp, n=20):
        sp.add_argument('--limit', type=int, default=n)
        sp.add_argument('--all', action='store_true')
        sp.add_argument('--from', dest='start', type=int, default=0, help='first item (the `next` cursor)')
        sp.add_argument('--json', action='store_true')
    s = sub.add_parser('summary'); s.add_argument('file'); lim(s, 10); s.set_defaults(fn=cmd_summary)
    s = sub.add_parser('modules'); s.add_argument('file'); s.add_argument('--depth', type=int, default=4)
    s.add_argument('--under'); lim(s); s.set_defaults(fn=cmd_modules)
    s = sub.add_parser('location'); s.add_argument('file'); s.add_argument('name'); lim(s); s.set_defaults(fn=cmd_location)
    s = sub.add_parser('compare'); s.add_argument('a'); s.add_argument('b'); s.add_argument('--depth', type=int, default=4)
    s.add_argument('--under'); lim(s); s.set_defaults(fn=cmd_compare)
    for v in ('congestion', 'route', 'fanout'):
        s = sub.add_parser(v); s.add_argument('rest', nargs='*'); lim(s); s.set_defaults(fn=cmd_unsupported)
    return p.parse_args(argv)


if __name__ == '__main__':
    sys.exit(timing.run(sys.argv[1:], area='place', parser=parse, doc=__doc__))
