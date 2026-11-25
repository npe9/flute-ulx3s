"""tools/hw/csrs.py: RV32 CSR field tables (privileged spec 1.12 + debug spec 0.13) for `hw fw csr`.

Fields are (name, hi, lo, desc[, values]).  Only what Flute on this SoC implements or what a
trap dump prints; an unknown CSR is an error record, never a guess.
"""

EXC = {0: 'instruction address misaligned', 1: 'instruction access fault', 2: 'illegal instruction',
       3: 'breakpoint', 4: 'load address misaligned', 5: 'load access fault',
       6: 'store/AMO address misaligned', 7: 'store/AMO access fault', 8: 'ecall from U', 9: 'ecall from S',
       11: 'ecall from M', 12: 'instruction page fault', 13: 'load page fault', 15: 'store/AMO page fault'}
IRQ = {1: 'supervisor software', 3: 'machine software', 5: 'supervisor timer', 7: 'machine timer',
       9: 'supervisor external', 11: 'machine external'}
PRIV = {0: 'U', 1: 'S', 3: 'M'}
XS = {0: 'Off', 1: 'Initial', 2: 'Clean', 3: 'Dirty'}

IRQ_FIELDS = [('SSI', 1, 1), ('MSI', 3, 3), ('STI', 5, 5), ('MTI', 7, 7), ('SEI', 9, 9), ('MEI', 11, 11)]


def F(name, hi, lo, desc='', values=None):
    return {'name': name, 'hi': hi, 'lo': lo, 'bits': '%d' % hi if hi == lo else '%d:%d' % (hi, lo),
            'desc': desc, 'values': values}


MSTATUS = [F('SIE', 1, 1, 'S interrupts enabled'), F('MIE', 3, 3, 'M interrupts enabled'),
           F('SPIE', 5, 5), F('UBE', 6, 6), F('MPIE', 7, 7), F('SPP', 8, 8, 'previous S-mode priv', {0: 'U', 1: 'S'}),
           F('VS', 10, 9, '', XS), F('MPP', 12, 11, 'previous M-mode priv', PRIV), F('FS', 14, 13, 'FPU state', XS),
           F('XS', 16, 15, '', XS), F('MPRV', 17, 17, 'loads/stores use MPP translation'),
           F('SUM', 18, 18, 'S may touch U pages'), F('MXR', 19, 19), F('TVM', 20, 20), F('TW', 21, 21),
           F('TSR', 22, 22), F('SD', 31, 31, 'some state dirty')]
SSTATUS = [f for f in MSTATUS if f['name'] in ('SIE', 'SPIE', 'UBE', 'SPP', 'VS', 'FS', 'XS', 'SUM', 'MXR', 'SD')]
CAUSE = [F('Interrupt', 31, 31), F('Code', 30, 0)]
TVEC = [F('MODE', 1, 0, '', {0: 'Direct', 1: 'Vectored'}), F('BASE', 31, 2, 'base >> 2')]
SATP = [F('PPN', 21, 0, 'root page table PPN'), F('ASID', 30, 22), F('MODE', 31, 31, '', {0: 'Bare', 1: 'Sv32'})]
DCSR = [F('prv', 1, 0, 'priv before debug entry', PRIV), F('step', 2, 2), F('nmip', 3, 3), F('mprven', 4, 4),
        F('cause', 8, 6, 'why debug mode was entered', {1: 'ebreak', 2: 'trigger', 3: 'haltreq', 4: 'step',
                                                         5: 'resethaltreq'}),
        F('stoptime', 9, 9), F('stopcount', 10, 10), F('stepie', 11, 11), F('ebreaku', 12, 12),
        F('ebreaks', 13, 13), F('ebreakm', 15, 15), F('xdebugver', 31, 28)]
PMPCFG = []
for i in range(4):
    b = 8 * i
    PMPCFG += [F('R%d' % i, b, b), F('W%d' % i, b + 1, b + 1), F('X%d' % i, b + 2, b + 2),
               F('A%d' % i, b + 4, b + 3, '', {0: 'OFF', 1: 'TOR', 2: 'NA4', 3: 'NAPOT'}), F('L%d' % i, b + 7, b + 7)]
IRQF = [F(n, h, l) for n, h, l in IRQ_FIELDS]
COUNTEREN = [F('CY', 0, 0), F('TM', 1, 1), F('IR', 2, 2)]

