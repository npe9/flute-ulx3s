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
assert s.count(a) == 1, (p, a); open(p, 'w').write(s.replace(a, b))
PY
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
m score_down  proof.c "mins [m].on = 0; score += 100;" "mins [m].on = 0; score -= 1;"
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
echo "$missed missed"
[ $missed = 0 ]
