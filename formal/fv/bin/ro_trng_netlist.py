#!/usr/bin/env python3
"""ro_trng_netlist: check src/RO_TRNG.v's ring oscillators in a synthesized ECP5 netlist (yosys JSON).

Simulation and formal never see the rings (Verilator, Bluesim and formal/fv each substitute a
stand-in), so this is the only check of what the FPGA gets.  On the netlist the bitstream is
placed from, for the one RO_TRNG instance:

  rings    8 disjoint combinational cycles of 3, 5, ..., 17 LUT4 cells, each a pure inverter
           (Z = ~A, B = C = D = 0); every loop net drives only the next stage, except the tap
           (the last stage), which also drives exactly one first-stage sampling flop.
  sampler  s1[r] samples ring r's tap, s2[r] samples s1[r] (no reset, one clock); bit_q's D is
           a LUT cone whose inputs are exactly the eight s2 outputs and whose function is their
           XOR (all 256 assignments evaluated).
  use      bit_q reaches the entropy source's decimator flop (rg_dec) through combinational
           logic only, and every flop above is clocked by rg_dec's clock.

--selftest breaks the loaded netlist in each of those ways and requires every break to be caught.
Usage: ro_trng_netlist.py [--selftest] <netlist.json>
"""
import copy
import itertools
import json
import re
import sys

COMB = {'LUT4', 'PFUMX', 'L6MUX21'}
FF = 'TRELLIS_FF'


class Bad(Exception):
    pass


def lut_init(c):
    s = c['parameters']['INIT']
    return int(s, 2) if set(s) <= {'0', '1'} else int(s)