CSRS = {
    'mstatus': {'addr': 0x300, 'priv': 'MRW', 'desc': 'machine status', 'fields': MSTATUS},
    'sstatus': {'addr': 0x100, 'priv': 'SRW', 'desc': 'supervisor status (view of mstatus)', 'fields': SSTATUS},
    'misa': {'addr': 0x301, 'priv': 'MRW', 'desc': 'ISA and extensions', 'fields': [F('Extensions', 25, 0), F('MXL', 31, 30, '', {1: '32', 2: '64'})]},
    'medeleg': {'addr': 0x302, 'priv': 'MRW', 'desc': 'exceptions delegated to S (bit n = cause n)', 'fields': []},
    'mideleg': {'addr': 0x303, 'priv': 'MRW', 'desc': 'interrupts delegated to S', 'fields': IRQF},
    'mie': {'addr': 0x304, 'priv': 'MRW', 'desc': 'interrupt enables', 'fields': IRQF},
    'mip': {'addr': 0x344, 'priv': 'MRW', 'desc': 'interrupts pending', 'fields': IRQF},
    'sie': {'addr': 0x104, 'priv': 'SRW', 'desc': 'S interrupt enables', 'fields': IRQF[:1] + IRQF[2:3] + IRQF[4:5]},
    'sip': {'addr': 0x144, 'priv': 'SRW', 'desc': 'S interrupts pending', 'fields': IRQF[:1] + IRQF[2:3] + IRQF[4:5]},
    'mtvec': {'addr': 0x305, 'priv': 'MRW', 'desc': 'M trap vector', 'fields': TVEC},
    'stvec': {'addr': 0x105, 'priv': 'SRW', 'desc': 'S trap vector', 'fields': TVEC},
    'mcounteren': {'addr': 0x306, 'priv': 'MRW', 'desc': 'counters visible to S', 'fields': COUNTEREN},
    'scounteren': {'addr': 0x106, 'priv': 'SRW', 'desc': 'counters visible to U', 'fields': COUNTEREN},
    'mscratch': {'addr': 0x340, 'priv': 'MRW', 'desc': 'M scratch', 'fields': []},
    'mepc': {'addr': 0x341, 'priv': 'MRW', 'desc': 'M exception PC (hw fw addr ELF PC)', 'fields': []},
    'mcause': {'addr': 0x342, 'priv': 'MRW', 'desc': 'M trap cause', 'fields': CAUSE},
    'mtval': {'addr': 0x343, 'priv': 'MRW', 'desc': 'M trap value (bad address or instruction)', 'fields': []},
    'sscratch': {'addr': 0x140, 'priv': 'SRW', 'desc': 'S scratch', 'fields': []},
    'sepc': {'addr': 0x141, 'priv': 'SRW', 'desc': 'S exception PC', 'fields': []},
    'scause': {'addr': 0x142, 'priv': 'SRW', 'desc': 'S trap cause', 'fields': CAUSE},
    'stval': {'addr': 0x143, 'priv': 'SRW', 'desc': 'S trap value', 'fields': []},
    'satp': {'addr': 0x180, 'priv': 'SRW', 'desc': 'address translation (Sv32)', 'fields': SATP},
    'pmpcfg0': {'addr': 0x3A0, 'priv': 'MRW', 'desc': 'PMP config entries 0-3', 'fields': PMPCFG},
    'pmpcfg1': {'addr': 0x3A1, 'priv': 'MRW', 'desc': 'PMP config entries 4-7', 'fields': PMPCFG},
    'mcycle': {'addr': 0xB00, 'priv': 'MRW', 'desc': 'cycle counter (low)', 'fields': []},
    'minstret': {'addr': 0xB02, 'priv': 'MRW', 'desc': 'retired instructions (low)', 'fields': []},
    'mhartid': {'addr': 0xF14, 'priv': 'MRO', 'desc': 'hart id', 'fields': []},
    'mvendorid': {'addr': 0xF11, 'priv': 'MRO', 'desc': 'vendor id', 'fields': []},
    'marchid': {'addr': 0xF12, 'priv': 'MRO', 'desc': 'architecture id', 'fields': []},
    'mimpid': {'addr': 0xF13, 'priv': 'MRO', 'desc': 'implementation id', 'fields': []},
    'dcsr': {'addr': 0x7B0, 'priv': 'DRW', 'desc': 'debug control and status', 'fields': DCSR},
    'dpc': {'addr': 0x7B1, 'priv': 'DRW', 'desc': 'debug PC', 'fields': []},
    'seed': {'addr': 0x015, 'priv': 'URW', 'desc': 'Zkr entropy source',
             'fields': [F('entropy', 15, 0), F('OPST', 31, 30, '', {0: 'BIST', 1: 'WAIT', 2: 'ES16', 3: 'DEAD'})]},
}


def decode(name, v):
    c = CSRS[name]
    out = []
    for f in c.get('fields', []):
        x = (v >> f['lo']) & ((1 << (f['hi'] - f['lo'] + 1)) - 1)
        r = {'name': f['name'], 'bits': f['bits'], 'value': x}
        if f.get('values') and x in f['values']:
            r['meaning'] = f['values'][x]
        if f.get('values'):
            r['always'] = True        # an enum's 0 is a value (MPP=U), print it
        out.append(r)
    if name in ('mcause', 'scause'):
        irq, code = v >> 31, v & 0x7FFFFFFF
        what = (IRQ if irq else EXC).get(code)
        summary = '%s %d: %s' % ('interrupt' if irq else 'exception', code, what or 'reserved/custom code')
        out[1]['meaning'] = what
        out[1]['always'] = True
    elif name == 'misa':
        letters = ''.join(chr(65 + i) for i in range(26) if v >> i & 1)
        summary = 'RV%s%s' % ({1: '32', 2: '64'}.get(v >> 30, '?'), letters)
    elif name in ('mtvec', 'stvec'):
        summary = 'base %#010x, %s' % (v & ~3, 'vectored' if v & 1 else 'direct')
    elif name == 'satp':
        summary = 'Bare' if not v >> 31 else 'Sv32, ASID %d, root table at PA %#x' % ((v >> 22) & 0x1FF, (v & 0x3FFFFF) << 12)
    elif name in ('medeleg',):
        summary = 'delegated: ' + (', '.join('%d %s' % (i, EXC[i]) for i in sorted(EXC) if v >> i & 1) or 'none')
    elif c.get('fields'):
        set_ = [r['name'] + ('=' + str(r.get('meaning', r['value'])) if r['value'] > 1 or r.get('values') or 'meaning' in r else '')
                for r in out if r['value'] or 'meaning' in r]
        summary = ' '.join(set_) or 'all fields zero'
    else:
        summary = 'no fields (a plain value)'
    return out, summary
