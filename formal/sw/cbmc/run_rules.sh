#!/bin/sh
# formal/sw/cbmc/run_rules.sh [THEOREM ...]: the modular spec proofs of proof_rules.c.  First
# the writer census must match its allow-list (the stubs are only as good as it); then each
# theorem is built with goto-cc, its callees replaced by generated stubs (gen_stubs.py), and
# checked by CBMC, with a vacuity run as in run_proof.sh.  Loops are unwound 42 times (every
# frame loop: 40-character text lines), title_screen's by their sizes (ROWS, WMAX, 64); the unwinding
# assertions must hold, so the bounds are proved enough.
cd "$(dirname "$0")"
OUT=${RULES_OUT:-../../../build/swfv/rules}; mkdir -p $OUT   # RULES_OUT: one dir per concurrent run
# GAME_SRC: another copy of sw/game2d (the mutants); the census and the stubs read it too
[ -n "$GAME_SRC" ] && { GAME_SRC=$(cd "$GAME_SRC" && pwd); export CENSUS_SRC=$GAME_SRC; }
python3 ../census.py --check ../census.allow || exit 1
CHECKS="--bounds-check --pointer-check --pointer-overflow-check --signed-overflow-check
        --undefined-shift-check --div-by-zero-check --unwinding-assertions"
SRC=${GAME_SRC:-../../../sw/game2d}; INC="-I $SRC -I ../../../sw/vdp -I $OUT"
rc=0
for th in ${@:-BD_NOOP S3_FRAME HURT_NOOP S2_FRAME}; do
   fam=${th%%_*}; [ $th = BD_NOOP ] && fam=S3; [ $th = HURT_NOOP ] && fam=S2
   python3 gen_stubs.py $OUT/stubs.h $fam > $OUT/$th.gen.log || { echo "$th: stub generation failed"; rc=1; continue; }
   for v in "" VACUITY; do
      g=$OUT/$th${v:+.vac}.gb
      goto-cc -m32 --little-endian -DTITLE_PROOF -D$th ${v:+-D$v} $INC proof_rules.c -o $g.0 > $OUT/$th.cc.log 2>&1 \
         || { echo "$th: goto-cc failed ($OUT/$th.cc.log)"; rc=1; continue 2; }
      goto-instrument --remove-function-pointers $g.0 $g.1 > /dev/null 2>&1 \
         && goto-instrument $(cat $OUT/stubs.h.calls) $g.1 $g > $OUT/$th.gi.log 2>&1 \
         || { echo "$th: goto-instrument failed ($OUT/$th.gi.log)"; rc=1; continue 2; }
   done
   # the verdict is the theorem's own assertions (main's); the language checks over the whole
   # engine (overflow, bounds) from an arbitrary state are reported, not judged: ruling them out
   # needs range invariants over all of it, which these proofs do not claim (UBSan and the Sail
   # fuzz test it)
   /usr/bin/time -p cbmc $OUT/$th.gb $CHECKS --unwind ${UNWIND:-42} --unwindset ${UNWINDSET:-title_screen.0:193,title_screen.1:31,title_screen.2:65,title_screen.3:65} > $OUT/$th.log 2>&1
   if ! grep -q "^\[main\.assertion" $OUT/$th.log; then r=FAIL; rc=1; echo "$th: no theorem assertions found"
   elif grep "^\[main\.assertion" $OUT/$th.log | grep -q FAILURE; then r=FAIL; rc=1; grep "^\[main\.assertion.*FAILURE" $OUT/$th.log
   elif grep "^\[main\.\(assertion\|unwind\)\|\.unwind\." $OUT/$th.log | grep -q FAILURE; then r="FAIL (unwinding)"; rc=1
   else r=PASS; fi
   ub=$(grep -v "^\[main\.assertion" $OUT/$th.log | grep -c ": FAILURE")
   cbmc $OUT/$th.vac.gb --unwind ${UNWIND:-42} --unwindset ${UNWINDSET:-title_screen.0:193,title_screen.1:31,title_screen.2:65,title_screen.3:65} > $OUT/$th.vacuity.log 2>&1
   grep -q "VERIFICATION FAILED" $OUT/$th.vacuity.log && v="assumptions satisfiable" || { v="VACUOUS"; rc=1; }
   echo "$th: $r ($v, $(grep '^real' $OUT/$th.log | awk '{print $2}') s; language checks not judged: $ub fail from arbitrary states)"
done
exit $rc
