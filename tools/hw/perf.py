#!/usr/bin/env python3
"""hw perf: Fmax / utilisation / CoreMark / Dhrystone across builds, from the artifacts (hwsh CONTRACT.md).

  hw perf record FILE... [--build NAME]    ingest nextpnr logs and bench logs into <project>/.hw/state.db
                                            (one run per file; a file already recorded is skipped: `cached`)
  hw perf seed [--root DIR]                record every build/*/pnr-s*.log and build/bench/*-{coremark,dhrystone}.log
  hw perf show [--builds RE] [--sort KEY]  one line per build: sys_clk band over seeds, LUT%, CM/MHz, DMIPS/MHz
  hw perf compare A B                      every metric of build A vs build B (seed bands for Fmax)
  hw perf history METRIC [--object O]      a metric over time (by the artifact's mtime), e.g. fmax --object clock:sys_clk

Numbers come only from artifact files (each recorded with its sha256), never from notes.  The
build name is the log's directory (build/lx49c/pnr-s3.log -> lx49c, seed 3); bench logs are
build/bench/<build>-<bench>.log.  Only routed logs give an Fmax; a placed-only log is recorded as
incomplete and left out of the bands.  Project: $HW_PROJECT, else this repository.
"""
import inspect
import json
import os
import re
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.environ.get('HW_ROOT') or os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.environ.get('HWSH_LIB', os.path.expanduser('~/src/hwsh/lib')))
sys.path.insert(0, HERE)
from hwout import HwError, bounded  # noqa: E402
import common  # noqa: E402
import pnr  # noqa: E402
import timing  # noqa: E402

try:
    import hwstate  # noqa: E402
except ImportError:  # pragma: no cover
    hwstate = None

SEEDED = 'seeded from an existing artifact; the commit it was built from is unknown'


def project():
    return os.environ.get('HW_PROJECT') or ROOT


def db():
    if hwstate is None:
        raise HwError('HW-E-NO-BACKEND', 'hwstate library not found', 'set HWSH_LIB to ~/src/hwsh/lib')
    return hwstate.connect(project())


def classify(path):
    """-> (kind, build, variant) from the file name and first bytes."""
    p = os.path.abspath(path)
    base = os.path.basename(p)
    m = re.match(r'(.+)-(coremark|dhrystone)\.log$', base)
    if m:
        return 'bench', m.group(1), m.group(2)
    with open(p, 'rb') as fh:
        head = fh.read(4096)
    if (b'nextpnr' in head or b'Next Generation Place and Route' in head or b'Info: constraining clock net' in head
            or b'Info: Logic utilisation before packing' in head or head.lstrip().startswith(b'{"critical_paths"')):
        m = re.match(r'pnr-(.+?)\.(?:log|json)$', base)
        return 'pnr', os.path.basename(os.path.dirname(p)), m.group(1) if m else base
    raise HwError('HW-E-PERF-FORMAT', '%s is neither a nextpnr log nor a <build>-<bench>.log' % path,
                  'hw perf record build/<b>/pnr-s<N>.log build/bench/<b>-coremark.log')


