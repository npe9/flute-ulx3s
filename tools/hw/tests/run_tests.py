#!/usr/bin/env python3
"""tools/hw/tests/run_tests.py: hw board / hw lab answers, each with a negative control (the same
query on a planted change must give a different answer, or an error record).  No board needed:
the lab tests are the refusals and the error records."""
import json, os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.realpath(__file__)); HW = os.path.dirname(HERE); ROOT = os.path.dirname(os.path.dirname(HW))
fails = 0
def hw(tool, *args, env=None):
    e = dict(os.environ, **(env or {})); e.pop('HW_HOLDER', None) if 'HW_HOLDER' not in (env or {}) else None
    r = subprocess.run(['python3', '-I', os.path.join(HW, tool + '.py')] + list(args) + ['--json'], capture_output=True, text=True, env=e)
    try: return r.returncode, json.loads(r.stdout)
    except ValueError: return r.returncode, {'status': 'BAD-OUTPUT', 'raw': r.stdout + r.stderr}
def check(name, cond, got):
    global fails
    print(('ok   ' if cond else 'FAIL ') + name + ('' if cond else '  -- got %s' % json.dumps(got)[:300]))
    fails += not cond

# a copy of the inputs with planted changes (the negative controls)
tmp = tempfile.mkdtemp(prefix='hwtest-')
for d in ('constraints', 'tools/hw/data', 'Flute/src_Testbench/SoC'):
    os.makedirs(os.path.join(tmp, d), exist_ok=True)
shutil.copy(os.path.join(ROOT, 'constraints/ulx3s_85f.lpf'), os.path.join(tmp, 'constraints'))
shutil.copy(os.path.join(ROOT, 'Makefile'), tmp)
shutil.copy(os.path.join(ROOT, 'Flute/src_Testbench/SoC/SoC_Map.bsv'), os.path.join(tmp, 'Flute/src_Testbench/SoC'))
lpf = os.path.join(tmp, 'constraints/ulx3s_85f.lpf'); s = open(lpf).read()
open(lpf, 'w').write(s.replace('LOCATE COMP "CLK"        SITE "G2"', 'LOCATE COMP "CLK"        SITE "H2"'))
sm = os.path.join(tmp, 'Flute/src_Testbench/SoC/SoC_Map.bsv'); s = open(sm).read()
open(sm, 'w').write(s.replace("uart0_addr_base = 'hC000_0000", "uart0_addr_base = 'hC000_0100"))
MUT = {'HW_ROOT': tmp}

