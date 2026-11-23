#!/bin/sh
# formal/sw/mutants.sh: planted software bugs that tier 1 (formal/sw/fuzz.sh) must catch.  Each
# mutant is a copy of the title's sources (build/swfv/mut/<name>/, the repo's layout) with one
# edit; fuzz.sh runs on the copy and must FAIL.
#   formal/sw/mutants.sh [runs] [frames]        (defaults 6 2000)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
RUNS=${1:-6}; FRAMES=${2:-2000}
M=$REPO/build/swfv/mut
missed=0

m () {   # name file "from" "to"   (the reason is the comment above each call)
   d=$M/$1; rm -rf "$d"; mkdir -p "$d/sw" "$d/test" "$d/formal/sw" "$d/build"
   cp -R "$REPO/sw/game2d" "$REPO/sw/vdp" "$REPO/sw/apu" "$d/sw/"; cp -R "$REPO/test/bench" "$d/test/"
   cp "$REPO/formal/sw/host_trace.c" "$d/formal/sw/"
   python3 - "$d/$2" "$3" "$4" <<'EOF'
import sys
p, a, b = sys.argv[1:]; s = open(p).read()
assert s.count(a) == 1, (p, a); open(p, 'w').write(s.replace(a, b))
EOF
   if ROOT=$d OUT=$d/out STOP_ON_FAIL=1 "$HERE/fuzz.sh" "$RUNS" "$FRAMES" > "$d/fuzz.log" 2>&1; then
      echo "$1: MISSED"; missed=$((missed + 1))
   else
      echo "$1: caught ($(grep -m1 FAIL "$d/fuzz.log" | cut -c1-110))"
   fi
}

# S1: the sprite clear loop runs one past the 64 sprites (a write beyond the sprite table)
m initoob    sw/game2d/lantern.c "for (int i = 0; i < 64; i++) spr (i, 0, 0, 0, 0, 0);" \
                                 "for (int i = 0; i <= 64; i++) spr (i, 0, 0, 0, 0, 0);"
# S1, deep: only at a game over (three crashes) does it touch sprite 64
m overoob    sw/game2d/lantern.c "if (lives == 0) over = 1;" \
                                 "if (lives == 0) { over = 1; spr (64, 0, 0, 0, 0, 0); }"
# S1: the buttons read from the wrong register
m btnreg     sw/game2d/board.c   "#define BTN           REG (0xC0008004)" \
                                 "#define BTN           REG (0xC0008008)"
# S1: VDP writes as halfwords (the title's contract is word accesses only)
m halfword   sw/game2d/board.c   "void hw_vdp_write (uint32_t addr, uint32_t value) { REG (addr) = value; }" \
                                 "void hw_vdp_write (uint32_t addr, uint32_t value) { *(volatile uint16_t *) (uintptr_t) addr = (uint16_t) value; *(volatile uint16_t *) (uintptr_t) (addr + 2) = (uint16_t) (value >> 16); }"
# S1: a write to the APU's read-only ENV register
m envwrite   sw/game2d/sound.c   "void sound_crash (void) { w (APU_KEYON, 0x80); }" \
                                 "void sound_crash (void) { w (APU_KEYON, 0x80); w (APU_ENV (7), 0); }"
# S2: plain char is unsigned on RISC-V and signed on the host: the drum sample differs
m charsign   sw/game2d/sound.c   "int t = (int) ((ph >> 16) & 255);" \
                                 "int t = (char) ((ph >> 16) & 255) + 128;"
# S2: a target-only change (what a miscompilation looks like from outside)
m targetonly sw/game2d/sound.c   "frame++;" \
                                 "frame++;
#ifdef __riscv
   if (frame == 1500) w (APU_MASTER, 27);
#endif"
# S2: the title reads the video frame counter (timing, not game state) into its input
m timing     sw/game2d/board.c   "      lantern_frame (b);" \
                                 "      lantern_frame (b | ((VIDEO_FRAME & 3) == 3 ? BTN_UP : 0));"

echo "$missed missed"
[ $missed -eq 0 ]
