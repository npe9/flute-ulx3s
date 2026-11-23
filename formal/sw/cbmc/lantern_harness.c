// formal/sw/cbmc/lantern_harness.c: tier 2 of notes/sw-verification-plan.md.  CBMC proves, for
// the title's C code (lantern.c + sound.c, included here so their file-static state is
// visible), for EVERY button sequence:
//   base  (HARNESS_BASE): lantern_init establishes INV;
//   step  (HARNESS_STEP): from ANY state satisfying INV, one lantern_frame with ANY buttons
//                         re-establishes INV;
// so INV holds at every frame forever (induction), and in both: no undefined behaviour
// (signed overflow, array bounds, pointers, shifts, division), every loop bounded (unwinding
// assertions), and
//   S1: every hw.h call names a register the device spec defines (hw_check_* below);
//   S3: KEYON only for voices whose registers the keyed mode reads were written (APU1 spec);
//   S4: one frame makes at most FRAME_WRITES device writes.
#include <stdint.h>
#include <assert.h>
#include "../../../sw/game2d/hw.h"
#include "../../../sw/vdp/vdp.h"
#include "../../../sw/apu/apu.h"

int      nondet_int (void);
uint32_t nondet_u32 (void);
_Bool    nondet_bool (void);

// ---------------- hw.h: the device contracts (S1, S3) and the write count (S4)
static unsigned writes;
// APU: which registers of each voice were written since reset (bit per register index 0..6:
// MODE PITCH VOL ADSR START LOOP END) and the last MODE written
static uint8_t  apu_wr [8];
static uint32_t apu_mode [8];

void hw_vdp_write (uint32_t a, uint32_t v) {
   (void) v; writes++;
   assert ((a & 3) == 0);
   assert ((a >= VDP_CTRL && a <= VDP_BACKDROP) || a == VDP_STATUS
           || (a >= VDP_SPRITES && a < VDP_SPRITES + 64 * 8)
           || (a >= VDP_MAP && a < VDP_MAP + 2048 * 2)
           || (a >= VDP_PATTERNS && a < VDP_PATTERNS + 8192 * 4));
}
void hw_palette (int i, uint32_t rgb) { (void) rgb; writes++; assert (i >= 0 && i < 256); }
void hw_video_on (void) { writes++; }
void hw_wait_frame (void) {}
uint32_t hw_buttons (void) { return nondet_u32 () & 0x7C; }
void hw_apu_write (uint32_t a, uint32_t v) {
   writes++;
   assert ((a & 3) == 0);
   if (a >= APU_WAVE && a < APU_WAVE + APU_WAVE_BYTES) return;
   if (a == APU_CTRL || a == APU_MASTER || a == APU_KEYOFF) return;
   if (a == APU_KEYON) {
      for (int k = 0; k < 8; k++) if (v & (1u << k)) {
         uint32_t m = apu_mode [k] & 7;
         assert ((apu_wr [k] & 0x0F) == 0x0F);                   // MODE PITCH VOL ADSR
         assert (m != 0);                                         // keying an off voice
         if (m == 4) {                                            // sample: START END (+ LOOP)
            assert (apu_wr [k] & 0x10); assert (apu_wr [k] & 0x40);
            if (apu_mode [k] & APU_LOOPED) assert (apu_wr [k] & 0x20);
         }
      }
      assert ((v & ~0xFFu) == 0);
      return;
   }
   assert (a >= APU_VOICE (0) && a < APU_VOICE (8));
   uint32_t r = (a - APU_VOICE (0)) & 0x1F, k = (a - APU_VOICE (0)) >> 5;
   assert (r != 0x1C);                                            // ENV is read-only
   apu_wr [k] |= (uint8_t) (1u << (r / 4));
   if (r == 0) apu_mode [k] = v;
}

// ---------------- the title, with its file-static state in scope
#include "../../../sw/game2d/sound.c"
#include "../../../sw/game2d/lantern.c"