rc, j = hw('board', 'pins', 'CLK'); check('pins CLK is G2, 25 MHz, with its lpf line', rc == 0 and j['pins'][0]['site'] == 'G2' and j['pins'][0].get('freq_mhz') == 25.0 and j['pins'][0]['loc'].startswith('constraints/ulx3s_85f.lpf:'), j)
rc, j = hw('board', 'pins', 'CLK', env=MUT); check('  control: a moved CLK reads H2', rc == 0 and j['pins'][0]['site'] == 'H2', j)
rc, j = hw('board', 'pins', 'led[3]'); check('pins led[3] gets the led[*] IOBUF (drive 4)', rc == 0 and j['pins'][0].get('drive') == '4', j)
rc, j = hw('board', 'pins', 'CLOK'); check('unknown pin is an error record with a hint', rc != 0 and j['status'] == 'error' and j['code'] == 'HW-E-NOT-FOUND' and j.get('hint'), j)
rc, j = hw('board', 'pins', '--limit', '3'); check('pins is bounded, with a cursor', rc == 0 and len(j['pins']) == 3 and j['truncated'] and j['next'], j)
rc, j = hw('board', 'map', '0xC0000010'); check('map 0xC0000010 is uart0', rc == 0 and [r['name'] for r in j['map']] == ['uart0'], j)
rc, j = hw('board', 'map', '0xC0000010', env=MUT); check('  control: a moved uart0 leaves 0xC0000010 unmapped', rc != 0 and j['code'] == 'HW-E-NOT-FOUND', j)
rc, j = hw('board', 'map', 'vdp_vram'); check('map vdp_vram carries its ifdefs', rc == 0 and 'INCLUDE_VDP' in j['map'][0]['ifdef'], j)
rc, j = hw('board', 'clock'); check('clock lists SYS_PLL=50 -> 50 MHz', rc == 0 and any(c.get('SYS_PLL') == '50' and c.get('hz') == 50000000 for c in j['clocks']), j)
rc, j = hw('board', 'state', env={'HW_ROOT': tmp}); check('state reads the fact file', rc == 0 and 'slot0' in j['facts']['flash'], j)
rc, j = hw('lab', 'flash', 'x.bit'); check('lab flash is refused (HW-E-FLASH-DENIED, with a hint)', rc != 0 and j['code'] == 'HW-E-FLASH-DENIED' and 'load' in j['hint'], j)
rc, j = hw('lab', 'power-cycle'); check('lab power-cycle is refused (HW-E-UNSUPPORTED)', rc != 0 and j['code'] == 'HW-E-UNSUPPORTED' and 'restart' in j['hint'], j)
rc, j = hw('lab', 'restart', env={'HW_SERIAL': '/dev/null'}); check('lab restart without HW_HOLDER is refused before touching anything', rc != 0 and j['code'] == 'HW-E-NO-FACTS' and 'HW_HOLDER' in j['hint'], j)
rc, j = hw('lab', 'restart', env={'HW_SERIAL': '/dev/cu.no-such-board'}); check('lab restart on a missing device is HW-E-NO-BOARD', rc != 0 and j['code'] == 'HW-E-NO-BOARD', j)
rc, j = hw('lab', 'load', '/nonexistent.bit'); check('lab load of a missing file is HW-E-NOT-FOUND', rc != 0 and j['code'] == 'HW-E-NOT-FOUND', j)
rc, j = hw('lab', 'raw', 'serial:0'); check('lab raw of an unknown ref is an error record', rc != 0 and j['code'] == 'HW-E-NOT-FOUND', j)
rc, j = hw('board', 'pins', '--limit', 'x'); check('a bad argument is HW-E-BADREQ, exit 2', rc == 2 and j['code'] == 'HW-E-BADREQ', j)
rc, j = hw('board', 'frobnicate'); check('an unknown verb is HW-E-BADREQ, exit 2', rc == 2 and j['code'] == 'HW-E-BADREQ', j)
rc, j = hw('board', 'map', 'uart0'); check('every answer says cached', rc == 0 and j.get('cached') is False, j)
rc, j = hw('board', 'periph', 'uart0'); check('periph uart0: 0xC0000000, fabric-decoded, PLIC source 1', rc == 0 and j['periph'][0]['base'] == 0xC0000000 and j['periph'][0]['plic_source'] == 1 and j['periph'][0]['fabric_decoded'], j)
rc, j = hw('board', 'periph', 'uart0', env=MUT); check('  control: the moved uart0 base shows in periph', rc == 0 and j['periph'][0]['base'] == 0xC0000100, j)
rc, j = hw('board', 'periph', 'uart1'); check('periph uart1 needs INCLUDE_UART1, PLIC source 5', rc == 0 and j['periph'][0]['ifdef'] == ['INCLUDE_UART1'] and j['periph'][0]['plic_source'] == 5, j)
rc, j = hw('board', 'periph', 'nosuchdev'); check('periph: unknown device is HW-E-NOT-FOUND', rc != 0 and j['code'] == 'HW-E-NOT-FOUND', j)

