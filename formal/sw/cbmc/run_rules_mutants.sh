#!/bin/sh
# formal/sw/cbmc/run_rules_mutants.sh: each planted bug in the engine must make run_rules.sh fail
# the named theorem.  A mutant edits a fresh copy of sw/ (the census and the stubs read the copy,
# so a mutant that changed a writer set would fail the census instead, which also counts).
cd "$(dirname "$0")"
ROOT=../../..; B=$ROOT/build/swfv/rules-mut; n=0; caught=0
m () {   # name theorem "from" "to"
   n=$((n + 1)); d=$B/$1-$(date +%s); mkdir -p $d && cp -R $ROOT/sw/game2d $ROOT/sw/vdp $ROOT/sw/apu $d/
   FROM="$3" TO="$4" python3 -c "
import os; p='$d/game2d/proof.c'; s=open(p).read(); a=os.environ['FROM']
if s.count(a) != 1: raise SystemExit('anchor not found once: ' + a)
open(p,'w').write(s.replace(a, os.environ['TO']))" || { echo "$1: ANCHOR MISSING"; return; }
   if GAME_SRC=$d/game2d sh run_rules.sh $2 > $d.log 2>&1; then echo "$1: survived ($2 passed)"
   else caught=$((caught + 1)); echo "$1: caught ($(grep -E "^$2:|^census" $d.log | tail -1))"; fi
}
m flash_guard S3_FRAME "|| !boss.on || boss.flash) return;" "|| !boss.on) return;"
m fight_guard S3_FRAME "if (g_state != G_FIGHT || !boss.on || boss.flash) return;" "if (!boss.on || boss.flash) return;"
m win_late    S3_FRAME "      if (boss.hp <= 0) {" "      if (boss.hp < 0) {"
echo "rule mutants: $caught of $n caught"
[ $caught = $n ]