def bench_metrics(path):
    text = open(path, errors='replace').read()
    mets, checks = [], []
    mhz = re.findall(r'at (\d+(?:\.\d+)?) MHz', text)
    clock = float(mhz[-1]) if mhz else None
    m = re.findall(r'Iterations/Sec\s*:\s*([\d.]+)', text)
    if m:
        mets.append({'name': 'coremark_its', 'value': float(m[-1]), 'unit': 'it/s'})
        if clock:
            mets.append({'name': 'coremark_per_mhz', 'value': round(float(m[-1]) / clock, 4), 'unit': 'CM/MHz'})
    m = re.findall(r'Cycles per Dhrystone:\s*([\d.]+)', text)
    if m:
        mets.append({'name': 'dhrystone_cycles', 'value': float(m[-1]), 'unit': 'cycles/run'})
    m = re.findall(r'DMIPS/MHz:\s*([\d.]+)', text)
    if m:
        mets.append({'name': 'dmips_per_mhz', 'value': float(m[-1]), 'unit': 'DMIPS/MHz'})
    runs = re.findall(r'BENCH (\S+) cycles=(\d+) instret=(\d+)', text)
    if runs:
        name, cyc, ins = runs[-1]
        mets.append({'name': 'cycles', 'value': int(cyc), 'unit': 'cycles', 'object': 'bench:' + name})
        mets.append({'name': 'ipc', 'value': round(int(ins) / int(cyc), 4), 'unit': 'IPC', 'object': 'bench:' + name})
    ok = ('Correct operation validated' in text) or ('BENCH-CHECK OK' in text)
    bad = 'BENCH-CHECK FAIL' in text or 'ERROR' in text
    checks.append({'name': 'self-check', 'status': 'fail' if bad else ('pass' if ok else 'inconclusive'),
                   'expected': 'Correct operation validated / BENCH-CHECK OK', 'observed': 'present' if ok else 'absent'})
    return mets, checks, clock


def already(c, path, build, variant):
    s = pnr.sha256(path)
    r = c.execute("select r.run_id from artifacts a join runs r using(run_id) join experiments e using(run_id) "
                  "where a.sha256 = ? and a.kind = 'input' and r.area = 'perf' and r.verb = 'record' "
                  "and e.name = ? and e.variant = ?", (s, build, variant)).fetchone()
    return r[0] if r else None


def record_one(c, path, build=None, who=None):
    kind, b, variant = classify(path)
    b = build or b
    rid = already(c, path, b, variant)
    if rid:
        return {'file': timing.label(path), 'build': b, 'variant': variant, 'kind': kind, 'run': rid, 'cached': True}
    started = os.path.getmtime(path)
    if kind == 'pnr':
        rec, _ = pnr.load(path)
        stage, st, complete = pnr.final_stage(rec)
        mets = [{'name': 'fmax', 'value': f['mhz'], 'unit': 'MHz', 'object': 'clock:' + f['clock']}
                for f in st['fmax']] if complete else []
        for long, short in pnr.SHORT[:4]:
            u = rec['util'].get(long)
            if u and u['available']:
                mets.append({'name': 'util_' + short, 'value': u['used'], 'unit': 'cells', 'object': None})
                mets.append({'name': 'util_%s_pct' % short, 'value': round(100.0 * u['used'] / u['available'], 1),
                             'unit': '%', 'object': None})
        # the import is the answer (status ok); each clock's verdict is a check, so a failing old seed
        # does not show up in `hw state failures` as if the recording had failed
        status = 'ok'
        summary = (' '.join('%s %.2f%s' % (f['clock'], f['mhz'], '' if f['verdict'] == 'PASS' else ' FAIL')
                            for f in st['fmax']) if complete else 'not routed (placement estimate only)')
        tool, ver = 'nextpnr-ecp5', rec.get('version')
        checks = [{'name': 'fmax ' + f['clock'], 'status': 'pass' if f['verdict'] == 'PASS' else 'fail',
                   'expected': '>= %g MHz' % f['target_mhz'], 'observed': '%.2f MHz' % f['mhz']}
                  for f in st['fmax']] if complete else []
        answer = {'status': status, 'lines': [summary], 'complete': complete, 'cmd': 'perf record'}
    else:
        mets, checks, clock = bench_metrics(path)
        status = 'ok'
        complete = bool(mets)
        summary = ' '.join('%s %g' % (m['name'], m['value']) for m in mets
                           if m['name'] in ('coremark_per_mhz', 'dmips_per_mhz', 'dhrystone_cycles'))
        tool, ver = variant, None
        answer = {'status': status, 'lines': [summary], 'complete': complete, 'cmd': 'perf record'}
    if 'git_rev' not in inspect.signature(hwstate.record).parameters:
        raise HwError('HW-E-NO-BACKEND', 'hwstate.record() has no git_rev override',
                      'update ~/src/hwsh/lib/hwstate.py (seeded runs must not claim the current commit)')
    answer['lines'] = ['%s %s: %s' % (b, variant, summary)]
    rid = hwstate.record(project(), 'perf', 'record', ['record', path], answer, inputs=[path], tool=tool,
                         tool_version=ver, metrics=mets, checks=checks, assumptions=SEEDED, who=who,
                         started=started, experiment=(b, variant), git_rev=None, dirty=None)
    return {'file': timing.label(path), 'build': b, 'variant': variant, 'kind': kind, 'run': rid, 'cached': False,
            'status': status, 'complete': complete, 'summary': summary}


