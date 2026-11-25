#!/usr/bin/env python3
# formal/sw/census.py: who writes the variables Proof Obligation's specification is about.
# From clang's AST of the board build (-DTITLE_PROOF, no PROOF_TEST), list for each rule
# variable every function that assigns it (=, op=, ++, --), whole or in part (an element, a
# field), or takes its address (after which anything could write it).  The modular proofs of
# the spec (formal/sw/cbmc/proof_rules.c) prove a contract for each writer; this census is what
# makes "the writers" a checked set.  With --check ALLOW, fail if the census differs from the
# allow-list (one "variable: function function ..." line each).
#   formal/sw/census.py [--check formal/sw/census.allow]
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
G = os.environ.get('CENSUS_SRC') or os.path.join(HERE, '..', '..', 'sw', 'game2d')
FILES = ['proof.c', 'proof_boss.c', 'proof_sound.c', 'proof_portraits.c']
# the observed state: plain globals, and fields of the global struct boss
VARS = ['g_state', 'demo', 'cur_boss', 'defeated', 'pl_lives', 'pl_dead', 'pl_hurt', 'pl_certs',
        'score', 'pl_weapon', 'pl_owned', 'pl_energy', 'got_hearts', 'got_energy', 't']
BOSS_FIELDS = ['hp', 'flash', 'on', 'attack']
ARG_CHECK = {'boss_damage'}               # writers whose argument range the proofs assume

def ast(f):
    out = subprocess.run(['clang', '-fsyntax-only', '-DTITLE_PROOF', '-I', G, '-I', os.path.join(G, '..', 'vdp'),
                          '-Xclang', '-ast-dump=json', os.path.join(G, f)], capture_output=True, text=True)
    if out.returncode: sys.exit('census: clang failed on %s:\n%s' % (f, out.stderr[-2000:]))
    return json.loads(out.stdout)

def base_name(e):
    """The rule variable an lvalue denotes (a global, an element of one, boss.<field>), or None."""
    while True:
        k = e.get('kind')
        if k in ('ImplicitCastExpr', 'ParenExpr'): e = e['inner'][0]; continue
        if k == 'ArraySubscriptExpr': e = e['inner'][0]; continue
        if k == 'MemberExpr':
            inner = e['inner'][0]
            while inner.get('kind') in ('ImplicitCastExpr', 'ParenExpr'): inner = inner['inner'][0]
            if inner.get('kind') == 'DeclRefExpr' and inner['referencedDecl'].get('name') == 'boss':
                return 'boss.' + e['name'] if e['name'] in BOSS_FIELDS else None
            if inner.get('kind') == 'DeclRefExpr' and inner['referencedDecl'].get('name') == 'boss' :
                return None
            e = inner; continue
        if k == 'DeclRefExpr':
            d = e['referencedDecl']
            if d.get('kind') != 'VarDecl': return None
            n = d.get('name')
            if n == 'boss': return 'boss'              # the whole struct
            return n if n in VARS else None
        return None

CONSTW = {}                               # (variable, function) -> the constants written, or None
CALLS, ADDR_FN, ARGS = {}, set(), {}      # caller -> callees; functions whose address is taken
RECID = {}
FIELDS, FIELD_FN = {}, {}                 # struct -> field names; field -> functions stored in it
def strip(e):
    while e.get('kind') in ('ImplicitCastExpr', 'ParenExpr'): e = e['inner'][0]
    return e
def const_vals(e):
    """The values an argument can take, if it is a literal or a ?: of literals; else None."""
    e = strip(e)
    if e.get('kind') == 'IntegerLiteral': return {int(e['value'])}
    if e.get('kind') == 'ConditionalOperator':
        a, b = const_vals(e['inner'][1]), const_vals(e['inner'][2])
        return a | b if a is not None and b is not None else None
    return None
