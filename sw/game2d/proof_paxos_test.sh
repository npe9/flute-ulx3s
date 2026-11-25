#!/bin/sh
# sw/game2d/proof_paxos_test.sh [RUNS]: Lamport's Paxos as the game runs it (the px_* block of
# proof_boss.c) under RUNS random schedules (default 1,000,000; any order, loss, duplication);
# PASS = agreement held in all of them AND the planted bug (phase 2 ignoring the votes reported)
# is caught.  Tested, not proved.
cd "$(dirname "$0")"
B=../../build/game2d/paxos; mkdir -p $B
{ echo '#include <stdint.h>'; sed -n '/^#define PX_A 3/,/^\/\/ ---- the game around it/p' proof_boss.c; } > $B/px_ext.c
cc -O2 -Wall -Wextra -fsanitize=address,undefined -I$B proof_paxos_test.c -o $B/pxtest && $B/pxtest ${1:-1000000} || { echo FAIL; exit 1; }
sed 's/if (pb > px_phb \[p\]) { px_phb \[p\] = pb; px_pval \[p\] = pv; }/if (pb > px_phb [p]) { px_phb [p] = pb; }/' $B/px_ext.c > $B/px_bug.c
cmp -s $B/px_ext.c $B/px_bug.c && { echo "FAIL: the planted bug did not apply"; exit 1; }
mkdir -p $B/bug && cp $B/px_bug.c $B/bug/px_ext.c
cc -O2 -I$B/bug proof_paxos_test.c -o $B/pxbug
if $B/pxbug ${1:-1000000}; then echo "FAIL: the planted bug was not caught"; exit 1; fi
echo PASS