# lab test: every refusal happens before the lock or the board (fake .bit files; no board needed)
lt = tempfile.mkdtemp(prefix='hwlab-')
for n in ('thin-s5.bit', 'ok-s3.bit', 'nolog.bit'): open(os.path.join(lt, n), 'wb').write(b'\xff' * 16)
pl = open(os.path.join(HW, 'tests', 'data', 'pnr-s1.log')).read()   # routed: 115.09 MHz at a 100 MHz target (+15.1%)
open(os.path.join(lt, 'pnr-s3.log'), 'w').write(pl)
ls_ = pl.split('\n'); k = [i for i, l in enumerate(ls_) if 'Max frequency for clock' in l][-1]
ls_[k] = ls_[k].replace('115.09 MHz (PASS', '105.00 MHz (PASS')
open(os.path.join(lt, 'pnr-s5.log'), 'w').write('\n'.join(ls_))  # planted: +5% margin
NOB = {'HW_SERIAL': '', 'HW_HOLDER': ''}
rc, j = hw('lab', 'test', 'cache', os.path.join(lt, 'thin-s5.bit'), env=NOB); check('lab test: a +5% bitstream is refused (HW-E-MARGIN, rule 7)', rc != 0 and j['code'] == 'HW-E-MARGIN' and '+5.0%' in j['reason'], j)
rc, j = hw('lab', 'test', 'cache', os.path.join(lt, 'ok-s3.bit'), env=NOB); check('  control: its +15% seed passes the margin gate (stops later at the console setting)', rc != 0 and j['code'] == 'HW-E-NO-FACTS' and 'console' in j['reason'], j)
rc, j = hw('lab', 'test', 'cache', os.path.join(lt, 'nolog.bit'), '--pnr', os.path.join(lt, 'nope.log'), env=NOB); check('lab test: --pnr to a missing log is not a pass', rc != 0, j)
os.remove(os.path.join(lt, 'pnr-s3.log')); os.remove(os.path.join(lt, 'pnr-s5.log'))
rc, j = hw('lab', 'test', 'cache', os.path.join(lt, 'nolog.bit'), env=NOB); check('lab test: unknown margin is refused unless --force', rc != 0 and j['code'] == 'HW-E-MARGIN' and '--force' in j['hint'], j)
rc, j = hw('lab', 'test', 'cache', os.path.join(lt, 'nolog.bit'), '--force', env=NOB); check('  control: --force gets past the margin gate', rc != 0 and j['code'] == 'HW-E-NO-FACTS', j)
rc, j = hw('lab', 'test', 'blob', os.path.join(lt, 'nolog.bit'), '--blob', 'test/sd_test_w.bin', '--force', env=NOB); check('lab test: sd_test_w.bin is refused (HW-E-DENIED, read-only SD)', rc != 0 and j['code'] == 'HW-E-DENIED', j)
rc, j = hw('lab', 'test', 'blob', os.path.join(lt, 'nolog.bit'), '--blob', 'test/amo_test.bin', '--force', env=NOB); check('  control: a read-only-safe blob is not denied', rc != 0 and j['code'] != 'HW-E-DENIED', j)
rc, j = hw('lab', 'test', 'frob', os.path.join(lt, 'nolog.bit')); check('lab test: unknown suite is HW-E-BADREQ, exit 2', rc == 2 and j['code'] == 'HW-E-BADREQ', j)
rc, j = hw('lab', 'serial', '--restart', env={'HW_SERIAL': '/dev/null'}); check('lab serial --restart without HW_HOLDER is refused before touching anything', rc != 0 and j['code'] == 'HW-E-NO-FACTS' and 'HW_HOLDER' in j['hint'], j)
shutil.rmtree(lt)
# result parsing on canned output (what a board run prints)
sys.path.insert(0, HW); sys.path.insert(0, os.path.expanduser('~/src/hwsh/lib')); import lab as LAB
P = 'program rc= 0\nloader rc= 0\n\n--- program output ---\n[81000137 : 01e42023]\n'
c = LAB.parse_tmd(P + 'TD\n', 'serial:1', 'cache')[0]; check('parse: T then D is a pass', c['status'] == 'pass', c)
c = LAB.parse_tmd(P + 'T\nM 80001000 5a5a0a37 00000000\nD\n', 'serial:1', 'cache')[0]; check('  control: a mismatch line makes it fail', c['status'] == 'fail' and '1 mismatch' in c['observed'], c)
try:
    LAB.parse_tmd('program rc= 0\nTraceback (most recent call last):\nRuntimeError: load failed at chunk 0\n', 'serial:1', 'cache'); c = 'no error'
except Exception as e:
    c = getattr(e, 'code', repr(e))
check('parse: a harness traceback is an error (HW-E-LAB-HARNESS), not a test verdict', c == 'HW-E-LAB-HARNESS', c)
S = 'PASS  eval 1+1  -- 2\nFAIL  devROM records  -- got 15\n    captured: abc\nWARN  I64 pair (hi-half P1)\n\n== summary: 1 PASS, 1 FAIL, 1 WARN, 0 SKIP ==\n'
cs = LAB.parse_suite(S, 'serial:1'); check('parse suite: one record per line, captured text kept', [x['status'] for x in cs] == ['pass', 'fail', 'warn'] and 'captured' in cs[1]['observed'], cs)
cs = LAB.parse_suite('REPL never reached a prompt\n', 'serial:1'); check('  control: no summary line is a failing check', cs and cs[-1]['status'] == 'fail', cs)
shutil.rmtree(tmp)
print('%d failed' % fails); sys.exit(1 if fails else 0)
