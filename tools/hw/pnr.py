"""tools/hw/pnr.py: parse nextpnr-ecp5 text logs and --report JSON into one small record.

Shared by timing.py (and perf.py).  Parsed records are cached by the file's sha256 in
~/.cache/hwsh/pnr/<sha>.json (rule 7); index.json maps sha[:12] -> path so ids such as
`tpath:<sha12>.0` and `pnrlog:<sha12>:L10-40` resolve back to their file.

Stage: a log's fmax/critical-path blocks after "Routing complete." are the ROUTED result (the
authoritative one, AGENTS.md rule 7); blocks before it are placement estimates.  A log with no
routing marker is placed-only: its numbers are estimates, never an Fmax claim.
"""
import hashlib
import json
import os
import re
import tempfile

PARSER_VERSION = 4
CACHE = os.environ.get('HW_PNR_CACHE') or os.path.expanduser('~/.cache/hwsh/pnr')

RX_FMAX = re.compile(r"^(?:Info|ERROR|Warning): Max frequency for clock\s+'([^']+)': ([\d.]+) MHz "
                     r"\((PASS|FAIL) at ([\d.]+) MHz\)")
RX_XDELAY = re.compile(r"^Info: Max delay (.+?)\s+-> (.+?)\s*: ([\d.]+) ns")
RX_UTIL = re.compile(r"^Info:\s+(\w+):\s+(\d+)/\s*(\d+)\s+(\d+)%")
RX_CP = re.compile(r"^Info: Critical path report for (?:clock '([^']+)' \(([^)]*)\)|cross-domain path '([^']+)' -> '([^']+)'):")
RX_HOP = re.compile(r"^Info:\s+(clk-to-q|routing|logic|setup|source|hold)\s+(-?[\d.]+)\s+(-?[\d.]+) (Source|Net) (\S+)"
                    r"(?: \((\d+),(\d+)\) -> \((\d+),(\d+)\))?")
RX_SINK = re.compile(r"^Info:\s+Sink (\S+)")
RX_LOC = re.compile(r"^Info:\s+(\S+?):(\d+)\.(\d+)-\d+\.\d+\s*$")
RX_SPLIT = re.compile(r"^Info: ([\d.]+) ns logic, ([\d.]+) ns routing")
RX_VER = re.compile(r"\(Version ([^)]+)\)")
# yosys/nextpnr cell-name suffixes: everything from the first mapped-cell marker on is mapping noise
RX_NOISE = re.compile(r"(?:_|\$)(?:LUT4|TRELLIS_[A-Z0-9]+|PFUMX|L6MUX21|CCU2C|CCU2|DP16KD|MULT18X18D|ALU54B|DPR16X4|"
                      r"glbnet|CCU2_COMB\d)(?=_|\.|\$|\[|$)")
RX_RULE = re.compile(r"(WILL_FIRE|CAN_FIRE)_(RL_\w+?)(?=_LUT4|_TRELLIS|\$|\.|\[|$)")
LIB_SRC = ('/share/yosys/', '/share/nextpnr/')

# resources the summary prints, in order (ECP5 names -> short names)
SHORT = [('TRELLIS_COMB', 'LUT4'), ('TRELLIS_FF', 'FF'), ('DP16KD', 'EBR'), ('MULT18X18D', 'DSP'),
         ('TRELLIS_RAMW', 'LUTRAM'), ('TRELLIS_IO', 'IO'), ('EHXPLLL', 'PLL')]


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for blk in iter(lambda: fh.read(1 << 20), b''):
            h.update(blk)
    return h.hexdigest()


def clock_name(n):
    """'$glbnet$sys_clk' -> 'sys_clk' (also strips '$TRELLIS_IO_IN' pad suffixes)."""
    n = n.replace('posedge ', '').replace('negedge ', '')
    n = re.sub(r'^\$glbnet\$', '', n)
    return re.sub(r'\$TRELLIS_IO_IN$', '', n)


def collapse(name):
    """A mapped cell/net name -> the design signal it came from (drop LUT4_Z_... chains, bit index, port)."""
    m = RX_NOISE.search(name)
    base = name[:m.start()] if m else re.sub(r'\.[A-Z0-9]+$', '', name)
    return re.sub(r'\[\d+\]$', '', base)


