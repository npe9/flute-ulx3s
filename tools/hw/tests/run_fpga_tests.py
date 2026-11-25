#!/usr/bin/env python3
"""tools/hw/tests/run_fpga_tests.py: hw timing / place / fw / perf, each answer with a negative control
(a planted change in the input must change the answer), plus code mutants (a broken backend must
fail at least one check).  Fixtures in tests/data: a tiny design routed by this nextpnr (pass at 100 MHz
and fail at 400 MHz), its --report JSON and --write placement, two bench logs.

    python3 -I tools/hw/tests/run_fpga_tests.py            all checks + mutants
    python3 -I tools/hw/tests/run_fpga_tests.py --no-mutants
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
HW = os.path.dirname(HERE)
DATA = os.path.join(HERE, 'data')


def make_inputs(tmp):
    """Copies of the fixtures with planted changes (the input negative controls)."""
    d = os.path.join(tmp, 'in')
    os.makedirs(os.path.join(d, 'tinyb'))
    os.makedirs(os.path.join(d, 'tiny'))
    os.makedirs(os.path.join(d, 'bench'))
    ok = open(os.path.join(DATA, 'pnr-s1.log')).read()
    open(os.path.join(d, 'tiny', 'pnr-s1.log'), 'w').write(ok)
    # planted: the routed (second) Max frequency line says 99.10 MHz FAIL; the placement estimate is untouched
    lines = ok.split('\n')
    idx = [i for i, l in enumerate(lines) if 'Max frequency for clock' in l]
    lines[idx[-1]] = re.sub(r"[\d.]+ MHz \(PASS at 100.00 MHz\)", '99.10 MHz (FAIL at 100.00 MHz)', lines[idx[-1]])
    open(os.path.join(d, 'tinyb', 'pnr-s1.log'), 'w').write('\n'.join(lines))
    # planted: killed before routing finished
    cut = ok[:ok.index('Info: Routing complete.')]
    open(os.path.join(d, 'tiny', 'pnr-s2.log'), 'w').write(cut)
    shutil.copy(os.path.join(DATA, 'pnr-fail.log'), os.path.join(d, 'fail.log'))
    shutil.copy(os.path.join(DATA, 'report.json'), os.path.join(d, 'report.json'))
    shutil.copy(os.path.join(DATA, 'placed.json'), os.path.join(d, 'placed.json'))
    p = json.load(open(os.path.join(DATA, 'placed.json')))
    for name, c in p['modules']['top']['cells'].items():           # planted: every `acc` cell moved +20 in x
        if name.startswith('acc'):
            x, y, bel = c['attributes']['NEXTPNR_BEL'].split('/', 2)
            c['attributes']['NEXTPNR_BEL'] = 'X%d/%s/%s' % (int(x[1:]) + 20, y, bel)
    json.dump(p, open(os.path.join(d, 'placed-moved.json'), 'w'))
    shutil.copy(os.path.join(DATA, 'tiny.v'), d)
    for b in ('coremark', 'dhrystone'):
        shutil.copy(os.path.join(DATA, 't1-%s.log' % b), os.path.join(d, 'bench', 't1-%s.log' % b))
    cm = open(os.path.join(DATA, 't1-coremark.log')).read().replace('Iterations/Sec   : 76.584725', 'Iterations/Sec   : 70.000000')
    open(os.path.join(d, 'bench', 't2-coremark.log'), 'w').write(cm)
    # firmware: an ELF with a known function, a build with an error, a warning and an undefined reference
    open(os.path.join(d, 'ok.c'), 'w').write('int sq(int x){ return x * x; }\nvoid _start(void){ for(;;) sq(3); }\n')
    open(os.path.join(d, 'bad.c'), 'w').write('extern int g(void);\nint f(void){ int u; return g(); }\n'
                                             'void _start(void){ f(); }\n')
    shutil.copy(os.path.join(DATA, 't1-coremark.log'), os.path.join(d, 'bench', 't3-coremark.log'))  # same bytes, other build
    open(os.path.join(d, 'ldwarn.log'), 'w').write('/x/bin/ld: warning: cannot find entry symbol _start; defaulting to 00010094\n')
    open(os.path.join(d, 'syn.c'), 'w').write('int h(void){ return y }\n')
    return d


def run_checks(hw, d, env):
    fails = []

    def q(tool, *args):
        r = subprocess.run(['python3', '-I', os.path.join(hw, tool + '.py')] + list(args[:1]) + ['--json'] + list(args[1:]),
                           capture_output=True, text=True, env=env, cwd=d)
        try:
            return r.returncode, json.loads(r.stdout)
        except ValueError:
            return r.returncode, {'status': 'BAD-OUTPUT', 'raw': (r.stdout + r.stderr)[-400:]}

    def check(name, cond, got):
        print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else '  -- got %s' % json.dumps(got)[:300]))
        if not cond:
            fails.append(name)

    def clk(j, i=0):
        return j['files'][i]['clocks'][0]

    # ---- timing
    rc, j = q('timing', 'summary', 'tiny/pnr-s1.log')
    check('timing: routed Fmax is the post-route line (115.09), PASS at 100', rc == 0 and j['files'][0]['stage'] == 'routed'
          and clk(j)['mhz'] == 115.09 and clk(j)['verdict'] == 'PASS', j)
    check('timing: the placement estimate (138.14) is not reported', rc == 0 and clk(j)['mhz'] != 138.14, j)
    rc, j = q('timing', 'summary', 'tinyb/pnr-s1.log')
    check('  control: a planted routed FAIL line is status fail, exit 1', rc == 1 and j['status'] == 'fail'
          and clk(j)['mhz'] == 99.1, j)
    rc, j = q('timing', 'summary', 'tiny/pnr-s2.log')
    check('timing: an unrouted log is complete:false, exit 5, no failing verdict', rc == 5 and j.get('complete') is False
          and j['files'][0]['stage'] == 'placed' and j['status'] == 'ok', j)
    rc, j = q('timing', 'summary', 'fail.log')
    check('timing: 115 MHz against 400 is fail (exit 1), margin -71.2%', rc == 1 and clk(j)['margin_pct'] == -71.2, j)
    rc, j = q('timing', 'summary', 'report.json')
    check('timing: --report JSON gives the same Fmax as its log', rc == 0 and clk(j)['mhz'] == 115.09 and
          j['files'][0]['stage'] == 'report' and j['files'][0].get('assumptions'), j)
    rc, j = q('timing', 'summary', 'tiny/pnr-s1.log', 'tinyb/pnr-s1.log')
    check('timing: two seeds give a band (min 99.1, max 115.09, 1 pass 1 fail)', rc == 1 and j['bands'][0]['min'] == 99.1
          and j['bands'][0]['max'] == 115.09 and j['bands'][0]['pass'] == 1, j)
    rc, j = q('timing', 'summary', 'tiny/pnr-s1.log')
    check('timing: a repeat is answered from cache', rc == 0 and j['cached'] is True, j)
    rc, j = q('timing', 'worst', 'tiny/pnr-s1.log')
    intra = [p for p in j.get('paths', []) if p['clock']]
    check('timing worst: the clk path, 1 DSP stage, slack from 100 MHz', rc == 0 and intra and intra[0]['clock'] == 'clk'
          and intra[0]['slack_ns'] == round(10 - intra[0]['ns'], 2) and intra[0]['id'].startswith('tpath:'), j)
    pid = intra[0]['id'] if intra else 'tpath:0.0'
    check('timing worst: design source survives (tiny.v), library cells do not', rc == 0 and intra and
          all('/share/yosys/' not in s['loc']['file'] for s in intra[0]['src']) and
          any(s['loc']['file'] == 'tiny.v' for s in intra[0]['src']), j)
    rc, j = q('timing', 'path', pid)
    check('timing path: from ra/rb register to acc/q, raw_ref names log lines', rc == 0 and j['path']['from'] in ('ra', 'rb')
          and j['path']['raw_ref'].startswith('pnrlog:'), j)
    rc, k = q('timing', 'expand', pid, '--limit', '3')
    check('timing expand: bounded hops with a cursor', rc == 0 and len(k['hops']) == 3 and k['truncated'], k)
    rc, r = q('timing', 'raw', j['path']['raw_ref'] if rc == 0 else 'pnrlog:x:L1-2')
    check('timing raw: the slice starts at the path header', rc == 0 and 'Critical path report' in r['text'][0], r)
    rc, j = q('timing', 'compare', 'tiny/pnr-s1.log', 'tinyb/pnr-s1.log')
    check('timing compare: -15.99 MHz, PASS -> FAIL', rc == 0 and j['clocks'][0]['delta_mhz'] == -15.99 and
          j['clocks'][0]['b_verdict'] == 'FAIL', j)
    rc, j = q('timing', 'summary', 'nope.log')
    check('timing: missing file is an error record (exit 3)', rc == 3 and j['code'] == 'HW-E-NOT-FOUND', j)
    rc, j = q('timing', 'path', 'tpath:zz')
    check('timing: a bad id is HW-E-BADREQ, exit 2', rc == 2 and j['code'] == 'HW-E-BADREQ', j)
    rc, j = q('timing', 'summary', 'tiny.v')
    check('timing: a non-log file answers with no fmax and incomplete, never a pass', rc == 5 and
          j['files'][0]['clocks'] == [], j)

    # ---- place
    rc, j = q('place', 'location', 'placed.json', 'acc')
    check('place location: acc has 16+ cells with a centroid', rc == 0 and j['n'] >= 16 and j['match'] == 'signal', j)
    rc, k = q('place', 'location', 'placed-moved.json', 'acc')
    check('  control: planted +20 x moves the acc centroid by 20', rc == 0 and j.get('centroid') and
          round(k['centroid'][0] - j['centroid'][0], 1) == 20.0, k)
    rc, j = q('place', 'compare', 'placed.json', 'placed-moved.json', '--depth', '1')
    check('place compare: the moved block is listed first', rc == 0 and j['modules'][0]['shift'] and
          j['modules'][0]['shift'] > 5, j)
    rc, j = q('place', 'summary', 'tiny/pnr-s1.log')
    check('place: a log is an error record (not JSON), with the --write hint', rc == 3 and '--write' in (j.get('hint') or ''), j)
    rc, j = q('place', 'congestion', 'placed.json')
    check('place congestion: HW-E-UNSUPPORTED with a hint', rc == 3 and j['code'] == 'HW-E-UNSUPPORTED' and j['hint'], j)

    # ---- fw
    gcc = shutil.which('riscv64-unknown-elf-gcc')
    if gcc:
        cc = [gcc, '-march=rv32imac', '-mabi=ilp32', '-nostdlib', '-O1', '-g']
        rc, j = q('fw', 'build', '--', *cc, 'ok.c', '-o', 'ok.elf')
        check('fw build: a clean build is ok, 0 errors', rc == 0 and j['errors'] == 0 and j['status'] == 'ok', j)
        rc, j = q('fw', 'build', '--', *cc, '-Wall', 'bad.c', '-o', 'bad.elf')
        codes = {x['code'] for x in j.get('diagnostics', [])}
        check('fw build: undefined reference is an ld error, unused var a -W warning; exit 1', rc == 1 and
              'ld-undefined' in codes and '-Wunused-variable' in codes and j['errors'] == 1, j)
        rc, j = q('fw', 'build', '--', *cc, '-c', 'syn.c')
        d0 = (j.get('diagnostics') or [{}])[0]
        check('fw build: a syntax error is typed with file:line:col', rc == 1 and d0.get('file') == 'syn.c' and
              d0.get('line') == 1 and d0.get('col'), j)
        rc, r = q('fw', 'raw', d0.get('raw_ref') or 'fwlog:x:L1-2')
        check('fw raw: the raw_ref holds the compiler text', rc == 0 and any('syn.c' in t for t in r['text']), r)
        rc, j = q('fw', 'symbols', 'ok.elf', '--grep', '^sq$')
        check('fw symbols: sq is a func with a size', rc == 0 and j['symbols'][0]['kind'] == 'func' and j['symbols'][0]['size'], j)
        rc, k = q('fw', 'disasm', 'ok.elf', 'sq')
        check('fw disasm sq: has a mul', rc == 0 and any(' mul ' in l for l in k['insns']), k)
        addr = j['symbols'][0]['addr'] if rc == 0 else 0
        rc, k = q('fw', 'addr', 'ok.elf', hex(addr + 2))
        check('fw addr: pc inside sq -> sq+0x2, ok.c:1', rc == 0 and k['pcs'][0]['symbol'] == 'sq' and k['pcs'][0]['offset'] == 2
              and k['pcs'][0]['file'].endswith('ok.c'), k)
        rc, k = q('fw', 'disasm', 'ok.elf', 'sqq')
        check('fw disasm: unknown function is an error with similar names', rc == 3 and 'sq' in (k.get('hint') or ''), k)
        rc, k = q('fw', 'symbols', 'tiny.v')
        check('fw: a non-ELF is HW-E-FW-NOT-ELF', rc == 3 and k['code'] == 'HW-E-FW-NOT-ELF', k)
    else:
        print('skip fw build/elf checks: no riscv64-unknown-elf-gcc')
    rc, j = q('fw', 'diags', 'ldwarn.log')
    check('fw diags: an ld warning is a warning, not an error (status ok)', rc == 0 and j['errors'] == 0 and j['warnings'] == 1, j)
    rc, j = q('fw', 'csr', 'misa', '0x4014112f')
    check('fw csr: misa 0x4014112f = RV32ABCDFIMSU (the promoted core)', rc == 0 and j['summary'] == 'RV32ABCDFIMSU', j)
    rc, j = q('fw', 'csr', 'misa', '0x4014110f')
    check('  control: misa without bit 5 drops F', rc == 0 and j['summary'] == 'RV32ABCDIMSU', j)
    rc, j = q('fw', 'csr', 'mcause', '0x8000000b')
    check('fw csr: mcause 0x8000000b = machine external interrupt', rc == 0 and 'machine external' in j['summary'], j)
    rc, j = q('fw', 'csr', 'mcause', '0xd')
    check('fw csr: mcause 13 = load page fault', rc == 0 and 'load page fault' in j['summary'], j)
    rc, j = q('fw', 'csr', 'mstatus', '0x1808')
    mpp = [f for f in j.get('fields', []) if f['name'] == 'MPP']
    check('fw csr: mstatus 0x1808 = MIE, MPP=M', rc == 0 and mpp and mpp[0]['meaning'] == 'M' and 'MIE' in j['summary'], j)
    rc, j = q('fw', 'csr', 'mtohost')
    check('fw csr: unknown CSR is an error record', rc == 3 and j['code'] == 'HW-E-NOT-FOUND', j)

    # ---- perf (its own state DB)
    rc, j = q('perf', 'record', 'tiny/pnr-s1.log', 'tiny/pnr-s2.log', 'tinyb/pnr-s1.log', 'bench/t1-coremark.log',
              'bench/t1-dhrystone.log', 'bench/t2-coremark.log')
    check('perf record: 6 new runs', rc == 0 and j['new'] == 6, j)
    rc, j = q('perf', 'record', 'tiny/pnr-s1.log')
    check('perf record: a file already recorded is not recorded again (cached)', rc == 0 and j['new'] == 0 and j['cached'], j)
    rc, j = q('perf', 'record', 'bench/t3-coremark.log')
    check('perf record: identical bytes under another build name are that build\'s run too', rc == 0 and j['new'] == 1, j)
    rc, j = q('perf', 'show', '--clock', 'clk', '--sort', 'name')
    rows = {r['build']: r for r in j.get('builds', [])}
    check('perf show: tiny band has the routed seed only, s2 listed unrouted', rc == 0 and rows.get('tiny', {}).get('fmax', {})
          and rows['tiny']['fmax']['n'] == 1 and rows['tiny']['unrouted'] == ['s2'], j)
    check('perf show: t1 CoreMark/MHz 1.5317 (76.58 it/s at 50 MHz), DMIPS/MHz 0.612', rc == 0 and
          rows.get('t1', {}).get('coremark_per_mhz') == 1.5317 and rows['t1']['dmips_per_mhz'] == 0.612, j)
    rc, j = q('perf', 'compare', 't1', 't2')
    m = {x['metric']: x for x in j.get('metrics', [])}
    check('  control: planted 70 it/s gives CM/MHz 1.4, delta -0.1317', rc == 0 and m.get('coremark_per_mhz', {}).get('b') == 1.4
          and m['coremark_per_mhz']['delta'] == -0.1317, j)
    rc, j = q('perf', 'compare', 'tiny', 'tinyb')
    f = [x for x in j.get('metrics', []) if x['metric'] == 'fmax']
    check('perf compare: tiny -> tinyb fmax mean -15.99', rc == 0 and f and f[0]['delta_mean'] == -15.99, j)
    db = os.path.join(env['HW_PROJECT'], '.hw', 'state.db')
    import sqlite3
    c = sqlite3.connect(db)
    row = c.execute("select count(*), sum(git_rev is null), sum(started < 1e9) from runs where area='perf'").fetchone()
    check('perf: seeded runs claim no commit (git_rev NULL)', row[0] == 7 and row[1] == 7, row)
    n = c.execute("select count(*) from artifacts a join runs r using(run_id) where r.area='perf' and a.kind='input'").fetchone()[0]
    check('perf: every run carries its artifact sha (lineage)', n == 7, n)
    c.close()
    rc, j = q('perf', 'history', 'nosuch')
    check('perf history: unknown metric is an error with the metric list', rc == 3 and 'fmax' in (j.get('hint') or ''), j)
    return fails


MUTANTS = [
    ('pnr.py', "stage, rec['routed'] = 'routed', True", "rec['routed'] = True",
     'takes the placement estimate as the Fmax'),
    ('fw.py', "            if msg.startswith('warning:'):\n                sev, msg = 'warning', msg[8:].strip()\n            elif",
     '            if', 'ld warnings counted as errors'),
    ('perf.py', "and e.name = ? and e.variant = ?\", (s, build, variant)", "and ? = ? and ? = ?\", (s, 1, 1, 1, 1)",
     'dedupes perf records by content only'),
    ('csrs.py', "letters = ''.join(chr(65 + i) for i in range(26) if v >> i & 1)",
     "letters = ''.join(chr(65 + i) for i in range(25) if v >> i + 1 & 1)", 'misa letters off by one'),
]


def env_for(tmp):
    e = dict(os.environ)
    e['HW_PNR_CACHE'] = os.path.join(tmp, 'cache')
    e['HW_PROJECT'] = os.path.join(tmp, 'proj')
    e.pop('HW_HOLDER', None)
    os.makedirs(e['HW_PROJECT'], exist_ok=True)
    return e


def main():
    tmp = tempfile.mkdtemp(prefix='hwfpga-')
    try:
        d = make_inputs(tmp)
        fails = run_checks(HW, d, env_for(os.path.join(tmp, 'real')))
        print('%d failed' % len(fails))
        mut_bad = 0
        if '--no-mutants' not in sys.argv:
            for k, (f, old, new, what) in enumerate(MUTANTS):
                mt = os.path.join(tmp, 'mut%d' % k)
                shutil.copytree(HW, os.path.join(mt, 'hw'), ignore=shutil.ignore_patterns('tests', '__pycache__', 'data'))
                shutil.copytree(os.path.join(HW, 'data'), os.path.join(mt, 'hw', 'data')) if os.path.isdir(
                    os.path.join(HW, 'data')) else None
                src = open(os.path.join(mt, 'hw', f)).read()
                if old not in src:
                    print('MUTANT %d (%s): pattern not found in %s -- update the test' % (k, what, f))
                    mut_bad += 1
                    continue
                open(os.path.join(mt, 'hw', f), 'w').write(src.replace(old, new, 1))
                d2 = make_inputs(mt)
                out = sys.stdout
                sys.stdout = open(os.devnull, 'w')
                try:
                    mf = run_checks(os.path.join(mt, 'hw'), d2, env_for(os.path.join(mt, 'env')))
                finally:
                    sys.stdout.close()
                    sys.stdout = out
                print('mutant %d (%s): %s' % (k, what, 'caught by %d check(s): %s' % (len(mf), mf[0]) if mf
                                                 else 'NOT CAUGHT'))
                mut_bad += not mf
        return 1 if fails or mut_bad else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