def walk(node, fn, found):
    k = node.get('kind')
    if k == 'FunctionDecl' and 'inner' in node: fn = node['name']
    if k == 'CallExpr':
        callee = strip(node['inner'][0])
        if callee.get('kind') == 'DeclRefExpr' and callee['referencedDecl'].get('kind') == 'FunctionDecl':
            name = callee['referencedDecl']['name']
            CALLS.setdefault(fn, set()).add(name)
            if name in ARG_CHECK:
                v = const_vals(node['inner'][1]) if len(node['inner']) > 1 else None
                ARGS.setdefault(name, []).append((fn, v))
            callee['_callee'] = True
        elif callee.get('kind') == 'MemberExpr':          # through a table's field: its targets
            CALLS.setdefault(fn, set()).add('<indirect:%s>' % callee['name'])
        else: CALLS.setdefault(fn, set()).add('<indirect>')
    if k == 'RecordDecl' and node.get('name') and 'inner' in node:
        FIELDS[node['name']] = [c['name'] for c in node['inner'] if c.get('kind') == 'FieldDecl']
    if k == 'TypedefDecl' and node.get('name') and node.get('inner'):   # typedef struct {...} name
        rec = [c for c in node['inner'] if c.get('kind') == 'ElaboratedType']
        for c in node['inner']:
            d = c.get('ownedTagDecl') or (c.get('inner', [{}])[0].get('ownedTagDecl') if c.get('inner') else None)
            if d and d.get('id') in RECID: FIELDS[node['name']] = RECID[d['id']]
    if k == 'RecordDecl' and 'inner' in node: RECID[node['id']] = [c['name'] for c in node['inner'] if c.get('kind') == 'FieldDecl']
    if k == 'InitListExpr':                               # a struct of a known type: field i = element i
        ty = node.get('type', {}).get('qualType', '').replace('const ', '')
        if ty in FIELDS:
            for name, el in zip(FIELDS[ty], node.get('inner', [])):
                el = strip(el)
                if el.get('kind') == 'DeclRefExpr' and el['referencedDecl'].get('kind') == 'FunctionDecl':
                    FIELD_FN.setdefault(name, set()).add(el['referencedDecl']['name']); el['_callee'] = True
    if k == 'DeclRefExpr' and node['referencedDecl'].get('kind') == 'FunctionDecl' and not node.get('_callee'):
        ADDR_FN.add(node['referencedDecl']['name'])
    lhs = None
    if k in ('BinaryOperator', 'CompoundAssignOperator') and node.get('opcode', '').endswith('=') \
       and node['opcode'] not in ('==', '!=', '<=', '>='):
        lhs = node['inner'][0]
    elif k == 'UnaryOperator' and node.get('opcode') in ('++', '--'):
        lhs = node['inner'][0]
    elif k == 'UnaryOperator' and node.get('opcode') == '&':
        v = base_name(node['inner'][0])
        if v: found.setdefault(v, set()).add((fn or '<file scope>') + '(&)')
    if lhs is not None:
        v = base_name(lhs)
        if v and v != 'boss':                           # what is written: a constant (a literal, an
            rhs = strip(node['inner'][1]) if k == 'BinaryOperator' and node['opcode'] == '=' else None
            c = None                                    # enum constant) or something else (None)
            if strip(lhs).get('kind') == 'ArraySubscriptExpr': rhs = None   # an element: not the whole
            if rhs is not None and rhs.get('kind') == 'IntegerLiteral': c = rhs['value']
            elif rhs is not None and rhs.get('kind') == 'DeclRefExpr' and rhs['referencedDecl'].get('kind') == 'EnumConstantDecl':
                c = rhs['referencedDecl']['name']
            key = (v, fn or '<file scope>')
            if c is None or (key in CONSTW and CONSTW[key] is None): CONSTW[key] = None
            else: CONSTW.setdefault(key, set()).add(c)
        if v:
            if v == 'boss':                             # a whole-struct write touches every field
                for f in BOSS_FIELDS: found.setdefault('boss.' + f, set()).add(fn or '<file scope>')
            else: found.setdefault(v, set()).add(fn or '<file scope>')
    if k == 'ImplicitCastExpr' and node.get('castKind') == 'ArrayToPointerDecay' and not node.get('_subscript'):
        v = base_name(node['inner'][0])                 # an array passed as a pointer
        if v: found.setdefault(v, set()).add((fn or '<file scope>') + '(&)')
    if k == 'ArraySubscriptExpr':                       # a[i]: the decay of a is not an escape
        b0 = node['inner'][0]
        if b0.get('kind') == 'ImplicitCastExpr': b0['_subscript'] = True
    for c in node.get('inner', []):
        if isinstance(c, dict): walk(c, fn, found)

found = {}
for f in FILES: walk(ast(f), None, found)
lines = ['%s: %s' % (v, ' '.join(sorted(found.get(v, ())))) for v in VARS + ['boss.' + f for f in BOSS_FIELDS]]
# the call graph: a function may write v if it writes v or may call one that does; an indirect
# call may reach any function whose address is taken
def reaches(writers):
    may = set(writers); changed = True
    while changed:
        changed = False
        for f, cs in CALLS.items():
            if f in may or f is None: continue
            ind = set()
            for c in cs:
                if c == '<indirect>': ind |= ADDR_FN
                elif c.startswith('<indirect:'): ind |= FIELD_FN.get(c[10:-1], set()) or ADDR_FN
            if cs & may or ind & may: may.add(f); changed = True
    return may
for v in VARS + ['boss.' + f for f in BOSS_FIELDS]:
    w = {x.replace('(&)', '') for x in found.get(v, ())}
    lines.append('may write %s: %s' % (v, ' '.join(sorted(reaches(w) - w))))
for fld in sorted(FIELD_FN): lines.append('field %s: %s' % (fld, ' '.join(sorted(FIELD_FN[fld]))))
lines.append('other address-taken functions: %s' % ' '.join(sorted(ADDR_FN - set().union(*FIELD_FN.values()))))
for f in sorted(ARG_CHECK):
    vals = set(); bad = []
    for caller, v in ARGS.get(f, []):
        if v is None: bad.append(caller)
        else: vals |= v
    lines.append('%s args: %s%s' % (f, ' '.join(map(str, sorted(vals))), (' NONCONSTANT in ' + ' '.join(sorted(bad))) if bad else ''))
lines = [l.rstrip() for l in lines]
if len(sys.argv) == 3 and sys.argv[1] == '--check':
    want = [l.rstrip() for l in open(sys.argv[2]) if l.strip() and not l.startswith('#')]
    if want != lines:
        import difflib
        print('census: the writers of the rule variables changed (update the proofs and %s):' % sys.argv[2])
        print('\n'.join(difflib.unified_diff(want, lines, 'allowed', 'now', lineterm='')))
        sys.exit(1)
    print('census: %d lines (writers, callers, arguments) as allowed' % len(lines))
else:
    print('\n'.join(lines))