def cmd_record(a, files=None):
    seeding = files is not None
    files = files or a.files
    c = db()
    out, skipped = [], []
    try:
        for f in files:
            if not os.path.exists(f):
                raise HwError('HW-E-NOT-FOUND', 'no such file: %s' % f)
            try:
                out.append(record_one(c, f, getattr(a, 'build', None)))
            except HwError as e:
                if not seeding:
                    raise
                skipped.append({'file': timing.label(f), 'code': e.code, 'reason': e.reason})
    finally:
        c.close()
    new = [r for r in out if not r['cached']]
    shown, more = timing.page(out, a)
    lines = ['recorded %d new, %d already in %s' % (len(new), len(out) - len(new),
                                                     os.path.join(project(), '.hw/state.db'))]
    lines += ['  %s %s %s%s' % (r['build'], r['variant'], 'already recorded' if r['cached'] else r['summary'],
                                '' if r['cached'] or r['complete'] else ' (INCOMPLETE)') for r in shown if not r['cached']][:a.limit]
    lines += ['  skipped %s: %s' % (s['file'], s['reason']) for s in skipped[:5]]
    return dict(cmd='perf record', recorded=shown, new=len(new), skipped=skipped, cached=not new, lines=lines, **more)


def cmd_seed(a):
    root = a.root or ROOT
    import glob
    files = sorted(glob.glob(os.path.join(root, 'build', '*', 'pnr-s*.log')))
    files += sorted(glob.glob(os.path.join(root, 'build', 'bench', '*-coremark.log')))
    files += sorted(glob.glob(os.path.join(root, 'build', 'bench', '*-dhrystone.log')))
    if not files:
        raise HwError('HW-E-NOT-FOUND', 'no build/*/pnr-s*.log or build/bench/*.log under %s' % root)
    return dict(cmd_record(a, files), cmd='perf seed')


# ---------------------------------------------------------------- queries
def table(c):
    rows = c.execute("""select e.name, e.variant, m.name, m.value, m.object, r.complete, r.started from experiments e
                        join runs r using(run_id) join metrics m using(run_id)
                        where r.area = 'perf' and r.verb = 'record'""").fetchall()
    builds = {}
    for b, v, n, x, o, comp, started in rows:
        bb = builds.setdefault(b, {'build': b, 'seeds': {}, 'bench': {}, 'util': {}, 'when': 0})
        bb['when'] = max(bb['when'], started)
        if n == 'fmax':
            bb['seeds'].setdefault(o.split(':', 1)[1], {})[v] = x
        elif n.startswith('util_'):
            bb['util'][n[5:]] = x
        else:
            bb['bench'][n if not o else '%s@%s' % (n, o)] = x
    # incomplete (placed-only) logs: count them so a missing seed is visible
    for b, v in c.execute("""select e.name, e.variant from experiments e join runs r using(run_id)
                             where r.area = 'perf' and r.complete = 0 and e.variant like 's%'""").fetchall():
        builds.setdefault(b, {'build': b, 'seeds': {}, 'bench': {}, 'util': {}, 'when': 0}).setdefault('unrouted', []).append(v)
    return builds