#ifndef SCORE_MAX                       // lantern.c's cap on the score, if it has one
#define SCORE_MAX 2147483640
#endif
#define T_NONDET nondet_int
#define FRAME_WRITES 75
#define X_LO (8 * RIVER_L)              // spawn_x's range
#define X_HI (8 * RIVER_R - 9)

// the invariant (the game state every frame starts in)
static _Bool inv (void) {
   if (rs == 0) return 0;                                   // xorshift never reaches 0
   if (bx < 8 * RIVER_L || bx > 8 * RIVER_R - 8 || by < 120 || by > 220) return 0;
   if (lives < 0 || lives > 3 || over != (lives == 0)) return 0;
   if (hurt < 0 || hurt > 90 || idle < 0 || idle > 600) return 0;
   if (score < 0 || score % 10 != 0 || score > SCORE_MAX) return 0;
   if (scroll_y < 0 || scroll_y > 255) return 0;
   for (int i = 0; i < N_LOG; i++) if (logs [i].on) {
      if (logs [i].on != 1) return 0;
      if (logs [i].y < -16 || logs [i].y > 240 || logs [i].vy < 1 || logs [i].vy > 3) return 0;
      if (logs [i].x < X_LO || logs [i].x > X_HI) return 0;
   }
   for (int i = 0; i < N_FLY; i++) if (flies [i].on) {
      if (flies [i].on != 1 || flies [i].vy != 1) return 0;
      if (flies [i].y < -16 || flies [i].y > 240) return 0;
      // a firefly drifts one pixel a frame since it spawned at y = -16 inside [X_LO, X_HI]
      if (flies [i].x < X_LO - (flies [i].y + 16) || flies [i].x > X_HI + (flies [i].y + 16)) return 0;
   }
   if (fly_t < 0 || fly_t > 4) return 0;
   // S3's history: sound_init configured these voices (lead 0, bass 1, hats 2, drum 3, chime 6,
   // crash 7); the pitch of 0, 1 and 6 is written by the step that keys them
   static const uint8_t need [8] = { 0x0D, 0x0D, 0x0F, 0x5F, 0, 0, 0x0D, 0x0F };
   for (int k = 0; k < 8; k++) if ((apu_wr [k] & need [k]) != need [k]) return 0;
   if ((apu_mode [0] & 7) != 1 || (apu_mode [1] & 7) != 2 || (apu_mode [2] & 7) != 3) return 0;
   if (apu_mode [3] != APU_SAMPLE || (apu_mode [6] & 7) != 1 || (apu_mode [7] & 7) != 3) return 0;
   return 1;
}

int main (void) {
#ifdef HARNESS_BASE
   lantern_init ();
   assert (inv ());
#else
   // any state: every variable the frame reads, nondeterministic, then assume INV
   rs = nondet_u32 ();
   bx = nondet_int (); by = nondet_int (); score = nondet_int (); lives = nondet_int ();
   hurt = nondet_int (); over = nondet_int (); t = T_NONDET (); scroll_y = nondet_int ();
   idle = nondet_int ();
   for (int i = 0; i < N_LOG; i++) {
      logs [i].x = nondet_int (); logs [i].y = nondet_int (); logs [i].vy = nondet_int ();
      logs [i].on = nondet_int ();
   }
   for (int i = 0; i < N_FLY; i++) {
      flies [i].x = nondet_int (); flies [i].y = nondet_int (); flies [i].vy = nondet_int ();
      flies [i].on = nondet_int ();
   }
   frame = T_NONDET (); fly_t = nondet_int ();
   for (int k = 0; k < 8; k++) { apu_wr [k] = (uint8_t) nondet_u32 (); apu_mode [k] = nondet_u32 (); }
   __CPROVER_assume (inv ());
#ifdef VACUITY
   assert (0);                          // must FAIL: INV is satisfiable (run.sh vacuity)
#endif
   writes = 0;
   lantern_frame (hw_buttons ());
   assert (writes <= FRAME_WRITES);
   assert (inv ());
#endif
   return 0;
}
