#!/usr/bin/env python3
"""Random RV32 B (Zba/Zbb/Zbc/Zbs) and Zkn (Zbkb/Zbkc/Zbkx/Zkne/Zknd/Zknh)
instruction traces in QCVEngine's trace format, for replay with
`QCVEngine -d DIR` (QCVEngine has encoders/disassembly for B but no
generator template, and nothing for Zk*).

Each test: random register values (lui+addi into x1..x15), then random B/Zkn
operations over x0..x15 (results can feed later operands).

usage: gen_bk_traces.py OUTDIR [NTESTS] [SEED] [LEN]
"""
import os
import random
import sys

def r_type(f7, rs2, rs1, f3, rd, op=0x33):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def i_type(imm12, rs1, f3, rd, op=0x13):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

# name -> (kind, args): 'R' = (f7, f3); 'U' = unary I-type (imm12, f3); 'S' = shift-imm (f7, f3)
R_OPS = {
    # Zba
    'sh1add': (0x10, 2), 'sh2add': (0x10, 4), 'sh3add': (0x10, 6),
    # Zbb
    'andn': (0x20, 7), 'orn': (0x20, 6), 'xnor': (0x20, 4),
    'max': (0x05, 6), 'maxu': (0x05, 7), 'min': (0x05, 4), 'minu': (0x05, 5),
    'rol': (0x30, 1), 'ror': (0x30, 5),
    # Zbc / Zbkc
    'clmul': (0x05, 1), 'clmulh': (0x05, 3), 'clmulr': (0x05, 2),
    # Zbs
    'bclr': (0x24, 1), 'bext': (0x24, 5), 'binv': (0x34, 1), 'bset': (0x14, 1),
    # Zbkb
    'pack': (0x04, 4), 'packh': (0x04, 7),
    # Zbkx
    'xperm4': (0x14, 2), 'xperm8': (0x14, 4),
    # Zknh (RV32 SHA-512 halves)
    'sha512sum0r': (0x28, 0), 'sha512sum1r': (0x29, 0),
    'sha512sig0l': (0x2a, 0), 'sha512sig1l': (0x2b, 0),
    'sha512sig0h': (0x2e, 0), 'sha512sig1h': (0x2f, 0),
}
U_OPS = {
    # Zbb
    'clz': (0x600, 1), 'ctz': (0x601, 1), 'cpop': (0x602, 1),
    'sext.b': (0x604, 1), 'sext.h': (0x605, 1),
    'orc.b': (0x287, 5), 'rev8': (0x698, 5),
    # Zbkb
    'brev8': (0x687, 5), 'zip': (0x08f, 1), 'unzip': (0x08f, 5),
    # Zknh
    'sha256sum0': (0x100, 1), 'sha256sum1': (0x101, 1),
    'sha256sig0': (0x102, 1), 'sha256sig1': (0x103, 1),
}
S_OPS = {  # shamt in imm[4:0]
    'rori': (0x30, 5), 'bclri': (0x24, 1), 'bexti': (0x24, 5),
    'binvi': (0x34, 1), 'bseti': (0x14, 1),
}
AES_OPS = {'aes32esi': 0x11, 'aes32esmi': 0x13, 'aes32dsi': 0x15, 'aes32dsmi': 0x17}

def rand_op(rng):
    kind = rng.choice(['R'] * 6 + ['U'] * 3 + ['S'] * 2 + ['A'] * 2 + ['Z'])
    rd, rs1, rs2 = rng.randrange(1, 16), rng.randrange(0, 16), rng.randrange(0, 16)
    if kind == 'R':
        n = rng.choice(sorted(R_OPS)); f7, f3 = R_OPS[n]
        if n == 'pack' and rs2 == 0:
            rs2 = 1                         # pack rs2=x0 is zext.h (covered below)
        return r_type(f7, rs2, rs1, f3, rd), f'{n} x{rd}, x{rs1}, x{rs2}'
    if kind == 'U':
        n = rng.choice(sorted(U_OPS)); imm, f3 = U_OPS[n]
        return i_type(imm, rs1, f3, rd), f'{n} x{rd}, x{rs1}'
    if kind == 'S':
        n = rng.choice(sorted(S_OPS)); f7, f3 = S_OPS[n]; sh = rng.randrange(32)
        return i_type((f7 << 5) | sh, rs1, f3, rd), f'{n} x{rd}, x{rs1}, {sh}'
    if kind == 'A':
        n = rng.choice(sorted(AES_OPS)); bs = rng.randrange(4)
        return r_type((bs << 5) | AES_OPS[n], rs2, rs1, 0, rd), f'{n} x{rd}, x{rs1}, x{rs2}, {bs}'
    # zext.h (RV32: pack rd, rs1, x0)
    return r_type(0x04, 0, rs1, 4, rd), f'zext.h x{rd}, x{rs1}'

def prelude(rng):
    out = []
    for r in range(1, 16):
        v = rng.choice([rng.getrandbits(32), rng.getrandbits(8), 0xFFFFFFFF, 0x80000000, 0])
        hi = ((v + 0x800) >> 12) & 0xFFFFF
        lo = v & 0xFFF
        out.append(((hi << 12) | (r << 7) | 0x37, f'lui x{r}, 0x{hi:x}'))
        out.append((i_type(lo, r, 0, r), f'addi x{r}, x{r}, 0x{lo:x}'))
    return out

def main():
    outdir = sys.argv[1]
    ntests = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    length = int(sys.argv[4]) if len(sys.argv) > 4 else 24
    rng = random.Random(seed)
    os.makedirs(outdir, exist_ok=True)
    for t in range(ntests):
        insts = prelude(rng) + [rand_op(rng) for _ in range(length)]
        with open(os.path.join(outdir, f'bk_{seed}_{t:04d}.S'), 'w') as f:
            f.write('#>QCVENGINE_TEST_V2.0\n')
            for word, txt in insts:
                f.write(f'.4byte 0x{word:08x} # {txt}\n')

if __name__ == '__main__':
    main()
