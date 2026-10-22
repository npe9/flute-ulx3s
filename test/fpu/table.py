#!/usr/bin/env python3
"""Turn build/fpu-tf*/summary.txt (RESULT lines from run.sh matrix) into a markdown op x rm table.
usage: table.py summary.txt [level]     cells: 'fails/total' (value-fails v, flag-fails f), '-' = not run"""
import re, sys
RM = ["RNE", "RTZ", "RDN", "RUP", "RMM"]
want = sys.argv[2] if len(sys.argv) > 2 else "1"
rows = {}
for line in open(sys.argv[1]):
    m = re.match(r"RESULT L(\d) s(\d+) (\S+)\s+rm=(\d) pass=(\d+) fail=(\d+) \(value=(\d+) flags=(\d+)", line)
    if not m or m.group(1) != want: continue
    lvl, s, op, rm, p, f, v, fl = m.groups()
    rows.setdefault(op, {})[int(rm)] = (int(p), int(f), int(v), int(fl), int(s))
order = lambda op: (op.split("_")[0] if not op[0] in "iu" else "z", op)
print(f"| op (level {want}) | " + " | ".join(RM) + " |")
print("|---|" + "---|" * len(RM))
for op in sorted(rows, key=order):
    cells = []
    for rm in range(5):
        if rm not in rows[op]:
            cells.append("-"); continue
        p, f, v, fl, s = rows[op][rm]
        tot = p + f
        sfx = f" (1/{s})" if s > 1 else ""
        cells.append(f"0/{tot}{sfx}" if f == 0 else f"**{f}**/{tot}{sfx} (v{v} f{fl})")
    if re.search(r"_(eq|lt|le)$", op):          # compares: rm field is funct3, run once
        cells = [c for c in cells if c != "-"][:1] + ["n/a"] * 4
    print(f"| {op} | " + " | ".join(cells) + " |")