def check(mod):
    cells = mod['cells']
    ring = {}
    for n, c in cells.items():
        m = re.match(r'(.*)\.g_ring\[(\d+)\]\.g_stage\[(\d+)\]\.inv$', n)
        if m:
            ring.setdefault((m.group(1), int(m.group(2))), {})[int(m.group(3))] = n
    insts = {p for p, _ in ring}
    if len(insts) != 1:
        raise Bad(f'expected one RO_TRNG instance with rings, found {sorted(insts)}')
    inst = insts.pop()
    drv, users = {}, {}
    for n, c in cells.items():
        for pin, bits in c['connections'].items():
            for b in bits:
                if isinstance(b, str):
                    continue
                d = c.get('port_directions', {}).get(pin)
                if d is None:
                    d = 'output' if pin in ('Z', 'Q', 'S0', 'S1', 'COUT', 'F0', 'F1', 'OFX0', 'OFX1') else 'input'
                (drv if d == 'output' else users).setdefault(b, []).append((n, pin))
    for b, ds in drv.items():
        if len(ds) > 1:
            raise Bad(f'net {b} has several drivers {ds}')

    def one(c, pin):
        v = cells[c]['connections'][pin]
        if len(v) != 1:
            raise Bad(f'{c}.{pin} is {len(v)} bits')
        return v[0]

    # ---- rings
    if sorted(r for _, r in ring) != list(range(8)):
        raise Bad(f'rings {sorted(r for _, r in ring)}, expected 0..7')
    taps, seen = [], set()
    for r in range(8):
        st = ring[(inst, r)]
        n_st = 3 + 2 * r
        if sorted(st) != list(range(n_st)):
            raise Bad(f'ring {r}: stages {sorted(st)}, expected {n_st}')
        for s, n in st.items():
            c = cells[n]
            if c['type'] != 'LUT4':
                raise Bad(f'{n} is {c["type"]}, not LUT4')
            for p in 'BCD':
                if c['connections'][p] != ['0']:
                    raise Bad(f'{n}.{p} is not tied 0')
            i = lut_init(c)
            if (i & 1, (i >> 1) & 1) != (1, 0):
                raise Bad(f'{n}: INIT {c["parameters"]["INIT"]} is not Z = ~A')
        # the cycle: stage s's input is stage s-1's output
        for s in range(n_st):
            a, z_prev = one(st[s], 'A'), one(st[(s - 1) % n_st], 'Z')
            if a != z_prev:
                raise Bad(f'ring {r}: stage {s} input {a} is not stage {(s - 1) % n_st} output {z_prev}')
            z = one(st[s], 'Z')
            if z in seen:
                raise Bad(f'ring {r}: net {z} shared with another ring')
            seen.add(z)
            u = users.get(z, [])
            others = [x for x in u if x != (st[(s + 1) % n_st], 'A')]
            if s == n_st - 1:
                if len(others) != 1 or cells[others[0][0]]['type'] != FF or others[0][1] != 'DI':
                    raise Bad(f'ring {r}: tap {z} drives {u}, expected the next stage and one flop D')
                taps.append((z, others[0][0]))
            elif others:
                raise Bad(f'ring {r}: loop net {z} also drives {others}')

    # ---- sampler
    clk = None
    s2q = []
    for r, (tap, s1) in enumerate(taps):
        if cells[s1]['connections'].get('LSR', ['0']) != ['0']:
            raise Bad(f'{s1}: s1 flop has a reset')
        q1 = one(s1, 'Q')
        u = [x for x in users.get(q1, []) if cells[x[0]]['type'] == FF and x[1] == 'DI']
        if len(users.get(q1, [])) != 1 or not u:
            raise Bad(f'ring {r}: s1 output {q1} drives {users.get(q1)}, expected one flop D')
        s2 = u[0][0]
        if cells[s2]['connections'].get('LSR', ['0']) != ['0']:
            raise Bad(f'{s2}: s2 flop has a reset')
        for f in (s1, s2):
            c = one(f, 'CLK')
            if clk is None:
                clk = c
            elif c != clk:
                raise Bad(f'{f} clocked by {c}, not {clk}')
        s2q.append(one(s2, 'Q'))

    def cone(net, leaves):
        """The cell driving net as a function of the leaves, or Bad if other inputs reach it."""
        if net in leaves:
            return lambda env: env[net]
        if net in ('0', '1'):
            return lambda env, k=int(net): k
        d = drv.get(net)
        if not d:
            raise Bad(f'net {net} undriven')
        n, _ = d[0]
        c = cells[n]
        t = c['type']
        if t == 'LUT4':
            ins = [cone(one(n, p), leaves) for p in 'ABCD']
            i = lut_init(c)
            return lambda env: (i >> (ins[0](env) | ins[1](env) << 1 | ins[2](env) << 2 | ins[3](env) << 3)) & 1
        if t == 'PFUMX':
            a, b, s = (cone(one(n, p), leaves) for p in ('ALUT', 'BLUT', 'C0'))
            return lambda env: a(env) if s(env) else b(env)
        if t == 'L6MUX21':
            d0, d1, s = (cone(one(n, p), leaves) for p in ('D0', 'D1', 'SD'))
            return lambda env: d1(env) if s(env) else d0(env)
        raise Bad(f'{n} ({t}) in the XOR cone is not a LUT or mux')

    bq_cands = {u[0] for q in s2q for u in users.get(q, [])}
    # bit_q: the flop at the end of the s2 outputs' cone
    ffs = set()
    frontier = set(s2q)
    visited = set()
    while frontier:
        b = frontier.pop()
        if b in visited:
            continue
        visited.add(b)
        for n, p in users.get(b, []):
            if cells[n]['type'] == FF:
                ffs.add((n, p))
            elif cells[n]['type'] in COMB:
                for pp, bits in cells[n]['connections'].items():
                    if pp in ('Z', 'OFX0', 'OFX1'):
                        frontier.update(x for x in bits if not isinstance(x, str))
            else:
                raise Bad(f'an s2 output reaches {n} ({cells[n]["type"]})')
    if len(ffs) != 1 or list(ffs)[0][1] != 'DI':
        raise Bad(f's2 outputs reach flops {sorted(ffs)}, expected one (bit_q) D')
    bq = list(ffs)[0][0]
    if one(bq, 'CLK') != clk:
        raise Bad(f'{bq} not on the sampler clock')
    f = cone(one(bq, 'DI'), set(s2q))
    for v in itertools.product((0, 1), repeat=8):
        env = dict(zip(s2q, v))
        if f(env) != (sum(v) & 1):
            raise Bad(f'bit_q D is not the XOR of the s2 outputs at {v}')

    # ---- use: bit_q reaches the decimator flop
    dec = [n for n in cells if cells[n]['type'] == FF and re.search(r'rg_dec(_TRELLIS_FF_Q)?$', n)
           and n.startswith(inst.rsplit('.', 1)[0])]
    if len(dec) != 1:
        raise Bad(f'decimator flop: {dec}')
    dec = dec[0]
    frontier, visited, hit = {one(bq, 'Q')}, set(), False
    while frontier:
        b = frontier.pop()
        if b in visited:
            continue
        visited.add(b)
        for n, p in users.get(b, []):
            if n == dec and p == 'DI':
                hit = True
            elif cells[n]['type'] in COMB:
                for pp, bits in cells[n]['connections'].items():
                    if pp in ('Z', 'OFX0', 'OFX1'):
                        frontier.update(x for x in bits if not isinstance(x, str))
    if not hit:
        raise Bad(f'bit_q ({bq}) does not reach {dec} D')
    if one(dec, 'CLK') != clk:
        raise Bad(f'{dec} is not on the sampler clock')
    return inst, bq, dec


