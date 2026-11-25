#!/usr/bin/env python3
# formal/sw/cbmc/gen_stubs.py OUT.h FAMILY: the stubs that replace proof_frame's callees in a
# modular spec proof (proof_rules.c).  From the census (formal/sw/census.py: who writes each
# rule variable, who may reach the writers), each stub of a callee f
#   - havocs every non-const global of the engine that is not a rule variable (f may write any
#     of them; over-approximating is sound),
#   - havocs each rule variable f may write, except the family's own variables,
#   - and, if f may reach a writer of the family's variables, calls the family's writer
#     contract instead (FAMILY_CALLS below), which is the real writer.
# It returns an arbitrary value of its return type.  The family's variables then change only
# through proof_frame's own code and the real writers, which is what the census allows.
# Also writes OUT.calls: the goto-instrument --replace-calls arguments.
import io, contextlib, os, runpy, sys

HERE = os.path.dirname(os.path.abspath(__file__))
out, family = sys.argv[1], sys.argv[2]
buf = io.StringIO()
sys.argv = ['census.py']
with contextlib.redirect_stdout(buf):
   C = runpy.run_path(os.path.join(HERE, '..', 'census.py'))

# the families: their variables (kept, never havocked by a stub) and the writer call a stub makes
# and the callees kept real because a stub would lose a correlation the family needs (next_demo
# and title_screen clear the boss only together with going to the title)
# per family: its variables; the real writers a stub may call; how a stub that may reach some of
# them (the set R) calls them; the callees kept real; what the writers' guards read.
#   S3: one boss_damage call is enough (BD_NOOP: the flash it sets makes a second do nothing)
#   S2: one effective player_hurt a frame (HURT_NOOP: the invulnerability it sets makes the rest
#       do nothing until player_update counts it down, which no stub reaches); bullets_update
#       takes at most one pickup per bullet slot (its loop runs pickup_update once per slot),
#       interleaved with hurts in any order
def s3_call (R):
   return 'if (nondet_int ()) boss_damage (nd (1, 4));'
def s2_call (R):
   if 'pickup_update' in R:
      hurt = ' else if (nondet_int ()) player_hurt ();' if 'player_hurt' in R else ''
      return ('for (int k = 0; k < NBUL; k++) { if (nondet_int ()) pickup_update (&bul [k]);%s }   '
              '// pickups and hurts, any order' % hurt)
   return 'if (nondet_int ()) player_hurt ();'
FAMILIES = {
   'S3': (['boss.hp', 'boss.flash'], {'boss_damage'}, s3_call, {'next_demo', 'title_screen'},
          ['g_state', 'boss.on', 'boss.flash']),
   'S2': (['pl_lives', 'pl_dead', 'pl_hurt', 'got_hearts'], {'player_hurt', 'pickup_update'}, s2_call,
          {'next_demo', 'title_screen', 'player_update', 'start_stage'},
          ['g_state', 'pl_hurt', 'pl_dead', 'pl_lives']),
}
KEEP, WRITERS, CALL, ALSO_REAL, GUARD_READS = FAMILIES[family]
# a stub havocs, then calls the writers, so it cannot reproduce a callee that writes and then
# changes what a writer's guard reads (GUARD_READS); such a callee must stay real (or be refused)
# never stubbed: the frame itself, the observation and the family's writers
REAL = {'proof_frame', 'proof_observe'} | WRITERS | ALSO_REAL

found, CALLS, FIELD_FN = C['found'], C['CALLS'], C['FIELD_FN']
rule_vars = C['VARS'] + ['boss.' + f for f in C['BOSS_FIELDS']]
writers = {v: {x.replace('(&)', '') for x in found.get(v, ())} for v in rule_vars}
may = {v: C['reaches'](writers[v]) for v in rule_vars}

# the callees to stub: proof_frame's, with the boss table's update functions for the indirect call
callees = set()
for c in CALLS['proof_frame']:
   if c.startswith('<indirect:'): callees |= FIELD_FN[c[10:-1]]
   elif c != '<indirect>': callees.add(c)
# and the callees of the functions kept real, to any depth, until a stub cuts the call tree
todo = sorted(ALSO_REAL)
while todo:
   g = todo.pop()
   for c in CALLS.get(g, ()):
      if c.startswith('<indirect'): continue
      if c in REAL or c in callees: continue
      callees.add(c)
callees -= REAL

def reach_from (f):
   seen, todo = set(), [f]
   while todo:
      g = todo.pop()
      if g in seen: continue
      seen.add(g)
      for c in CALLS.get(g, ()):
         if c.startswith('<indirect:'): todo += sorted(FIELD_FN.get(c[10:-1], ()))
         elif c == '<indirect>': todo += sorted(C['ADDR_FN'])
         else: todo.append(c)
   return seen

# the engine's globals and the callees' signatures, from the same AST
globs, sigs = {}, {}
def scan(node, top):
   k = node.get('kind')
   if top and k == 'VarDecl' and node.get('storageClass') != 'extern':
      q = node['type']['qualType']
      if not q.startswith('const ') and '*const' not in q.replace(' ', '') and not ('const' in q.split('[')[0]):
         globs[node['name']] = q
   if k == 'FunctionDecl' and node.get('name') in callees and 'inner' in node:
      sigs[node['name']] = node
   for c in node.get('inner', []):
      if isinstance(c, dict) and c.get('kind') in ('TranslationUnitDecl',): scan(c, True)
