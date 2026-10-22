#!/usr/bin/env python3
"""Greedy delta-debugging of a QCVEngine trace against Sail vs Flute.

  minimize.py IN.S OUT.S [LABEL] [JOBS]

Repeatedly deletes chunks of instructions (halving chunk size down to 1) and
keeps a deletion when the replay (testrig/run_testrig.sh -S -t) still fails
with the same classify_failures.py label (default: the label of IN.S).
The mcause/mtval/mccsr suffix is added back by QCVEngine on every replay.
Each replay is a fresh Sail + DUT pair; JOBS replays run in parallel.
"""
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import classify_failures as C

def load(path):
    insts, skip = [], False
    for line in open(path, errors='replace'):
        if line.startswith('#>START_NO_SHRINK'):
            skip = True
        elif line.startswith('#>END_NO_SHRINK'):
            skip = False
        elif not skip and re.match(r'\.4byte 0x[0-9a-f]+ #', line):
            insts.append(line.rstrip('\n'))
    return insts

def write(path, insts):
    with open(path, 'w') as f:
        f.write('#>QCVENGINE_TEST_V2.0\n' + '\n'.join(insts) + '\n')

def run(insts, slot, work):
    d = tempfile.mkdtemp(dir=work)
    t = os.path.join(d, 'cand.S')
    write(t, insts)
    os.makedirs(os.path.join(d, 'fail'))
    env = dict(os.environ, PORT_BASE=str(30000 + 2 * slot + 40 * (os.getpid() % 200)))
    subprocess.run([os.path.join(HERE, 'run_testrig.sh'), '-o', d, '-r', 'rv32imacs_zicsr_zifencei',
                    '-S', '-t', t, '-s', os.path.join(d, 'fail')],
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    fails = [os.path.join(d, 'fail', f) for f in os.listdir(os.path.join(d, 'fail'))]
    if not fails:
        return None
    return C.classify(sorted(fails)[0])[0]

def main():
    src, dst = sys.argv[1], sys.argv[2]
    label = sys.argv[3] if len(sys.argv) > 3 else C.classify(src)[0]
    jobs = int(sys.argv[4]) if len(sys.argv) > 4 else 3
    work = tempfile.mkdtemp(prefix='testrig-min-')
    insts = load(src)
    print(f'{len(insts)} instructions, target label {label}', flush=True)
    if run(insts, 0, work) != label:
        sys.exit('input does not reproduce with that label')
    n = max(1, len(insts) // 2)
    with ThreadPoolExecutor(jobs) as ex:
        while n >= 1:
            changed = True
            while changed:
                changed = False
                starts = list(range(0, len(insts), n))
                for k in range(0, len(starts), jobs):
                    batch = starts[k:k + jobs]
                    cands = [insts[:s] + insts[s + n:] for s in batch]
                    res = list(ex.map(lambda a: run(a[1], a[0], work), enumerate(cands)))
                    ok = [c for c, r in zip(cands, res) if r == label]
                    if ok:
                        insts = min(ok, key=len)
                        write(dst, insts)
                        print(f'chunk {n}: {len(insts)} instructions', flush=True)
                        changed = True
                        break
            n //= 2
    write(dst, insts)
    print(f'done: {len(insts)} instructions -> {dst}')

if __name__ == '__main__':
    main()