def band(seeds):
    v = list(seeds.values())
    return {'n': len(v), 'min': min(v), 'mean': round(sum(v) / len(v), 2), 'max': max(v),
            'by_seed': dict(sorted(seeds.items()))} if v else None


def build_row(bb, clock):
    r = {'build': bb['build'], 'when': bb['when'], 'fmax': band(bb['seeds'].get(clock, {})),
         'lut_pct': bb['util'].get('LUT4_pct'), 'ff_pct': bb['util'].get('FF_pct'),
         'coremark_per_mhz': bb['bench'].get('coremark_per_mhz'), 'dmips_per_mhz': bb['bench'].get('dmips_per_mhz'),
         'unrouted': bb.get('unrouted', [])}
    return r


def fmt_row(r, clock):
    f = r['fmax']
    s = '%-10s %s' % (r['build'], '%s %.2f/%.2f/%.2f (n=%d)' % (clock, f['min'], f['mean'], f['max'], f['n']) if f
                      else '%s -' % clock)
    if r['lut_pct'] is not None:
        s += '  LUT %g%%' % r['lut_pct']
    if r['coremark_per_mhz'] is not None:
        s += '  CM/MHz %g' % r['coremark_per_mhz']
    if r['dmips_per_mhz'] is not None:
        s += '  DMIPS/MHz %g' % r['dmips_per_mhz']
    if r['unrouted']:
        s += '  unrouted: %s' % ','.join(r['unrouted'])
    return s


def cmd_show(a):
    c = db()
    try:
        builds = table(c)
    finally:
        c.close()
    if not builds:
        raise HwError('HW-E-NOT-FOUND', 'no perf runs recorded in %s' % project(), 'hw perf seed')
    rows = [build_row(b, a.clock) for b in builds.values() if not a.builds or re.search(a.builds, b['build'])]
    key = {'when': lambda r: -r['when'], 'fmax': lambda r: -(r['fmax']['mean'] if r['fmax'] else 0),
           'name': lambda r: r['build']}[a.sort]
    rows.sort(key=key)
    shown, more = timing.page(rows, a)
    lines = ['%d builds (%s; fmax min/mean/max over routed seeds, MHz)' % (len(rows), 'newest first' if a.sort == 'when'
                                                                          else 'by ' + a.sort)]
    lines += [fmt_row(r, a.clock) for r in shown]
    return dict(cmd='perf show', clock=a.clock, builds=shown, cached=True, lines=lines, **more)


def cmd_compare(a):
    c = db()
    try:
        builds = table(c)
    finally:
        c.close()
    for b in (a.a, a.b):
        if b not in builds:
            raise HwError('HW-E-NOT-FOUND', 'no build `%s` recorded' % b, 'hw perf show lists them; hw perf record FILE adds one')
    A, B = builds[a.a], builds[a.b]
    out, lines = [], ['%s -> %s' % (a.a, a.b)]
    for clk in sorted(set(A['seeds']) | set(B['seeds'])):
        ba, bb = band(A['seeds'].get(clk, {})), band(B['seeds'].get(clk, {}))
        d = {'metric': 'fmax', 'object': 'clock:' + clk, 'a': ba, 'b': bb,
             'delta_mean': round(bb['mean'] - ba['mean'], 2) if ba and bb else None}
        out.append(d)
        lines.append('  fmax %s: %s -> %s%s' % (
            clk, '%.2f/%.2f/%.2f' % (ba['min'], ba['mean'], ba['max']) if ba else '-',
            '%.2f/%.2f/%.2f' % (bb['min'], bb['mean'], bb['max']) if bb else '-',
            ' (mean %+.2f)' % d['delta_mean'] if d['delta_mean'] is not None else ''))
    for grp in ('util', 'bench'):
        for k in sorted(set(A[grp]) | set(B[grp])):
            va, vb = A[grp].get(k), B[grp].get(k)
            out.append({'metric': k, 'a': va, 'b': vb, 'delta': round(vb - va, 4) if va is not None and vb is not None else None})
            if va != vb:
                g = lambda x: '-' if x is None else '%g' % x
                lines.append('  %s: %s -> %s%s' % (k, g(va), g(vb), ' (%+g)' % (vb - va) if va is not None and vb is not None else ''))
    same = [k for k in sorted(set(A['util']) | set(A['bench'])) if A['util'].get(k, A['bench'].get(k)) ==
            B['util'].get(k, B['bench'].get(k))]
    if same:
        lines.append('  unchanged: ' + ', '.join(same))
    return dict(cmd='perf compare', a=a.a, b=a.b, metrics=out, cached=True, lines=lines)