def selftest(mod):
    cells = mod['cells']
    inst, bq, dec = check(mod)
    st = lambda r, s: f'{inst}.g_ring[{r}].g_stage[{s}].inv'
    def mut_init(m):
        m['cells'][st(3, 2)]['parameters']['INIT'] = '1010101010101010'
    def mut_buf(m):
        m['cells'][st(0, 1)]['parameters']['INIT'] = '0000000000000010'
    def mut_short(m):            # ring 5 loses a stage: stage 0 fed from stage 2's output
        m['cells'][st(5, 0)]['connections']['A'] = m['cells'][st(5, 2)]['connections']['Z']
    def mut_drop(m):
        del m['cells'][st(7, 4)]
    def mut_tie(m):
        m['cells'][st(2, 0)]['connections']['B'] = m['cells'][st(2, 1)]['connections']['Z']
    def mut_xor(m):              # bit_q cone: one LUT's INIT inverted (XNOR)
        for n, c in m['cells'].items():
            if c['type'] == 'LUT4' and n.startswith(bq) :
                c['parameters']['INIT'] = format(lut_init(c) ^ 0xFFFF, '016b')
                return
        raise Bad('no LUT in the bit_q cone named after it')
    def mut_unused(m):           # bit_q's output disconnected from the source
        q = m['cells'][bq]['connections']['Q']
        for n, c in m['cells'].items():
            if n != bq:
                for p, bits in c['connections'].items():
                    if p not in ('Z', 'Q', 'OFX0', 'OFX1') and bits == q:
                        c['connections'][p] = ['0']
    def mut_clk(m):
        m['cells'][bq]['connections']['CLK'] = ['1']
    def mut_reset(m):
        for n, c in m['cells'].items():
            if c['type'] == FF and '.s1' in n:
                c['connections']['LSR'] = m['cells'][dec]['connections']['Q']
                return
    bad = 0
    for name, f in list(locals().items()):
        if not name.startswith('mut_'):
            continue
        m = copy.deepcopy(mod)
        f(m)
        try:
            check(m)
            print(f'selftest {name[4:]}: NOT CAUGHT')
            bad += 1
        except Bad as e:
            print(f'selftest {name[4:]}: caught ({e})')
    return bad


def main(argv):
    st = '--selftest' in argv
    path = [a for a in argv if not a.startswith('--')][0]
    d = json.load(open(path))
    tops = [m for m, v in d['modules'].items() if v.get('attributes', {}).get('top')]
    mod = d['modules'][tops[0]]
    try:
        inst, bq, dec = check(mod)
    except Bad as e:
        print(f'ro_trng_netlist: FAIL: {e}')
        return 1
    print(f'ro_trng_netlist: PASS ({inst}: 8 rings 3..17, s1 -> s2 -> XOR -> bit_q -> rg_dec)')
    if st:
        return 1 if selftest(mod) else 0
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
