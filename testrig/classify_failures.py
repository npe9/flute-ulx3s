#!/usr/bin/env python3
"""Classify QCVEngine counterexample files (written with -s DIR) by the first
divergence in a field QCVEngine's non-strict comparison checks.

  classify_failures.py DIR...      -> one line per file + a summary

Labels (heuristics; anything 'other' needs a manual look):
  D2       first divergence is a load's rd_wdata, and the previous
           D-side instruction in the trace was a load/store/AMO that trapped
           (misaligned): stale-data-after-misaligned-trap D-cache bug.
  D2?      wrong load rd_wdata with a trapped (misaligned) load/store
           somewhere earlier in the test, but not immediately before
           (the D2 family: e.g. trap, fence.i, ..., store, load miss).
  D3       Sail traps (illegal CSR), Flute does not, CSR in 0x380-0x39F or
           0x3F0-0x3FF (PMP CSR decode too wide).
  cfg-pmp / cfg-debug / cfg-csr
           CSRs where this Sail configuration and Flute legitimately differ
           (pmpcfg4-15 / pmpaddr8-63, trigger + debug CSRs, Sail's V
           extension, priv-1.12 envcfg, counters, mip): see README.
  SC-allowed SC succeeds in Sail and fails in Flute after an intervening
           load/store/AMO, FENCE(.I), SYSTEM or SFENCE.VMA by the same hart: outside a
           constrained LR/SC loop the ISA lets an SC fail (not a bug).
  SC-trap  SC fails in Sail and succeeds in Flute with a trap between the LR
           and the SC: Sail cancels the reservation on every trap, the ISA
           does not require it (not a bug).
  SC-bug   SC fails in Sail and succeeds in Flute with no trap in between.
  D1       Sail traps on a store/AMO to the vacant line 0xFFFFFFC0-0xFFFFFFFF,
           Flute does not (store access fault to a vacant address is lost).
  D1?      same, other address (e.g. RAM8M=1 runs).
  rerun-ok the saved re-run of the failing test did not diverge (failure
           depends on state left by an earlier test, e.g. D2's stale BRAM
           output register, which is not reset between tests).
  other    anything else.
"""
import os
import re
import sys
from collections import Counter

SIG = {'insn', 'trap', 'halt', 'rd_addr', 'rd_wdata', 'pc_wdata',
       'mem_addr', 'mem_wdata', 'mem_wmask'}
LDST_OPC = {0x03, 0x23, 0x2f}

def is_mem(word):
    if word & 3 == 3:
        return (word & 0x7f) in LDST_OPC
    op, f3 = word & 3, (word >> 13) & 7
    return (op == 0 and f3 in (2, 6)) or (op == 2 and f3 in (2, 6))   # c.lw/c.sw/c.lwsp/c.swsp

def parse(path):
    """-> list of dicts {word, text, a, b, mism} in trace order."""
    out, cur = [], None
    for line in open(path, errors='replace'):
        m = re.match(r'\.4byte 0x([0-9a-f]+) # (.*)', line)
        if m:
            cur = {'word': int(m.group(1), 16), 'text': m.group(2).strip(), 'a': None, 'b': None, 'mism': []}
            out.append(cur)
            continue
        if cur is None:
            continue
        if 'Trap:' in line:
            key = 'b' if 'PRV_?' in line else 'a'
            if cur[key] is None:
                cur[key] = line.strip('# \n')
        m = re.search(r'A, B v: (.*)', line)
        if m:
            cur['mism'] += re.findall(r'mismatch in field (\w+): (\S+) != (\S+)', m.group(1))
    return out

# CSR numbers where Sail (this config) and Flute legitimately differ
CFG_CSRS = {
    0x008: 'vstart (Sail model has V)', 0x009: 'vxsat', 0x00a: 'vxrm', 0x00f: 'vcsr',
    0x301: 'misa (Sail: V set, B clear)',
    0x10a: 'senvcfg (priv 1.12; Flute is 1.11)', 0x30a: 'menvcfg', 0x31a: 'menvcfgh',
    0x102: 'sedeleg (Flute keeps the N-ext legacy CSR)', 0x103: 'sideleg (idem)',
    0x344: 'mip (Sail MTIP always pending)', 0xb00: 'mcycle', 0xb80: 'mcycleh',
}

def csr_label(csr, names, r):
    sail_trap = trapped(r['a'])
    if (0x380 <= csr <= 0x39f or 0x3f0 <= csr <= 0x3ff) and 'trap' in names and sail_trap:
        return 'D3'                       # Flute decodes these as PMP CSRs
    if 0x3a4 <= csr <= 0x3af or 0x3b8 <= csr <= 0x3ef:
        return 'cfg-pmp'                  # PMP entries Sail has (16/64) and Flute (8) lacks
    if 0x7a0 <= csr <= 0x7bf:
        return 'cfg-debug'                # trigger / debug-mode CSRs (Flute GDB control)
    if csr in CFG_CSRS or 0xb03 <= csr <= 0xb1f or 0xb83 <= csr <= 0xb9f or 0x323 <= csr <= 0x33f \
       or 0xc00 <= csr <= 0xc9f:
        return 'cfg-csr'
    return None

