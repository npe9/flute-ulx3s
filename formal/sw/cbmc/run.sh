#!/bin/sh
# formal/sw/cbmc/run.sh: tier 2 (notes/sw-verification-plan.md): the base case and the
# inductive step of formal/sw/cbmc/lantern_harness.c.  PASS = both VERIFICATION SUCCESSFUL.
#   formal/sw/cbmc/run.sh [base|step]     (default both)
cd "$(dirname "$0")"
OUT=../../../build/swfv/cbmc; mkdir -p $OUT
CHECKS="--bounds-check --pointer-check --pointer-overflow-check --signed-overflow-check
        --undefined-shift-check --div-by-zero-check --unwinding-assertions"
rc=0
for h in ${1:-base step}; do
   case $h in
   base) U="--unwind 2050 --object-bits 12" ;;        # lantern_init's loops are concrete
   step) U="--unwind 13" ;;                            # N_LOG = 12 is the longest frame loop
   esac
   D=$(echo $h | tr a-z A-Z)
   /usr/bin/time -p cbmc lantern_harness.c -DHARNESS_$D $CHECKS $U > $OUT/$h.log 2>&1
   if [ $h = step ]; then                # the assumed invariant must be satisfiable
      cbmc lantern_harness.c -DHARNESS_STEP -DVACUITY --unwind 13 > $OUT/vacuity.log 2>&1
      grep -q "VERIFICATION FAILED" $OUT/vacuity.log && echo "step: INV satisfiable" \
         || { echo "step: VACUOUS (INV unsatisfiable)"; rc=1; }
   fi
   if grep -q "VERIFICATION SUCCESSFUL" $OUT/$h.log; then echo "$h: PASS"
   else echo "$h: FAIL"; grep -E "FAILURE|^\[.*\] .* (line|FAIL)" $OUT/$h.log | grep FAIL | head -20; rc=1; fi
done
exit $rc
