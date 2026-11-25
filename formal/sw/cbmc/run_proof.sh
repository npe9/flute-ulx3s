#!/bin/sh
# formal/sw/cbmc/run_proof.sh: tier 2 for Proof Obligation's boss algorithms
# (formal/sw/cbmc/proof_algos.c).  PASS = every theorem VERIFICATION SUCCESSFUL, and each
# theorem's assumptions satisfiable (a vacuity run with an assert(0) appended must FAIL).
#   formal/sw/cbmc/run_proof.sh [THEOREM ...]     (default all)
cd "$(dirname "$0")"
OUT=../../../build/swfv/cbmc_proof; mkdir -p $OUT
CHECKS="--ILP32 --unsigned-char --little-endian
        --bounds-check --pointer-check --pointer-overflow-check --signed-overflow-check
        --undefined-shift-check --div-by-zero-check --unwinding-assertions"
INC="-I ../../../sw/game2d -I ../../../sw/vdp"
rc=0
for th in ${@:-COMPILER KSTATE_LIVE KSTATE_CLOSED KSTATE_CONVERGE FIND FIAT KAMI PAXOS_INIT PAXOS_STEP PAXOS_AGREE}; do
   if [ $th = FIND ]; then                   # by exhaustive enumeration over ranks (find_exhaustive.c)
      cc -O2 -fsanitize=address,undefined $INC find_exhaustive.c -Wl,-dead_strip -o $OUT/find_exhaustive \
         && $OUT/find_exhaustive > $OUT/FIND.log 2>&1 && r=PASS || { r=FAIL; rc=1; }
      echo "FIND: $r ($(tail -1 $OUT/FIND.log))"; continue
   fi
   case $th in
   KSTATE_CONVERGE) U="--unwind 26" ;;
   *) U="--unwind 10" ;;
   esac
   /usr/bin/time -p cbmc proof_algos.c $INC -D$th $CHECKS $U > $OUT/$th.log 2>&1
   if grep -q "VERIFICATION SUCCESSFUL" $OUT/$th.log; then r=PASS
   else r=FAIL; rc=1; grep -E "FAILURE" $OUT/$th.log | head -10; fi
   # vacuity: the same assumptions with a false assertion at the end of main must be reachable
   cbmc proof_algos.c $INC -D$th -DVACUITY $U > $OUT/$th.vacuity.log 2>&1
   grep -q "VERIFICATION FAILED" $OUT/$th.vacuity.log && v="assumptions satisfiable" || { v="VACUOUS"; rc=1; }
   echo "$th: $r ($v, $(grep '^real' $OUT/$th.log | awk '{print $2}') s)"
done
exit $rc