def compared(field, a):
    """QCVEngine rvfiCheck (non-strict): the fields it actually compares.
    The annotated re-run lists every differing field, compared or not."""
    if field in ('trap', 'halt', 'pc_wdata', 'mode', 'XLEN'):
        return True
    if field in ('insn', 'rd_addr', 'rd_wdata', 'mem_wdata'):
        return not trapped(a)
    if field == 'mem_addr':
        m = re.search(r'MWM: 0b([01]+)', a)
        return bool(m and int(m.group(1), 2))
    return False

def trapped(rec):
    return rec is not None and 'Trap:  True' in rec

def classify(path):
    tr = parse(path)
    for i, r in enumerate(tr):
        sig = [m for m in r['mism'] if compared(m[0], r['a'] or '')]
        if not sig:
            continue
        fields = ','.join(f'{f}:{a}!={b}' for f, a, b in sig)
        names = {f for f, _, _ in sig}
        # SC: Sail succeeds, Flute fails, with a store/AMO/FENCE.I by this hart between
        # the LR and the SC.  The ISA lets an SC fail there (only constrained
        # LR/SC loops, with no other memory access inside, must succeed).
        if names == {'rd_wdata'} and r['word'] & 0x7f == 0x2f and (r['word'] >> 27) == 0x03 \
           and sig[0][1] == '0x0':
            between = []
            for p in reversed(tr[:i]):
                if p['word'] & 0x7f == 0x2f and (p['word'] >> 27) == 0x02:   # lr.w
                    break
                between.append(p)
            # Constrained LR/SC loops (unpriv 'Eventual Success') admit no loads,
            # stores, FENCEs or SYSTEM instructions, so any of these lets the SC fail.
            if any((p['word'] & 0x7f in (0x03, 0x23, 0x2f, 0x0f, 0x73)) or is_mem(p['word']) or
                   (p['word'] & 0x707f == 0x100f) or                               # fence.i
                   (p['word'] & 0xfe007fff == 0x12000073) or                       # sfence.vma
                   (p['word'] & 3 != 3 and p['word'] & 3 in (0, 2) and (p['word'] >> 13) & 7 == 6)
                   for p in between if not trapped(p['a'])):
                return 'SC-allowed', r['text'], fields
        # SC: Sail fails, Flute succeeds, with a trap between the LR and the SC.
        # Sail cancels the reservation on every trap; the ISA does not require
        # it (only another SC, or a store by another hart/device, must clear it).
        if names == {'rd_wdata'} and r['word'] & 0x7f == 0x2f and (r['word'] >> 27) == 0x03 \
           and sig[0][1] == '0x1':
            between = []
            for p in reversed(tr[:i]):
                if p['word'] & 0x7f == 0x2f and (p['word'] >> 27) == 0x02:   # lr.w
                    break
                between.append(p)
            return ('SC-trap' if any(trapped(p['a']) for p in between) else 'SC-bug'), r['text'], fields
        if names == {'rd_wdata'} and r['a'] and 'MRM: 0b0' in (r['a'] + (r['b'] or '')) and is_mem(r['word']):
            for p in reversed(tr[:i]):
                if is_mem(p['word']):
                    if trapped(p['a']):
                        return 'D2', r['text'], fields
                    break
            if any(is_mem(p['word']) and trapped(p['a']) for p in tr[:i]):
                return 'D2?', r['text'], fields
        if r['word'] & 0x7f == 0x73 and (r['word'] >> 12) & 7 not in (0, 4):
            lab = csr_label(r['word'] >> 20, names, r)
            if lab:
                return lab, r['text'], fields
        if 'trap' in names and trapped(r['a']) and not trapped(r['b']) and is_mem(r['word']) \
           and ((r['word'] & 0x7f) in (0x23, 0x2f) or r['word'] & 3 != 3):
            m = re.search(r'MA: 0x([0-9a-f]+)', r['a'])
            vacant = m and int(m.group(1), 16) >= 0xFFFFFFC0      # default map's vacant top line
            return ('D1' if vacant else 'D1?'), r['text'], fields
        return 'other', r['text'], fields
    return 'rerun-ok', '', ''

def main():
    files = []
    for d in sys.argv[1:]:
        files += sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith('.S')) if os.path.isdir(d) else [d]
    cnt = Counter()
    for f in files:
        lab, txt, fields = classify(f)
        cnt[lab] += 1
        print(f'{lab:9s} {os.path.basename(f)}  {txt}  {fields}')
    print('summary:', dict(cnt), 'files:', len(files))

if __name__ == '__main__':
    main()
