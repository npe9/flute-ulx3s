#!/usr/bin/env python3
"""hw timing: nextpnr timing results as small records (hwsh CONTRACT.md).  Read-only.

  hw timing summary FILE... [--limit N|--all]   per file: routed Fmax per clock vs target, margin, utilisation;
                                                several files (seeds) also get a band per clock
  hw timing worst FILE [--clock C] [--limit N]   the critical path of each clock / clock pair, worst slack first
  hw timing path ID [--hops N]                   one path: endpoints, logic vs routing, LUT levels, module chain,
                                                the longest wires, design source lines, rule names seen
  hw timing compare A B                          Fmax per clock, utilisation and critical endpoints, A -> B
  hw expand tpath:ID [--from K] [--limit N]      every hop of a path (bounded)
  hw raw pnrlog:SHA12:LA-B                       a slice of the log (bounded)

FILE is a nextpnr text log (`nextpnr-ecp5 ... > pnr.log 2>&1`) or a `--report` JSON.
Only the post-ROUTE block of a log is an Fmax (AGENTS.md rule 7).  A log that never routed
(killed, --no-route) answers with its placement estimate marked `complete: false`, exit 5.
A routed clock below its target is `status: fail`, exit 1.  A PASS with < 5% margin is flagged
`thin` (rule 7: not hardware margin).  Answers are cached by file content (`cached`).
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.environ.get('HWSH_LIB', os.path.expanduser('~/src/hwsh/lib')))
sys.path.insert(0, HERE)
from hwout import HwError, bounded, emit  # noqa: E402
import common  # noqa: E402
import pnr  # noqa: E402

THIN = 5.0     # percent; AGENTS.md rule 7


def label(path):
    try:
        r = os.path.relpath(path)
    except ValueError:
        r = path
    return r if not r.startswith('../../') else path


def open_file(path):
    if not os.path.exists(path):
        raise HwError('HW-E-NOT-FOUND', 'no such file: %s' % path, 'a nextpnr log or --report JSON')
    try:
        return pnr.load(path)
    except ValueError as e:
        raise HwError('HW-E-TIMING-FORMAT', '%s: %s' % (path, e), 'pass the nextpnr log (stdout+stderr) or --report JSON')


def margin(f):
    return round(100.0 * (f['mhz'] - f['target_mhz']) / f['target_mhz'], 1)


def util_short(rec):
    out = {}
    for long, short in pnr.SHORT:
        u = rec['util'].get(long)
        if u and u['available']:
            out[short] = {'used': u['used'], 'available': u['available'],
                          'pct': round(100.0 * u['used'] / u['available'], 1)}
    return out


def page(items, a):
    """Rule 1: bounded, and `next` is a flag this same verb accepts (`--from N`)."""
    start = getattr(a, 'start', 0) or 0
    return bounded(list(items)[start:], a.limit, a.all, cursor=lambda i: '--from %d' % (start + i))


def file_summary(path):
    rec, cached = open_file(path)
    stage, st, complete = pnr.final_stage(rec)
    clocks = []
    for f in st['fmax']:
        c = {'clock': f['clock'], 'mhz': f['mhz'], 'target_mhz': f['target_mhz'], 'verdict': f['verdict'],
             'margin_pct': margin(f), 'line': f['line']}
        c['thin'] = f['verdict'] == 'PASS' and c['margin_pct'] < THIN
        clocks.append(c)
    other = [e for e in rec['errors'] if not e['message'].startswith('Max frequency')]
    out = {'file': label(path), 'sha12': rec['sha12'], 'stage': stage, 'complete': complete,
           'tool_version': rec.get('version'), 'clocks': clocks, 'util': util_short(rec),
           'errors': other[:5], 'finished': rec['finished']}
    if rec['kind'] == 'report':
        out['assumptions'] = 'a --report JSON does not say whether routing ran; read as the final result'
    return out, cached, rec


def fmt_clock(c):
    s = '%s %.2f MHz %s@%g (%+.1f%%)' % (c['clock'], c['mhz'], c['verdict'], c['target_mhz'], c['margin_pct'])
    return s + (' THIN' if c['thin'] else '')


def fmt_util(u):
    return ' '.join('%s %g%%' % (k, v['pct']) for k, v in u.items() if k in ('LUT4', 'FF', 'EBR', 'DSP'))


def cmd_summary(a):
    rows, cached_all, metrics, recs = [], True, [], []
    for p in a.files:
        s, cached, rec = file_summary(p)
        rows.append(s)
        recs.append(rec)
        cached_all &= cached
        if s['complete']:
            for c in s['clocks']:
                metrics.append({'name': 'fmax', 'value': c['mhz'], 'unit': 'MHz', 'object': 'clock:' + c['clock']})
    shown, more = page(rows, a)
    lines = []
    for s in shown:
        head = '%s %s' % (s['file'], s['stage'] if s['complete'] else 'NOT ROUTED (placement estimate only)')
        lines.append('%s: %s ; %s' % (head, ' | '.join(fmt_clock(c) for c in s['clocks']) or 'no fmax lines',
                                     fmt_util(s['util'])))
        for e in s['errors']:
            lines.append('  error line %d: %s' % (e['line'], e['message'][:160]))
        if not s['finished'] and s['stage'] != 'report':
            lines.append('  log does not end with "Program finished normally" (killed or still running?)')
    band = {}
    for s in rows:
        if not s['complete']:
            continue
        for c in s['clocks']:
            b = band.setdefault(c['clock'], {'mhz': [], 'pass': 0, 'fail': 0, 'target_mhz': c['target_mhz']})
            b['mhz'].append(c['mhz'])
            b['pass' if c['verdict'] == 'PASS' else 'fail'] += 1
    bands = []
    if len(rows) > 1:
        for clk, b in band.items():
            m = b['mhz']
            bands.append({'clock': clk, 'n': len(m), 'min': min(m), 'mean': round(sum(m) / len(m), 2), 'max': max(m),
                          'target_mhz': b['target_mhz'], 'pass': b['pass'], 'fail': b['fail']})
            lines.append('band %s over %d routed: min %.2f mean %.2f max %.2f MHz (target %g): %d pass, %d fail'
                         % (clk, len(m), min(m), sum(m) / len(m), max(m), b['target_mhz'], b['pass'], b['fail']))
    failing = [s['file'] for s in rows if s['complete'] and any(c['verdict'] == 'FAIL' for c in s['clocks'])]
    incomplete = [s['file'] for s in rows if not s['complete']]
    res = {'cmd': 'timing summary', 'files': shown, 'bands': bands, 'cached': cached_all,
           'status': 'fail' if failing else 'ok', 'failing': failing, 'not_routed': incomplete, **more,
           '_inputs': list(a.files), '_tool': 'nextpnr-ecp5', '_tool_version': recs[0].get('version'),
           '_metrics': metrics if len(a.files) == 1 else []}
    if incomplete:
        res['complete'] = False
    return dict(res, lines=lines)


# ---------------------------------------------------------------- paths
def common_prefix(names):
    parts = [n.split('.')[:-1] for n in names if '.' in n]
    if not parts:
        return ''
    pre = []
    for col in zip(*parts):
        if all(c == col[0] for c in col):
            pre.append(col[0])
        else:
            break
    return '.'.join(pre)


def rel(n, pre):
    return n[len(pre) + 1:] if pre and n.startswith(pre + '.') else n


def path_record(rec, st, k, p, nhops=3):
    hops = p['hops']
    names = [pnr.collapse(h['name']) for h in hops]
    sinks = [pnr.collapse(h['sink']) for h in hops if h.get('sink')]
    pre = common_prefix(names + sinks)
    delay = hops[-1]['total'] if hops else 0.0
    target = next((f['target_mhz'] for f in st['fmax'] if p['clock'] and f['clock'] == p['clock']), None)
    chain = []
    for n in names:
        m = rel(pnr.module_of(n), pre) if pnr.module_of(n) != pre else '.'
        if m not in chain:          # first-seen order; a path re-enters modules, the set is what matters
            chain.append(m)
    wires = sorted((h for h in hops if h['type'] == 'routing'), key=lambda h: -h['ns'])[:nhops]
    wl = []
    for h in wires:
        w = {'ns': h['ns'], 'net': rel(pnr.collapse(h['name']), pre)}
        if h.get('xy'):
            x0, y0, x1, y1 = h['xy']
            w.update({'from': [x0, y0], 'to': [x1, y1], 'dist': abs(x1 - x0) + abs(y1 - y0)})
        wl.append(w)
    design_src, lost = [], 0
    for h in hops:
        srcs = h.get('src') or []
        real = [s for s in srcs if not any(x in s['file'] for x in pnr.LIB_SRC)]
        if srcs and not real:
            lost += 1
        for s in real:
            if s not in design_src:
                design_src.append(s)
    logic = p.get('logic_ns')
    route = p.get('routing_ns')
    if logic is None:
        logic = round(sum(h['ns'] for h in hops if h['type'] != 'routing'), 2)
        route = round(sum(h['ns'] for h in hops if h['type'] == 'routing'), 2)
    out = {'id': 'tpath:%s.%d' % (rec['sha12'], k), 'clock': p['clock'], 'from_clk': p['from_clk'],
           'to_clk': p['to_clk'], 'ns': delay, 'logic_ns': logic, 'routing_ns': route,
           'routing_pct': round(100.0 * route / delay, 0) if delay else None,
           'luts': sum(1 for h in hops if h['type'] == 'logic'), 'hops': len(hops), 'in': pre,
           'from': rel(names[0], pre) if names else None, 'to': rel(names[-1], pre) if names else None,
           'modules': chain, 'longest_wires': wl,
           'src': [{'loc': s, 'via': [{'tool': 'yosys', 'loc': s}]} for s in design_src[:3]],
           'rules': pnr.rule_hints([h['name'] for h in hops] + [h.get('sink', '') for h in hops]),
           'provenance': ('Verilog only: no bsc Verilog->BSV map yet' if design_src else
                          'lost: every hop is a yosys/nextpnr library cell'),
           'raw_ref': ('pnrlog:%s:L%d-%d' % (rec['sha12'], p['line_from'], p['line_to'])
                       if p.get('line_from') else None)}
    if target:
        out['slack_ns'] = round(1000.0 / target - delay, 2)
        out['target_mhz'] = target
    return out


def fmt_path(r, wires=True):
    clk = r['clock'] or '%s -> %s' % (r['from_clk'], r['to_clk'])
    s = '%s %s %.2f ns%s: %.2f logic / %.2f route (%d%%), %d LUT levels' % (
        r['id'], clk, r['ns'], ' (slack %+.2f)' % r['slack_ns'] if 'slack_ns' in r else '',
        r['logic_ns'], r['routing_ns'], r['routing_pct'] or 0, r['luts'])
    out = [s, '  in %s: %s -> %s' % (r['in'] or '(top)', r['from'], r['to'])]
    if len(r['modules']) > 1:
        out.append('  via ' + ' > '.join(r['modules']))
    if wires and r['longest_wires']:
        out.append('  longest wires: ' + '; '.join(
            '%.2f %s %s->%s' % (w['ns'], w['net'], tuple(w['from']), tuple(w['to'])) if 'from' in w
            else '%.2f %s' % (w['ns'], w['net']) for w in r['longest_wires']))
    if r['rules']:
        out.append('  rules: ' + ', '.join('%s (%s in %s)' % (x['rule'], x['via'], x['inst']) for x in r['rules']))
    if r['src']:
        out.append('  src: ' + ', '.join('%s:%d' % (x['loc']['file'], x['loc']['line']) for x in r['src']))
    return out


def stage_paths(path):
    rec, cached = open_file(path)
    stage, st, complete = pnr.final_stage(rec)
    return rec, cached, stage, st, complete


def cmd_worst(a):
    rec, cached, stage, st, complete = stage_paths(a.file)
    recs = [path_record(rec, st, k, p) for k, p in enumerate(st['paths'])]
    if a.clock:
        recs = [r for r in recs if a.clock in (r['clock'] or '') or
                (a.cross and r['clock'] is None and a.clock in (r['from_clk'], r['to_clk']))]
        if not recs:
            raise HwError('HW-E-NOT-FOUND', 'no critical path for clock matching `%s`' % a.clock,
                          'clocks here: %s' % ', '.join(sorted({p['from_clk'] for p in st['paths']})))
    recs.sort(key=lambda r: (r.get('slack_ns') is None, r.get('slack_ns', 0), -r['ns']))
    shown, more = page(recs, a)
    lines = [] if complete else ['NOT ROUTED: placement-estimate paths (%s)' % label(a.file)]
    for r in shown:
        lines += fmt_path(r, wires=False)
    res = {'cmd': 'timing worst', 'file': label(a.file), 'stage': stage, 'paths': shown, 'cached': cached, **more}
    if not complete:
        res['complete'] = False
    return dict(res, lines=lines)


def find_path(pid):
    try:
        sha12, k = pid.split(':', 1)[1].split('.')
        k = int(k)
    except (IndexError, ValueError):
        raise HwError('HW-E-BADREQ', 'bad path id `%s`' % pid, 'ids look like tpath:<sha12>.<n> (from hw timing worst)')
    path = pnr.resolve(sha12)
    if not path:
        raise HwError('HW-E-NOT-FOUND', 'no file with content %s in the timing cache' % sha12,
                      'the file changed or moved; run hw timing worst FILE again for fresh ids')
    rec, cached, stage, st, complete = stage_paths(path)
    if not 0 <= k < len(st['paths']):
        raise HwError('HW-E-NOT-FOUND', '%s has %d paths, no #%d' % (label(path), len(st['paths']), k))
    return rec, cached, stage, st, complete, k, path


def cmd_path(a):
    rec, cached, stage, st, complete, k, path = find_path(a.id)
    r = path_record(rec, st, k, st['paths'][k], a.hops)
    lines = fmt_path(r)
    lines.append('  provenance: %s; full hops: hw expand %s%s' % (
        r['provenance'], r['id'], '; raw: hw raw ' + r['raw_ref'] if r['raw_ref'] else ''))
    res = {'cmd': 'timing path', 'file': label(path), 'stage': stage, 'path': r, 'cached': cached}
    if not complete:
        res['complete'] = False
    return dict(res, lines=lines)


def cmd_expand(a):
    rec, cached, stage, st, complete, k, path = find_path(a.id)
    p = st['paths'][k]
    pre = common_prefix([pnr.collapse(h['name']) for h in p['hops']])
    hops = []
    for h in p['hops']:
        x = {'type': h['type'], 'ns': h['ns'], 'total': h['total'], 'name': rel(pnr.collapse(h['name']), pre),
             'raw_name': h['name']}
        if h.get('xy'):
            x['xy'] = h['xy']
        real = [s for s in h.get('src') or [] if not any(y in s['file'] for y in pnr.LIB_SRC)]
        if real:
            x['src'] = real
        hops.append(x)
    shown, more = page(hops, a)
    lines = ['%s in %s (%d hops)' % (a.id, pre or '(top)', len(p['hops']))]
    for h in shown:
        lines.append('  %-8s %5.2f %6.2f %s%s%s' % (h['type'], h['ns'], h['total'], h['name'],
                     ' (%d,%d)->(%d,%d)' % tuple(h['xy']) if 'xy' in h else '',
                     ' @%s:%d' % (h['src'][0]['file'], h['src'][0]['line']) if 'src' in h else ''))
    res = {'cmd': 'timing expand', 'id': a.id, 'in': pre, 'hops': shown, 'cached': cached, **more}
    for h in res['hops']:
        h.pop('raw_name', None) if not a.raw_names else None
    return dict(res, lines=lines)


def cmd_raw(a):
    try:
        _, sha12, rng = a.ref.split(':', 2)
        lo, hi = (int(x) for x in rng.lstrip('L').split('-'))
    except ValueError:
        raise HwError('HW-E-BADREQ', 'bad raw ref `%s`' % a.ref, 'refs look like pnrlog:<sha12>:L<a>-<b>')
    path = pnr.resolve(sha12)
    if not path:
        raise HwError('HW-E-NOT-FOUND', 'no file with content %s in the timing cache' % sha12,
                      'run hw timing worst FILE again')
    lines = open(path, errors='replace').read().split('\n')[lo - 1:hi]
    shown, more = bounded(lines, a.limit, a.all, cursor=lambda i: 'pnrlog:%s:L%d-%d' % (sha12, lo + i, hi))
    cut = [l[:a.width] + ('...' if len(l) > a.width else '') for l in shown]
    return {'cmd': 'timing raw', 'ref': a.ref, 'file': label(path), 'text': cut, 'lines': cut, 'cached': True, **more}


def cmd_compare(a):
    sa, ca, ra = file_summary(a.a)
    sb, cb, rb = file_summary(a.b)
    lines = ['%s (%s) -> %s (%s)' % (sa['file'], sa['stage'], sb['file'], sb['stage'])]
    clocks = []
    cmap = {c['clock']: c for c in sa['clocks']}
    for c in sb['clocks']:
        o = cmap.pop(c['clock'], None)
        d = {'clock': c['clock'], 'a_mhz': o and o['mhz'], 'b_mhz': c['mhz'],
             'delta_mhz': round(c['mhz'] - o['mhz'], 2) if o else None, 'b_verdict': c['verdict'],
             'a_verdict': o and o['verdict']}
        clocks.append(d)
        lines.append('  %s: %s -> %.2f MHz (%s)%s' % (c['clock'], '%.2f' % o['mhz'] if o else 'absent', c['mhz'],
                                                     '%+.2f' % d['delta_mhz'] if o else 'new', '' if not o or
                                                     o['verdict'] == c['verdict'] else ' %s -> %s' % (o['verdict'], c['verdict'])))
    for c in cmap.values():
        clocks.append({'clock': c['clock'], 'a_mhz': c['mhz'], 'b_mhz': None, 'delta_mhz': None})
        lines.append('  %s: %.2f MHz -> absent' % (c['clock'], c['mhz']))
    util = {}
    for k in set(sa['util']) | set(sb['util']):
        ua, ub = sa['util'].get(k, {}).get('used'), sb['util'].get(k, {}).get('used')
        if ua != ub:
            util[k] = {'a': ua, 'b': ub, 'delta': (ub or 0) - (ua or 0)}
    if util:
        lines.append('  util: ' + ', '.join('%s %s->%s (%+d)' % (k, v['a'], v['b'], v['delta']) for k, v in sorted(util.items())))
    ends = []
    _, sta, _ = pnr.final_stage(ra)
    _, stb, _ = pnr.final_stage(rb)
    pa = {(p['from_clk'], p['to_clk']): path_record(ra, sta, k, p) for k, p in enumerate(sta['paths'])}
    for k, p in enumerate(stb['paths']):
        r = path_record(rb, stb, k, p)
        o = pa.get((p['from_clk'], p['to_clk']))
        if p['clock'] is None:
            continue
        same = o is not None and (o['in'], o['from'], o['to']) == (r['in'], r['from'], r['to'])
        ends.append({'clock': p['clock'], 'same_endpoints': same, 'a': o and o['id'], 'b': r['id'],
                     'a_ns': o and o['ns'], 'b_ns': r['ns']})
        lines.append('  critical %s: %s%s' % (p['clock'], 'same endpoints' if same else 'MOVED',
                                              '' if same or not o else ' (%s -> %s ; %s -> %s)' % (
                                                  o['from'], o['to'], r['from'], r['to'])))
    res = {'cmd': 'timing compare', 'a': sa['file'], 'b': sb['file'], 'clocks': clocks, 'util': util,
           'critical': ends, 'cached': ca and cb}
    if not (sa['complete'] and sb['complete']):
        res['complete'] = False
        lines.append('  NOTE: %s not routed; its numbers are placement estimates' %
                     ' and '.join(s['file'] for s in (sa, sb) if not s['complete']))
    return dict(res, lines=lines)


def parse(argv):
    p = common.Parser(prog='hw timing', add_help=False)
    p.add_argument('--json', action='store_true')
    sub = p.add_subparsers(dest='verb', required=True, parser_class=common.Parser)

    def lim(sp, n=20):
        sp.add_argument('--limit', type=int, default=n)
        sp.add_argument('--all', action='store_true')
        sp.add_argument('--from', dest='start', type=int, default=0, help='first item (the `next` cursor)')
        sp.add_argument('--json', action='store_true')
    s = sub.add_parser('summary'); s.add_argument('files', nargs='+'); lim(s); s.set_defaults(fn=cmd_summary)
    s = sub.add_parser('worst'); s.add_argument('file'); s.add_argument('--clock')
    s.add_argument('--cross', action='store_true', help='with --clock: also the cross-domain paths into/out of it'); lim(s); s.set_defaults(fn=cmd_worst)
    for v in ('path', 'explain'):
        s = sub.add_parser(v); s.add_argument('id'); s.add_argument('--hops', type=int, default=3); lim(s)
        s.set_defaults(fn=cmd_path)
    s = sub.add_parser('expand'); s.add_argument('id')
    s.add_argument('--depth', type=int); s.add_argument('--raw-names', action='store_true'); lim(s, 30)
    s.set_defaults(fn=cmd_expand)
    s = sub.add_parser('raw'); s.add_argument('ref'); s.add_argument('--width', type=int, default=160); lim(s, 40)
    s.set_defaults(fn=cmd_raw)
    s = sub.add_parser('compare'); s.add_argument('a'); s.add_argument('b'); lim(s); s.set_defaults(fn=cmd_compare)
    return p.parse_args(argv)


def run(argv, area='timing', parser=None, doc=None):
    """Contract exits: 0 ok, 1 fail, 5 incomplete, 2/3/4 errors.  Records to hw state with HW_PROJECT."""
    if not argv or argv[0] in ('-h', '--help', 'help'):
        print((doc or __doc__).strip())
        return 0
    json_out = '--json' in argv
    t0 = time.time()
    try:
        a = (parser or parse)(argv)
        res = a.fn(a)
        res.setdefault('status', 'ok')
        res.setdefault('cached', False)
        rc = 1 if res['status'] == 'fail' else (5 if res.get('complete') is False else 0)
    except HwError as e:
        res = {'status': 'error', 'code': e.code, 'reason': e.reason, 'hint': e.hint, 'cached': False}
        rc = common.EXIT.get(e.code, 3)
    except OSError as e:
        res, rc = {'status': 'error', 'code': 'HW-E-IO', 'reason': str(e), 'cached': False}, 3
    except Exception as e:  # noqa: BLE001 - never a traceback
        res, rc = {'status': 'error', 'code': 'HW-E-INTERNAL', 'reason': '%s: %s' % (type(e).__name__, e),
                   'cached': False}, 4
    res.setdefault('cmd', area or 'perf')
    if area:
        common.record(area, argv, res, time.time() - t0)
    for k in [k for k in res if k.startswith('_')]:
        res.pop(k)
    emit(res, json_out)
    return rc


if __name__ == '__main__':
    sys.exit(run(sys.argv[1:]))
