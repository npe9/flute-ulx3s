#!/usr/bin/env python3
"""fvgen: formal checks for one IP block, generated from formal/fv/ips/<ip>/<ip>.cfg.

Modelled on riscv-formal's checks.cfg -> genchecks (one sby task per check, generated) and on the
YosysHQ AXI4 FVIP (protocol checkers as separate modules, a role parameter for which side is the
DUT).  The verification is kept apart from the implementation:

  * the RTL is read exactly as the FPGA build reads it: no defines, and fvgen refuses RTL that
    contains formal constructs (assert/assume/cover, anyconst/anyseq, `ifdef FORMAL ...);
  * the environment module (env) only instantiates the DUT and leaves its inputs free;
  * everything that checks lives in formal/fv: VIPs on the DUT's ports, the register model
    generated from the IP's register spec, and induction invariants in a checker that is attached
    to the DUT with `bind` -- so it can name internal signals without the RTL exporting them;
  * each bound checker must be attached: a missing bind target is an error, not a silent PASS.

Usage:
  fvgen.py run <ip> [check ...]      generate and run (all checks by default)
  fvgen.py mutate <ip> [mutant ...]  every mutant must be caught by a check or a catcher command
  fvgen.py regs <spec> <module>      print the register model generated from a register spec
  fvgen.py lint <file.v ...>         the RTL formal-construct check alone

Tools: the SVA yosys fork (sv-yosys, `bind` support): FV_YOSYS_DIR, default
~/src/sv-yosys/third_party/yosys/build.  Work trees: build/fv/<ip>/.
"""
import configparser
import os
import re
import shutil
import subprocess
import sys
import tempfile

FV = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(FV))
YDIR = os.environ.get('FV_YOSYS_DIR', os.path.expanduser('~/src/sv-yosys/third_party/yosys/build'))
TOOLS = ['--yosys', f'{YDIR}/yosys', '--abc', f'{YDIR}/yosys-abc', '--smtbmc', f'{YDIR}/yosys-smtbmc']

# ---------------------------------------------------------------- RTL lint
FORBIDDEN = [
    (re.compile(r'`ifn?def\s+(FORMAL|RISCV_FORMAL|RVFI|SDH_FAST)\b'), 'formal-only conditional'),
    (re.compile(r'(?<![\w$])(assert|assume|cover|restrict)\s*(property\s*)?\('), 'formal statement'),
    (re.compile(r'\b(anyconst|anyseq|allconst|allseq)\b'), 'formal attribute'),
    (re.compile(r'\$(past|stable|rose|fell|initstate)\b'), 'formal system function'),
]


def lint(paths):
    bad = []
    for p in paths:
        for n, line in enumerate(open(p, errors='replace'), 1):
            code = line.split('//')[0]
            for rx, what in FORBIDDEN:
                if rx.search(code):
                    bad.append(f'{p}:{n}: {what}: {line.strip()}')
    return bad


# ---------------------------------------------------------------- checker discipline
INV_MARK = re.compile(r'//\s*-+\s*INVARIANTS')


def lint_checker(path, allowed=()):
    """A bound checker states its properties on ports: the names in its '// internals' port group
    may appear only below its INVARIANTS marker (and in its bind statement), and nothing below the
    marker may assume.  `allowed`: internals the cfg declares usable above it (whitebox lemmas)."""
    text = open(path).read()
    m = re.search(r'//\s*internals[^\n]*\n(.*?)\);', text, re.S)
    if not m:
        return []
    names = set(re.findall(r'\b([A-Za-z_]\w*)\b\s*(?=[,\n])', re.sub(r'input\s+wire|\[[^\]]*\]', ' ', m.group(1))))
    names -= set(allowed)
    body_start = m.end()
    mk = INV_MARK.search(text, body_start)
    if not mk:
        return [f'{path}: internals declared but no INVARIANTS section']
    bind = text.find('\nbind ', mk.end())
    above = text[body_start:mk.start()]
    below = text[mk.end():bind if bind >= 0 else len(text)]
    bad = []
    for n, line in enumerate(above.split('\n'), text[:body_start].count('\n') + 1):
        code = line.split('//')[0]
        for nm in sorted(names):
            if re.search(rf'(?<![\w.]){re.escape(nm)}\b', code):
                bad.append(f'{path}:{n}: internal "{nm}" used outside INVARIANTS: {line.strip()}')
    for n, line in enumerate(below.split('\n'), text[:mk.end()].count('\n') + 1):
        if re.search(r'\bassume\s*\(', line.split('//')[0]):
            bad.append(f'{path}:{n}: assume in the INVARIANTS section: {line.strip()}')
    return bad