def module_of(sig):
    return sig.rsplit('.', 1)[0] if '.' in sig else '(top)'


def rule_hints(names):
    out = []
    for n in names:
        for m in RX_RULE.finditer(n):
            pre = n[:m.start()]
            r = {'rule': m.group(2), 'inst': pre.rsplit('.', 1)[0] if '.' in pre else '(top)', 'via': m.group(1)}
            if r not in out:
                out.append(r)
    return out


# ---------------------------------------------------------------- log parser
def parse_log(path):
    lines = open(path, errors='replace').read().split('\n')
    rec = {'kind': 'log', 'version': None, 'routed': False, 'finished': False, 'errors': [],
           'util': {}, 'stages': {'placed': {'fmax': [], 'xdelay': [], 'paths': []},
                                  'routed': {'fmax': [], 'xdelay': [], 'paths': []}}}
    stage = 'placed'
    cp = None

    def close():
        nonlocal cp
        if cp is not None:
            rec['stages'][cp.pop('_stage')]['paths'].append(cp)
            cp = None

    for i, l in enumerate(lines, 1):
        if rec['version'] is None and '(Version' in l:
            m = RX_VER.search(l)
            rec['version'] = m.group(1) if m else None
        if l.startswith('Info: Routing complete.'):
            close()
            stage, rec['routed'] = 'routed', True
            continue
        if l.startswith('Info: Program finished normally.'):
            rec['finished'] = True
        m = RX_FMAX.match(l)
        if m:
            close()
            rec['stages'][stage]['fmax'].append({'clock': clock_name(m.group(1)), 'net': m.group(1),
                                                 'mhz': float(m.group(2)), 'verdict': m.group(3),
                                                 'target_mhz': float(m.group(4)), 'line': i})
            continue
        if l.startswith('ERROR:'):
            rec['errors'].append({'line': i, 'message': l[6:].strip()[:300]})
        m = RX_XDELAY.match(l)
        if m:
            rec['stages'][stage]['xdelay'].append({'from': clock_name(m.group(1).strip()),
                                                   'to': clock_name(m.group(2).strip()), 'ns': float(m.group(3))})
            continue
        m = RX_UTIL.match(l)
        if m and not rec['util'].get(m.group(1)):
            rec['util'][m.group(1)] = {'used': int(m.group(2)), 'available': int(m.group(3))}
            continue
        m = RX_CP.match(l)
        if m:
            close()
            if m.group(1):
                cp = {'clock': clock_name(m.group(1)), 'from_clk': clock_name(m.group(1)),
                      'to_clk': clock_name(m.group(1)), 'edges': m.group(2)}
            else:
                cp = {'clock': None, 'from_clk': clock_name(m.group(3)), 'to_clk': clock_name(m.group(4))}
            cp.update({'_stage': stage, 'hops': [], 'line_from': i, 'line_to': i})
            continue
        if cp is None:
            continue
        m = RX_HOP.match(l)
        if m:
            hop = {'type': m.group(1), 'ns': float(m.group(2)), 'total': float(m.group(3)),
                   'what': m.group(4).lower(), 'name': m.group(5), 'line': i}
            if m.group(6):
                hop['xy'] = [int(m.group(6)), int(m.group(7)), int(m.group(8)), int(m.group(9))]
            cp['hops'].append(hop)
            cp['line_to'] = i
            continue
        m = RX_SINK.match(l)
        if m and cp['hops']:
            cp['hops'][-1]['sink'] = m.group(1)
            cp['line_to'] = i
            continue
        m = RX_LOC.match(l)
        if m and cp['hops']:
            cp['hops'][-1].setdefault('src', []).append({'file': m.group(1), 'line': int(m.group(2)),
                                                         'col': int(m.group(3))})
            cp['line_to'] = i
            continue
        m = RX_SPLIT.match(l)
        if m:
            cp['logic_ns'], cp['routing_ns'] = float(m.group(1)), float(m.group(2))
            cp['line_to'] = i
            close()
            continue
        if not l.startswith('Info:   ') and not l.startswith('Info: \t'):
            close()
    close()
    return rec


