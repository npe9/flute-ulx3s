#!/bin/sh
# formal/sw/cbmc/mutants.sh: planted bugs tier 2 (run.sh) must catch.  Like formal/sw/mutants.sh,
# each is a copy of the sources (build/swfv/cbmut/<name>/) with one edit.  Some are out of the
# fuzzer's reach (states its scripts never produce); CBMC sees every state INV allows.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
M=$REPO/build/swfv/cbmut
missed=0
m () {   # name file "from" "to"
   d=$M/$1; rm -rf "$d"; mkdir -p "$d/sw" "$d/formal/sw/cbmc"
   cp -R "$REPO/sw/game2d" "$REPO/sw/vdp" "$REPO/sw/apu" "$d/sw/"
   cp "$HERE/lantern_harness.c" "$HERE/run.sh" "$d/formal/sw/cbmc/"
   python3 - "$d/$2" "$3" "$4" <<'PY'
import sys
p, a, b = sys.argv[1:]; s = open(p).read()
assert s.count(a) == 1, (p, a); open(p, 'w').write(s.replace(a, b))
PY
   if "$d/formal/sw/cbmc/run.sh" > "$d/run.log" 2>&1; then echo "$1: MISSED"; missed=$((missed + 1))
   else echo "$1: caught ($(grep -m1 -E 'FAIL|VACUOUS' "$d/run.log" | cut -c1-60); $(grep -m1 'FAILURE' "$d/run.log" | cut -c1-90))"; fi
}
# S1 (base): the sprite clear loop runs one past the table
m initoob   sw/game2d/lantern.c "for (int i = 0; i < 64; i++) spr (i, 0, 0, 0, 0, 0);" \
                                "for (int i = 0; i <= 64; i++) spr (i, 0, 0, 0, 0, 0);"
# S1 (step): only when every log is on (a state the fuzz scripts never reached): spawns into slot 12
m logsfull  sw/game2d/lantern.c "logs [i].vy = 1 + (int) (rnd () % 2) + (score > 300); break;
         }" "logs [i].vy = 1 + (int) (rnd () % 2) + (score > 300); break;
         }
         if (logs [N_LOG - 1].on && logs [0].on && logs [5].on) spr (S_FLY + N_FLY + 36, 0, 0, 0, 0, 0);"
# S3: the chime keyed before its pitch is written (the first firefly would play a stale pitch)
m keyorder  sw/game2d/sound.c   "w (APU_PITCH (6), note_pitch (91)); w (APU_KEYON, 0x40);" \
                                "w (APU_KEYON, 0x40); w (APU_PITCH (6), note_pitch (91));"
# S3: a voice keyed that sound_init never configured
m keyvoice  sw/game2d/sound.c   "void sound_crash (void) { w (APU_KEYON, 0x80); }" \
                                "void sound_crash (void) { w (APU_KEYON, 0xA0); }"
# INV: the boat can leave the river on the right
m boatedge  sw/game2d/lantern.c "if (bx > 8 * RIVER_R - 8) bx = 8 * RIVER_R - 8;" \
                                "if (bx > 8 * RIVER_R - 6) bx = 8 * RIVER_R - 6;"
# INV: a crash during the hurt time (lives can go below zero: a second crash at a game over)
m hurtcrash sw/game2d/lantern.c "else if (!hurt && hit (bx, by, logs [i].x, logs [i].y, 3)) {" \
                                "else if (hit (bx, by, logs [i].x, logs [i].y, 3)) {"
# UB: the score's cap removed (signed overflow after 2^31 / 10 fireflies)
m scorecap  sw/game2d/lantern.c "if (score < SCORE_MAX) score += 10;" "score += 10;"
# S4: an extra write per log
m writes    sw/game2d/lantern.c "         logs [i].y += logs [i].vy;" \
                                "         logs [i].y += logs [i].vy; hw_vdp_write (VDP_BACKDROP, 0); hw_vdp_write (VDP_BACKDROP, 0); hw_vdp_write (VDP_BACKDROP, 0);"
echo "$missed missed"; [ $missed -eq 0 ]
