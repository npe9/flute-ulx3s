#!/bin/sh
# formal/sw/cbmc/run_proof_mutants.sh: planted bugs that run_proof.sh's theorems must catch.
# Each is a copy of sw/game2d/proof_boss.c (build/swfv/cbmut_proof/<name>/) with one edit, run
# against the one theorem it breaks.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
M=$REPO/build/swfv/cbmut_proof
CHECKS="--ILP32 --unsigned-char --little-endian --bounds-check --pointer-check
        --pointer-overflow-check --signed-overflow-check --undefined-shift-check
        --div-by-zero-check --unwinding-assertions"
missed=0
m () {   # name theorem unwind "from" "to"
   d=$M/$1; rm -rf "$d"; mkdir -p "$d"
   cp "$REPO/sw/game2d/proof_boss.c" "$d/"
   python3 - "$d/proof_boss.c" "$4" "$5" <<'PY'
import sys
p, a, b = sys.argv[1:]; s = open(p).read()
assert s.count(a) == 1, (p, a); open(p, 'w').write(s.replace(a, b))
PY
   if [ $2 = FIND ]; then
      (cd "$HERE" && cc -O2 -fsanitize=address,undefined -I "$REPO/sw/game2d" -I "$REPO/sw/vdp" \
         "-DBOSS_SRC=\"$d/proof_boss.c\"" find_exhaustive.c -Wl,-dead_strip -o "$d/fx" && "$d/fx") > "$d/run.log" 2>&1 \
         && { echo "$1: MISSED"; missed=$((missed + 1)); } || echo "$1: caught by FIND ($(grep -m1 -E 'FAIL|ERROR|runtime' "$d/run.log" | cut -c1-80))"
      return
   fi
   (cd "$HERE" && cbmc proof_algos.c -I "$REPO/sw/game2d" -I "$REPO/sw/vdp" -D$2 \
      "-DBOSS_SRC=\"$d/proof_boss.c\"" $CHECKS --unwind $3) > "$d/run.log" 2>&1
   if grep -q "VERIFICATION SUCCESSFUL" "$d/run.log"; then echo "$1: MISSED"; missed=$((missed + 1))
   else echo "$1: caught by $2 ($(grep -m1 'FAILURE' "$d/run.log" | sed 's/^ *//' | cut -c1-80))"; fi
}
# the compiler emits the two operators in the wrong order
m compile_order COMPILER 10 "mc_code [3] = mc_o2; mc_code [4] = mc_o1; }" "mc_code [3] = mc_o1; mc_code [4] = mc_o2; }"
# a machine i > 0 copies its neighbour's value plus one (not Dijkstra's rule)
m kstate_copy KSTATE_CLOSED 10 "else ss_x [i] = ss_x [i - 1]; }" "else ss_x [i] = (ss_x [i - 1] + 1) % SS_K; }"
# FIND's left scan does not stop at an element equal to the pivot
m find_scan FIND 77 "case 1: if (fd_a [fd_i] < fd_r) fd_i++;" "case 1: if (fd_a [fd_i] <= fd_r) fd_i++;"
# a carry takes 9 from its limb, not 10
m fiat_carry FIAT 10 "if (ft_l [i] > 9) { ft_l [i] -= 10;" "if (ft_l [i] > 9) { ft_l [i] -= 9;"
# the pipeline shifts front to back, so one input fills every stage
m kami_shift KAMI 10 "for (int s = 2; s > 0; s--) { km_q [s][0]" "for (int s = 1; s < 3; s++) { km_q [s][0]"
# Paxos phase 2 ignores the votes the promises reported (proof_paxos_test.sh's planted bug)
m px_votes PAXOS_STEP 10 "if (pb > px_phb [p]) { px_phb [p] = pb; px_pval [p] = pv; }" "if (pb > px_phb [p]) { px_phb [p] = pb; }"
# a proposer goes to phase 2 on one promise, not a quorum of two
m px_quorum PAXOS_STEP 10 "   if (n < 2) return 0;
   px_pph [p] = 2;" "   if (n < 1) return 0;
   px_pph [p] = 2;"
# an acceptor votes in a ballot below the one it promised
m px_promise PAXOS_STEP 10 "|| v < 1 || b < px_prom [a]) return 0;" "|| v < 1) return 0;"
# both proposers may use every ballot (two values proposed in one ballot)
m px_owner PAXOS_STEP 10 "|| (b - 1) % 2 != p ||" "||"
# the learner learns from one acceptor's Accepted
m px_learn PAXOS_STEP 10 "for (int j = i + 1; j < PX_A; j++)" "for (int j = i; j < PX_A; j++)"
echo "$missed missed"
[ $missed = 0 ]