for f in ['proof.c', 'proof_boss.c']:              # the files proof_rules.c includes
   tu = C['ast'](f)
   for n in tu.get('inner', []): scan(n, True)
# a callee defined outside the included files (proof_sound.c) stays bodyless: CBMC gives it no
# side effects, which is sound only if the census says it writes no rule variable and reaches
# no writer of one
bodyless = callees - set(sigs)
for f in bodyless:
   bad = [v for v in rule_vars if f in writers[v] or f in may[v]]
   if bad: sys.exit('gen_stubs: %s is not in the included files but may write %s' % (f, ' '.join(bad)))
callees -= bodyless

plain_rule = {v for v in rule_vars if not v.startswith('boss.')}
lines = ['// generated by formal/sw/cbmc/gen_stubs.py %s: do not edit' % family,
         'static void havoc_nonrule (void) {']
for g in sorted(globs):
   if g in plain_rule or g == 'boss': continue
   lines.append('   __CPROVER_havoc_object (&%s);' % g)
lines.append('}')
lines.append('static void havoc_boss_except (int hp, int flash, int on, int attack) {   // 1: keep it')
lines.append('   boss_t b = boss; __CPROVER_havoc_object (&boss);')
lines.append('   if (hp) boss.hp = b.hp; if (flash) boss.flash = b.flash; if (on) boss.on = b.on; if (attack) boss.attack = b.attack;')
lines.append('}')
calls = []
for f in sorted(callees):
   n = sigs[f]
   ret = n['type']['qualType'].split('(')[0].strip()
   params = [p for p in n.get('inner', []) if p.get('kind') == 'ParmVarDecl']
   plist = ', '.join('%s %s' % (p['type']['qualType'], p.get('name', 'a%d' % i)) for i, p in enumerate(params)) or 'void'
   # the non-rule globals f may write: those whose writers f can reach, and every escaped one
   # (a pointer to it may be written anywhere)
   rf = reach_from (f)
   body = ['   __CPROVER_havoc_object (&%s);' % g for g in sorted(globs)
           if g not in plain_rule and g != 'boss' and (g in C['ESC'] or C['ALLW'].get(g, set()) & rf)]
   bossf = {}
   boss_any = 'boss' in C['ESC'] or bool(C['ALLW'].get('boss', set()) & rf)   # any field of boss
   for v in rule_vars:
      if f not in writers[v] and f not in may[v]: continue
      if v in KEEP: continue
      if v.startswith('boss.'): bossf[v[5:]] = 1; continue
      # the writers of v that f can reach: if each writes only constants, f leaves v alone or
      # sets it to one of them; otherwise anything
      seen, todo, ws = set(), [f], set()
      while todo:
         g = todo.pop()
         if g in seen: continue
         seen.add(g)
         if g in writers[v]: ws.add(g)
         for c in CALLS.get(g, ()):
            if c.startswith('<indirect:'): todo += sorted(FIELD_FN.get(c[10:-1], ()))
            elif c == '<indirect>': todo += sorted(C['ADDR_FN'])
            else: todo.append(c)
      cs = set()
      for g in ws:
         k = C['CONSTW'].get((v, g), None)
         if k is None: cs = None; break
         cs |= k
      if cs:
         alts = ' else '.join('if (nondet_int ()) %s = %s;' % (v, c) for c in sorted(cs))
         body.append('   %s   // %s writes only these' % (alts, ' '.join(sorted(ws))))
      else: body.append('   __CPROVER_havoc_object (&%s);' % v)
   keep = lambda fld: 0 if fld in bossf else 1
   # the boss's other fields (position, phase, ...) change whenever f may write any field; the
   # rule fields only when f may write them (and never the family's own)
   if bossf or boss_any:
      kp = lambda fld: 1 if ('boss.' + fld) in KEEP else keep (fld)
      body.append('   havoc_boss_except (%d, %d, %d, %d);' % (kp('hp'), kp('flash'), kp('on'), kp('attack')))
   R = {w for w in WRITERS if w in reach_from (f)}
   left = [v for v in KEEP if (f in may[v] or f in writers[v]) and not (writers[v] & reach_from (f) <= WRITERS | REAL)]
   if left: sys.exit('gen_stubs: %s may write %s through a writer that is not the family\'s' % (f, ' '.join(left)))
   if R:
      bad = [v for v in GUARD_READS if v not in KEEP and (f in writers[v] or f in may[v])]
      if bad: sys.exit('gen_stubs: %s reaches the writer and may also write %s, which its guard reads:'
                       ' a stub would be unsound; keep it real' % (f, ' '.join(bad)))
      body.append('   ' + CALL (R))
   if ret != 'void': body.append('   %s r; return r;' % ret)
   lines.append('%s stub_%s (%s) {' % (ret, f, plist))   # external: goto-cc keeps it
   lines += body
   lines.append('}')
   calls.append('--replace-calls %s:stub_%s' % (f, f))
open(out, 'w').write('\n'.join(lines) + '\n')
open(out + '.calls', 'w').write(' '.join(calls) + '\n')
print('gen_stubs %s: %d stubs, %d globals havocked' % (family, len(calls), len(lines)))
