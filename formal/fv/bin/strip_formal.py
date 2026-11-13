#!/usr/bin/env python3
"""strip_formal.py <in.v> [out.v]: remove formal-only conditional code from RTL -- what the
preprocessor yields with FORMAL, RISCV_FORMAL, RVFI and SDH_FAST undefined; other conditionals
are kept as they are.  For moving verification out of src/ into formal/fv."""
import re, sys
MACROS = {'FORMAL', 'RISCV_FORMAL', 'RVFI', 'SDH_FAST'}
def strip(text):
    out, stack = [], []          # stack entries: (formal?, keeping?) ; non-formal entries pass through
    for line in text.splitlines(keepends=True):
        m = re.match(r'\s*`(ifdef|ifndef|else|endif|elsif)\b\s*(\w*)', line)
        live = all(k for f, k in stack if f)
        if m:
            d, name = m.groups()
            if d in ('ifdef', 'ifndef'):
                f = name in MACROS
                stack.append((f, (d == 'ifndef') if f else True))
                if f: continue
            elif d == 'elsif' and stack and stack[-1][0]:
                sys.exit('elsif under a formal macro: not handled')
            elif d == 'else' and stack:
                f, k = stack[-1]
                if f:
                    stack[-1] = (f, not k); continue
            elif d == 'endif' and stack:
                f, _ = stack.pop()
                if f: continue
        if live:
            out.append(line)
    return ''.join(out)
if __name__ == '__main__':
    t = strip(open(sys.argv[1]).read())
    (open(sys.argv[2], 'w') if len(sys.argv) > 2 else sys.stdout).write(t)
