#!/bin/bash
# formal/sw/spec_mutants.sh: planted engine bugs that Proof Obligation's specification
# (sw/game2d/proof_spec.c, notes/proof-obligation-spec.md) must catch.  Each mutant is a fresh
# copy of the sources (build/swfv/specmut/<time>/<name>/) with one edit, run on the host for
# 30,000 attract-demo frames with HOST_SPEC=1; the first violated clause is printed.
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../.." && pwd)
M=$R/build/swfv/specmut/$(date +%Y%m%d-%H%M%S); mkdir -p "$M"
S=(host.c proof.c proof_boss.c proof_sound.c proof_portraits.c proof_spec.c ../vdp/vdp_ref.c)
missed=0
m () {   # name file "from" "to"
   d=$M/$1; mkdir -p "$d/sw"
   cp -R "$R/sw/game2d" "$R/sw/vdp" "$R/sw/apu" "$d/sw/"
   python3 - "$d/sw/game2d/$2" "$3" "$4" <<'PY'
import sys
p, a, b = sys.argv[1:]; s = open(p).read()
if s.count(a) != 1: sys.exit("anchor not found once: %r" % a)
open(p, 'w').write(s.replace(a, b))
PY
   [ $? = 0 ] || { echo "$1: ANCHOR FAILED (the source changed; update the mutant)"; missed=$((missed + 1)); return; }
   if ! (cd "$d/sw/game2d" && cc -O1 -DTITLE_PROOF -I. -I../vdp "${S[@]}" -o "$d/h") > "$d/build.log" 2>&1; then
      echo "$1: BUILD FAILED"; missed=$((missed + 1)); return; fi
   r=$(cd "$d" && HOST_SPEC=1 ./h 30000 o.ppm | grep -m1 -E "spec: (frame|init)")
   if [ -n "$r" ]; then echo "$1: caught ($r)"; else echo "$1: MISSED"; missed=$((missed + 1)); fi
}
# S3: a boss can be hit while flashing
m flash_guard proof.c "   if (boss.flash) return;
   boss.hp -= n;" "   boss.hp -= n;"
# S2: a heart can be lost while invulnerable
m hurt_guard  proof.c "   if (pl_hurt || pl_dead || g_state == G_WIN) return;" "   if (pl_dead || g_state == G_WIN) return;"
# S5: a defeated minion takes a point
m score_down  proof.c "   n->on = 0; score += 100;" "   n->on = 0; score -= 1;"
# S4: the demo discharges bosses
m demo_win    proof.c "         if (!demo) defeated |= 1 << cur_boss;" "         defeated |= 1 << cur_boss;"
# S6: the camera leads by 150, not 140
m cam_lead    proof.c "int want = pl_x - 140;" "int want = pl_x - 150;"
# N2: a stage starts with six hearts
m lives6      proof.c "pl_vy = 0; pl_lives = 5;" "pl_vy = 0; pl_lives = 6;"
# V2: a VDP write outside the flush (it could land mid-screen)
m stray_write proof.c "   psnd_frame ();
   g_timer++;" "   psnd_frame ();
   if ((t & 255) == 0) hw_vdp_write (VDP_BACKDROP, 1);
   g_timer++;"
# W4: TICK costs 6, not 7
m tick_cost   proof.c "w_cost [NWEAPON] = { 0, 1, 2, 4, 7, 2, 1, 3 };" "w_cost [NWEAPON] = { 0, 1, 2, 4, 6, 2, 1, 3 };"
# W3: the demo lacks PATH
m demo_owned  proof.c "pl_owned = demo ? (1 << NWEAPON) - 1 :" "pl_owned = demo ? (1 << NWEAPON) - 5 :"
# (W5's refill bound has no mutant: the demo's few energy pickups all find a tactic within 4 of
# full, so a wrong refill is hidden by the cap; notes/proof-obligation-spec.md)
# S2: a heart that no pickup gave
m free_heart  proof.c "{ got_hearts++; if (pl_lives < 5) pl_lives++; return; }" "{ if (pl_lives < 5) pl_lives++; return; }"
echo "$missed missed"
[ $missed = 0 ]