def cmd_history(a):
    c = db()
    try:
        q = """select e.name, e.variant, m.value, m.unit, r.started, r.run_id from metrics m join runs r using(run_id)
               join experiments e using(run_id) where m.name = ? and r.area = 'perf'"""
        args = [a.metric]
        if a.object:
            q += ' and m.object = ?'
            args.append(a.object)
        rows = c.execute(q + ' order by r.started', args).fetchall()
    finally:
        c.close()
    if not rows:
        raise HwError('HW-E-NOT-FOUND', 'no values for metric `%s`%s' % (a.metric, ' / ' + a.object if a.object else ''),
                      'metrics: fmax (--object clock:sys_clk), util_LUT4_pct, coremark_per_mhz, dmips_per_mhz, dhrystone_cycles')
    pts = [{'build': b, 'variant': v, 'value': x, 'unit': u, 'when': t, 'run': r} for b, v, x, u, t, r in rows]
    shown, more = timing.page(pts[::-1], a)
    lines = ['%s%s: %d values, newest first' % (a.metric, ' ' + a.object if a.object else '', len(pts))]
    lines += ['  %s %-10s %-10s %g %s' % (time.strftime('%Y-%m-%d', time.localtime(p['when'])), p['build'], p['variant'],
                                          p['value'], p['unit'] or '') for p in shown]
    return dict(cmd='perf history', metric=a.metric, object=a.object, points=shown, cached=True, lines=lines, **more)


def parse(argv):
    p = common.Parser(prog='hw perf', add_help=False)
    p.add_argument('--json', action='store_true')
    sub = p.add_subparsers(dest='verb', required=True, parser_class=common.Parser)

    def lim(sp, n=20):
        sp.add_argument('--limit', type=int, default=n)
        sp.add_argument('--all', action='store_true')
        sp.add_argument('--from', dest='start', type=int, default=0, help='first item (the `next` cursor)')
        sp.add_argument('--json', action='store_true')
    s = sub.add_parser('record'); s.add_argument('files', nargs='+'); s.add_argument('--build'); lim(s)
    s.set_defaults(fn=cmd_record)
    s = sub.add_parser('seed'); s.add_argument('--root'); lim(s, 10); s.set_defaults(fn=cmd_seed)
    s = sub.add_parser('show'); s.add_argument('--builds'); s.add_argument('--clock', default='sys_clk')
    s.add_argument('--sort', choices=('when', 'fmax', 'name'), default='when'); lim(s); s.set_defaults(fn=cmd_show)
    s = sub.add_parser('compare'); s.add_argument('a'); s.add_argument('b'); lim(s); s.set_defaults(fn=cmd_compare)
    s = sub.add_parser('history'); s.add_argument('metric'); s.add_argument('--object'); lim(s)
    s.set_defaults(fn=cmd_history)
    return p.parse_args(argv)


if __name__ == '__main__':
    # perf writes the state DB itself (one run per artifact), so the wrapper does not record its own answer
    sys.exit(timing.run(sys.argv[1:], area=None, parser=parse, doc=__doc__))