# ---------------------------------------------------------------- register spec -> model
def parse_bits(b):
    """'31:0' / '5' / '31:28,15:4' -> list of (hi, lo)"""
    out = []
    for part in b.split(','):
        hi, _, lo = part.partition(':')
        out.append((int(hi), int(lo or hi)))
    return out


def regs_sv(spec, module):
    """Register spec: one field per line: <offset> <name> <bits> <access> <reset>.
    access: rw (read back what was last written in full-word writes, reset value before),
            wo (shadowed like rw, not read back: s_<name> is what software last wrote),
            ro (constant <reset>), zero (reads 0), vol (not modelled: status, FIFO, side effects).
    Header options: '!window <bits>' (address bits), '!decode <mask>' (the address bits the
    device decodes: it aliases elsewhere; offsets are compared under the mask), '!unmapped zero'
    (unlisted offsets read 0), '!writes full|any|lanes' (a field takes a write with all four
    strobes / any strobe / the strobes of the byte lanes it occupies).
    The model shadows the rw fields from the bus writes and asserts every modelled read."""
    fields, opts = [], {'window': '12', 'unmapped': 'zero', 'writes': 'full'}
    for line in open(spec):
        line = line.split('#')[0].strip()
        if not line:
            continue
        if line.startswith('!'):
            k, v = line[1:].split(None, 1)
            opts[k] = v.strip()
            continue
        off, name, bits, acc, *rest = line.split()
        fields.append(dict(off=int(off, 0), name=name, bits=parse_bits(bits), acc=acc,
                           reset=int(rest[0], 0) if rest and rest[0] != '-' else 0))
    aw = int(opts['window'])
    offs = sorted({f['off'] for f in fields})
    rw = [f for f in fields if f['acc'] in ('rw', 'wo')]
    mask = int(opts['decode'], 0) if 'decode' in opts else (1 << aw) - 1
    def at(sig):
        return f"(({sig} & {aw}'h{mask:x}) == " if 'decode' in opts else f"({sig} == "
    def lanes(f):
        (h, l), = f['bits']
        return ' && '.join(f'wr_strb[{b}]' for b in range(l // 8, h // 8 + 1))
    ports = ['input wire clk', 'input wire rst',
             f'input wire wr', f'input wire [{aw-1}:0] wr_addr', 'input wire [31:0] wr_data',
             'input wire [3:0] wr_strb', 'input wire rd', f'input wire [{aw-1}:0] rd_addr',
             'input wire [31:0] rd_data']
    for f in rw:
        (h, l), = f['bits']
        ports.append(f'output reg [{h-l}:0] s_{f["name"]}')
    o = [f'// generated by formal/fv/bin/fvgen.py from {os.path.relpath(spec, FV)} -- do not edit',
         '`default_nettype none', f'module {module} (', '    ' + ',\n    '.join(ports), ');']
    full = {'full': lambda f: "(wr_strb == 4'hF)", 'any': lambda f: "1'b1",
            'lanes': lambda f: f'({lanes(f)})'}[opts['writes']]
    o.append('    always @(posedge clk) begin')
    for f in rw:
        (h, l), = f['bits']
        o.append(f"        if (wr && {full(f)} && {at('wr_addr')}{aw}'h{f['off']:x})) s_{f['name']} <= wr_data[{h}:{l}];")
    o.append('        if (rst) begin')
    for f in rw:
        w = f['bits'][0][0] - f['bits'][0][1] + 1
        o.append(f"            s_{f['name']} <= {w}'h{f['reset']:x};")
    o.append('        end')
    o.append('    end')
    o.append('    always @(*) if (!rst && rd) begin')
    for off in offs:
        terms = []
        for f in (f for f in fields if f['off'] == off):
            for (h, l) in f['bits']:
                if f['acc'] == 'rw':
                    terms.append(f"rd_data[{h}:{l}] == s_{f['name']}")
                elif f['acc'] == 'ro':
                    terms.append(f"rd_data[{h}:{l}] == {h-l+1}'h{(f['reset'] >> l) & ((1 << (h-l+1)) - 1):x}")
                elif f['acc'] == 'zero':
                    terms.append(f"rd_data[{h}:{l}] == {h-l+1}'h0")
        if terms:
            o.append(f"        if ({at('rd_addr')}{aw}'h{off:x})) assert ({' && '.join(terms)});")
    if opts['unmapped'] == 'zero':
        cond = ' && '.join(f"!{at('rd_addr')}{aw}'h{off:x})" for off in offs)
        o.append(f"        if ({cond}) assert (rd_data == 32'h0);")
    o.append('    end')
    o.append('endmodule')
    return '\n'.join(o) + '\n'


# ---------------------------------------------------------------- config
def load(ip):
    path = os.path.join(FV, 'ips', ip, f'{ip}.cfg')
    cp = configparser.ConfigParser(interpolation=None, delimiters=('=',))
    cp.optionxform = str
    cp.read(path)
    c = dict(cp['ip'])
    c['checks'] = dict(cp['checks']) if cp.has_section('checks') else {}
    c['mutants'] = dict(cp['mutants']) if cp.has_section('mutants') else {}
    c['catchers'] = dict(cp['catchers']) if cp.has_section('catchers') else {}
    return c


def fvpath(p):
    return p if os.path.isabs(p) else os.path.join(FV, p)


def gen(ip, c, work, rtl_override=None, only=None):
    """Write the work tree for each check (all, or those in `only`); returns {check: dir}.
    Only those checks' directories are replaced: another run's may be in use."""
    os.makedirs(work, exist_ok=True)
    root = os.path.abspath(os.environ.get('FV_RTL_ROOT') or REPO)   # a staged RTL tree (default: the repo)
    rtl = [rtl_override.get(r, os.path.join(root, r)) if rtl_override else os.path.join(root, r)
           for r in c['rtl'].split()]
    bad = lint(rtl)
    if bad:
        sys.exit('fvgen: formal constructs in the RTL (keep them in formal/fv):\n  ' + '\n  '.join(bad))
    fv = [fvpath(p) for p in c.get('fv', '').split()]
    bad = [b for f in fv for b in lint_checker(f, c.get('whitebox', '').split())]
    if bad:
        sys.exit('fvgen: checker discipline:\n  ' + '\n  '.join(bad))
    incs = [fvpath(p) for p in c.get('include', '').split()]
    if 'regs' in c:
        spec, mod = c['regs'].split()
        rp = os.path.abspath(os.path.join(work, f'{mod}.sv'))
        open(rp, 'w').write(regs_sv(fvpath(spec), mod))
        fv.insert(0, rp)
    env = fvpath(c['env'])
    binds = c.get('binds', '').split()
    dirs = {}
    for name, spec in c['checks'].items():
        if only and name not in only:
            continue
        mode, depth, *defs = spec.split()
        d = os.path.join(work, name)
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
        files = rtl + fv + [env] + [os.path.join(i, f) for i in incs for f in sorted(os.listdir(i))]
        dflags = ' '.join(f'-D{x}' for x in defs)
        eng = c.get(f'engine.{name}', c.get('engine', 'smtbmc boolector'))
        s = ['[options]', f'mode {mode}', f'depth {depth}', '', '[engines]', eng, '', '[script]']
        s.append('read_verilog -sv -formal ' + ' '.join(os.path.basename(r) for r in rtl))   # no defines
        s.append(f'read_verilog -sv -formal {dflags} ' + ' '.join(os.path.basename(f) for f in fv + [env]))
        s.append(f'prep -top {c["top"]}')
        for b in binds:
            s.append(f'select -assert-count 1 t:{b}')
        s += ['', '[files]'] + files
        open(os.path.join(d, f'{name}.sby'), 'w').write('\n'.join(s) + '\n')
        dirs[name] = d
    return dirs


def run_check(d, name, timeout=None):
    try:
        subprocess.run(['sby', '-f'] + TOOLS + [f'{name}.sby'], cwd=d, capture_output=True,
                       timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'TIMEOUT', ''
    log = os.path.join(d, name, 'logfile.txt')
    txt = open(log, errors='replace').read() if os.path.exists(log) else ''
    if 'NOT attached' in txt or 'unattached' in txt:
        return 'ERROR', 'a bound checker was not attached'
    m = re.findall(r'DONE \((\w+)', txt)
    st = m[-1] if m else 'ERROR'
    where = re.findall(r'failed assertion \S+ at (\S+)', txt)
    if st == 'ERROR':
        err = re.findall(r'ERROR: (.*)', txt)
        return st, err[0] if err else ''
    return st, where[0] if where else ''


def cmd_run(ip, only):
    c = load(ip)
    work = os.path.join(REPO, 'build', 'fv', ip)
    unknown = [n for n in only if n not in c['checks']]
    if unknown:
        sys.exit(f'fvgen: no such check: {" ".join(unknown)}')
    dirs = gen(ip, c, work, only=only)
    ok = True
    for name, d in dirs.items():
        if only and name not in only:
            continue
        st, where = run_check(d, name)
        want = 'PASS'
        print(f'{ip}.{name}: {st} {where}'.rstrip(), flush=True)
        ok &= st == want
    return 0 if ok else 1


def apply_mutant(text, exprs):
    """exprs: one or more  s#<python regex>#<replacement>#[g]  separated by ' ;; ' (any delimiter);
    each replaces its first match in the file (every match with g)."""
    for expr in exprs.split(' ;; '):
        m = re.fullmatch(r's(.)(.*?)\1(.*?)\1(g?)', expr.strip(), re.S)
        if not m:
            sys.exit(f'bad mutant expression: {expr}')
        _, pat, rep, g = m.groups()
        new = re.sub(pat, rep, text, count=0 if g else 1, flags=re.M)
        if new == text:
            return None                          # every part must apply
        text = new
    return text


def cmd_mutate(ip, only):
    c = load(ip)
    rtl = c['rtl'].split()
    root = os.path.abspath(os.environ.get('FV_RTL_ROOT') or REPO)
    tmp = tempfile.mkdtemp(prefix=f'fvmut_{ip}_')
    bad = 0

    def evaluate(tag, override):
        work = os.path.join(tmp, tag)
        dirs = gen(ip, c, work, override)
        res = []
        for name, d in dirs.items():
            if c['checks'][name].split()[0] == 'cover':
                continue
            st, where = run_check(d, name, timeout=int(os.environ.get('MUT_LIMIT', '900')))
            res.append((name, st, where))
        for name, cmd in c['catchers'].items():
            files = {os.path.basename(r): override.get(r, os.path.join(root, r)) if override else os.path.join(root, r)
                     for r in rtl}
            cmdx = cmd.format(w=work, repo=REPO, **{k.replace('.', '_'): v for k, v in files.items()})
            os.makedirs(work, exist_ok=True)
            try:
                r = subprocess.run(cmdx, shell=True, cwd=REPO, capture_output=True, text=True, timeout=900)
                res.append((name, 'PASS' if r.returncode == 0 else 'FAIL', ''))
            except subprocess.TimeoutExpired:
                res.append((name, 'TIMEOUT', ''))
        return res

    base = evaluate('base', None)
    print('baseline: ' + ', '.join(f'{n} {s}' for n, s, _ in base), flush=True)
    if any(s != 'PASS' for _, s, _ in base):
        return 1
    for name, spec in c['mutants'].items():
        if only and name not in only:
            continue
        path, _, expr = spec.partition('::')
        path = path.strip()
        src = open(os.path.join(root, path)).read()
        mut = apply_mutant(src, expr)
        if mut is None or mut == src:
            print(f'{name}: mutation did not apply')
            bad += 1
            continue
        mp = os.path.join(tmp, name + '_rtl', os.path.basename(path))
        os.makedirs(os.path.dirname(mp), exist_ok=True)
        open(mp, 'w').write(mut)
        res = evaluate(name, {path: mp})
        # only a counterexample (FAIL) or a failed induction (UNKNOWN) catches a mutant; a catcher
        # command catches by failing.  TIMEOUT / ERROR are inconclusive and fail the sweep.
        caught = [f'{n} {s} {w}'.strip() for n, s, w in res if s in ('FAIL', 'UNKNOWN')]
        odd = [f'{n} {s} {w}'.strip() for n, s, w in res if s not in ('PASS', 'FAIL', 'UNKNOWN')]
        msg = ('caught by ' + '; '.join(caught)) if caught else 'NOT CAUGHT'
        print(f'{name}: {msg}' + (f'  [inconclusive: {"; ".join(odd)}]' if odd else ''), flush=True)
        bad += not caught
    shutil.rmtree(tmp, ignore_errors=True)
    return 1 if bad else 0


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, arg, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    if cmd == 'run':
        return cmd_run(arg, rest)
    if cmd == 'mutate':
        return cmd_mutate(arg, rest)
    if cmd == 'regs':
        sys.stdout.write(regs_sv(arg, rest[0]))
        return 0
    if cmd == 'lint':
        bad = lint([arg] + rest)
        print('\n'.join(bad) or 'clean')
        return 1 if bad else 0
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main())
