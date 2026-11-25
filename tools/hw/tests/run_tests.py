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
shutil.rmtree(tmp)
print('%d failed' % fails); sys.exit(1 if fails else 0)