# ---------------------------------------------------------------- --report JSON
def parse_report(path):
    d = json.load(open(path))
    if not isinstance(d, dict) or 'fmax' not in d:
        raise ValueError('not a nextpnr --report JSON (no "fmax" key)')
    st = {'fmax': [], 'xdelay': [], 'paths': []}
    for net, f in d.get('fmax', {}).items():
        st['fmax'].append({'clock': clock_name(net), 'net': net, 'mhz': round(float(f['achieved']), 2),
                           'target_mhz': float(f['constraint']),
                           'verdict': 'PASS' if f['achieved'] >= f['constraint'] else 'FAIL', 'line': None})
    for k, c in enumerate(d.get('critical_paths', [])):
        fc, tc = clock_name(c['from']), clock_name(c['to'])
        hops, tot, logic, routing = [], 0.0, 0.0, 0.0
        for h in c.get('path', []):
            tot += h['delay']
            if h['type'] == 'routing':
                routing += h['delay']
            else:
                logic += h['delay']
            hop = {'type': h['type'], 'ns': round(h['delay'], 3), 'total': round(tot, 3),
                   'what': 'net' if h['type'] == 'routing' else 'source',
                   'name': h.get('net') or '%s.%s' % (h['from']['cell'], h['from']['port']), 'line': None,
                   'sink': '%s.%s' % (h['to']['cell'], h['to']['port'])}
            if h['type'] == 'routing':
                hop['xy'] = list(h['from']['loc']) + list(h['to']['loc'])
            src = []
            for s in h.get('sources', []):
                m = re.match(r'(.+?):(\d+)\.(\d+)', s)
                if m:
                    src.append({'file': m.group(1), 'line': int(m.group(2)), 'col': int(m.group(3))})
            if src:
                hop['src'] = src
            hops.append(hop)
        st['paths'].append({'clock': fc if fc == tc and c['from'] != '<async>' else None, 'from_clk': fc,
                            'to_clk': tc, 'hops': hops, 'logic_ns': round(logic, 2),
                            'routing_ns': round(routing, 2), 'line_from': None, 'line_to': None})
    util = {k: {'used': v['used'], 'available': v['available']} for k, v in d.get('utilization', {}).items()}
    return {'kind': 'report', 'version': None, 'routed': None, 'finished': True, 'errors': [], 'util': util,
            'stages': {'report': st}}


# ---------------------------------------------------------------- cache
def _atomic_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, 'w') as fh:
        fh.write(text)
    os.replace(tmp, path)


def _index():
    try:
        return json.load(open(os.path.join(CACHE, 'index.json')))
    except (OSError, ValueError):
        return {}


def load(path):
    """-> (record, cached).  The record carries sha, sha12, path."""
    s = sha256(path)
    cf = os.path.join(CACHE, s + '.json')
    try:
        rec = json.load(open(cf))
        if rec.get('parser') == PARSER_VERSION:
            cached = True
        else:
            rec = None
    except (OSError, ValueError):
        rec = None
    if rec is None:
        cached = False
        with open(path, 'rb') as fh:
            head = fh.read(64).lstrip()
        rec = parse_report(path) if head.startswith(b'{') else parse_log(path)
        rec['parser'] = PARSER_VERSION
        _atomic_write(cf, json.dumps(rec, separators=(',', ':')))
    rec['sha'], rec['sha12'], rec['path'] = s, s[:12], os.path.abspath(path)
    idx = _index()
    if idx.get(s[:12]) != rec['path']:
        idx[s[:12]] = rec['path']
        _atomic_write(os.path.join(CACHE, 'index.json'), json.dumps(idx, indent=0))
    return rec, cached


def resolve(sha12):
    """sha[:12] -> path, checking the file still has that content."""
    p = _index().get(sha12)
    if p and os.path.exists(p) and sha256(p).startswith(sha12):
        return p
    return None


def final_stage(rec):
    """-> (stage name, stage dict, complete).  routed if the log routed; else the placement estimate."""
    if rec['kind'] == 'report':
        return 'report', rec['stages']['report'], True
    if rec['routed'] and rec['stages']['routed']['fmax']:
        return 'routed', rec['stages']['routed'], True
    return 'placed', rec['stages']['placed'], False
