#!/bin/bash
# formal/sw/ubsan.sh: Proof Obligation's host build under UBSan and ASan (any undefined behaviour
# or bad access stops the run): the 30,000-frame demo with the spec oracle, the random button
# scripts (formal/sw/host_trace.c, build/proof/spec/btn*.txt when present), and the PROOF_TEST
# fight matrix (every boss's moves, every tactic, the HP pins, poke, parry, clean).  The modular
# spec proofs (cbmc/run_rules.sh) assume the frame has no undefined behaviour; this tests it.
set -u
cd "$(dirname "$0")/../../sw/game2d"
D=../../build/proof/ubsan-$(date +%s); mkdir -p $D
F=(-O1 -g -fsanitize=undefined,address -fno-sanitize-recover=undefined -DTITLE_PROOF -I. -I../vdp)
G=(proof.c proof_boss.c proof_sound.c proof_portraits.c proof_spec.c)
cc "${F[@]}" host.c "${G[@]}" ../vdp/vdp_ref.c -o $D/h || exit 1
cc "${F[@]}" ../../formal/sw/host_trace.c "${G[@]}" -o $D/ht || exit 1
cc "${F[@]}" -DPROOF_TEST ../../formal/sw/host_trace.c "${G[@]}" -o $D/htt || exit 1
n=0; bad=0
chk () { n=$((n+1)); if [ $1 != 0 ] || grep -qE "runtime error|AddressSanitizer|^SPEC|spec: frame|spec: init" $2; then
   bad=$((bad+1)); echo "BAD: $3 (rc $1) $(grep -m1 -E 'runtime error|AddressSanitizer|SPEC|spec:' $2)"; fi; }
(cd $D && HOST_SPEC=1 ./h 30000 o.ppm > demo.txt 2>&1); chk $? $D/demo.txt demo
for f in ../../build/proof/spec/btn*.txt; do [ -f "$f" ] || continue; $D/ht 20000 $f $D/t.txt > $D/r.txt 2>&1; chk $? $D/r.txt $(basename $f); done
printf '0\n%.0s' $(seq 3000) > $D/idle.txt
mv=(4 5 4 5 4 5 5)                           # moves per boss (proof_observe's table)
run () { env "$@" $D/htt 2400 $D/idle.txt $D/t.txt > $D/r.txt 2>&1; chk $? $D/r.txt "$*"; }
for b in 0 1 2 3 4 5 6; do
   for m in $(seq 0 $((${mv[$b]} - 1))); do run PROOF_TEST=$b,$m,-1; done
   for w in 0 1 2 3 4 5 6 7; do run PROOF_TEST=$b,0,$w; done
   for hp in 8 16; do run PROOF_TEST=$b,0,-1 PROOF_HP=$hp; done
   run PROOF_TEST=$b,0,-1 PROOF_POKE=1; run PROOF_TEST=$b,0,-1 PROOF_PARRY=1; run PROOF_TEST=$b,0,0 PROOF_CLEAN=1
done
echo "ubsan: $n runs, $bad bad"
[ $bad = 0 ]
