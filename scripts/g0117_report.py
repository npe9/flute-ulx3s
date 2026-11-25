import re, sys, collections
p = sys.argv[1]; t = open(p).read()
rows = []
for m in re.finditer(r'Warning: "([^"]+)", line (\d+), column \d+: \(G0117\)\n(.*?)To silence', t, re.S):
    body = ' '.join(m.group(3).split())
    r = re.search(r"Rule `([^']+)' shadows the effects of `([^']+)' when .*?Affected method calls: (.*)$", body)
    regs = sorted(set(re.sub(r'\d+', 'N', x.strip(' ,')) for x in r.group(3).replace(',', ' ').split()))
    rows.append((m.group(1).split('flute-lx50/')[-1], int(m.group(2)), r.group(1), r.group(2), regs))
N = lambda s: re.sub(r'\d+', 'N', s)
g = collections.OrderedDict()
for f, ln, a, b, regs in rows:
    k = (f, ln, N(a), N(b), ', '.join(r.replace('.write', '') for r in regs)); g[k] = g.get(k, 0) + 1
RESET = re.compile(r'reset|rst|flush|init|start|clear', re.I)
isrule = lambda n: n.startswith('rl_') or '_rl_' in n or n.startswith('m_rl')
cat = {'A': [], 'B': [], 'C': []}
for k, n in g.items():
    a = k[2]
    cat['A' if RESET.search(a) else ('C' if isrule(a) else 'B')].append((k, n))
title = {'A': 'A. A reset / flush / start rule wins over normal work',
         'B': 'B. A method (the caller) wins over an internal rule',
         'C': 'C. One internal rule wins over another'}
print(f'{len(rows)} warnings in {len(g)} groups (numbered copies of one rule folded to N).\n')
for c in 'CBA':
    print(f'### {title[c]} ({len(cat[c])} groups)\n')
    print('| n | where | wins | loses | registers |'); print('|---|---|---|---|---|')
    for (f, ln, a, b, regs), n in cat[c]:
        print(f'| {n} | {f}:{ln} | `{a}` | `{b}` | {regs} |')
    print()
