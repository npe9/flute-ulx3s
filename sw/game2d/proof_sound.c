// sw/game2d/proof_sound.c: Proof Obligation's music and effects on APU1 (sw/apu/apu.h), through
// hw_apu_write only and driven once a frame, so the host build issues exactly the board's writes.
// Voices: 0 lead (pulse), 1 bass (triangle), 2 hats (short noise), 3 drum (a sample), 4 jump /
// throw (pulse, swept), 5 hurt and explosions (noise), 6 cues and hits (pulse), 7 deflections.
// The tunes are generated here (an original loop per boss, each in its own mode and tempo: a
// seeded walk over the scale with a repeated motif), not transcribed.
#include "proof_int.h"
#include "../apu/apu.h"

static void w (uint32_t a, uint32_t d) { hw_apu_write (a, d); }
static uint32_t note_pitch (int n) {
   static const uint32_t c4 [12] = { 26163, 27718, 29366, 31113, 32963, 34923,
                                     36999, 39200, 41530, 44000, 46616, 49388 };
   if (n < 24) n = 24;
   if (n > 108) n = 108;
   int o = n / 12 - 5;
   uint32_t f = c4 [n % 12];
   f = o >= 0 ? f << o : f >> -o;
   return apu_pitch_cHz (f);
}

static const uint8_t modes [7][7] = {
   { 0, 2, 4, 5, 7, 9, 11 }, { 0, 2, 3, 5, 7, 9, 10 }, { 0, 1, 3, 5, 7, 8, 10 }, { 0, 2, 4, 6, 7, 9, 11 },
   { 0, 2, 4, 5, 7, 9, 10 }, { 0, 2, 3, 5, 7, 8, 10 }, { 0, 2, 3, 5, 7, 8, 11 } };
//                          root, mode, frames a step, seed
static const uint8_t tunes [10][4] = {
   { 57, 1, 7, 11 }, { 55, 5, 8, 23 }, { 60, 0, 7, 5 }, { 59, 3, 6, 41 }, { 57, 4, 7, 17 },
   { 52, 6, 8, 29 }, { 62, 2, 6, 37 }, { 60, 4, 7, 3 }, { 57, 5, 9, 13 }, { 60, 0, 6, 53 } };
static uint8_t lead [32], bass [8];
static int tune, step_frames;
static unsigned frame;                    // unsigned: wraps defined
static int jump_t, shot_t, cue_t;

static void compose (int n) {
   const uint8_t *tu = tunes [n];
   const uint8_t *m = modes [tu [1]];
   uint32_t s = 0x9E37u * tu [3] + 1;
   int deg = 7;                           // scale degree, 7 = the root an octave up
   for (int i = 0; i < 16; i++) {
      s = s * 1103515245u + 12345u;
      int r = (int) ((s >> 16) % 8);
      if (i % 4 == 0 || r < 5) {
         int d = r < 2 ? -1 : r < 4 ? 1 : r < 5 ? 2 : r < 6 ? -2 : 0;
         deg += d; if (deg < 3) deg = 3; if (deg > 12) deg = 12;
         if (i == 0 || i == 8) deg = 7;
         lead [i] = (uint8_t) (tu [0] + 12 * (deg / 7) + m [deg % 7] - 12 + 12);
      } else lead [i] = 0;
   }
   for (int i = 0; i < 16; i++) {          // the second half: the motif again, its end varied
      lead [16 + i] = lead [i];
      if (i >= 12 && lead [i]) { s = s * 1103515245u + 12345u; int d = (int) ((s >> 16) % 3); lead [16 + i] = (uint8_t) (tu [0] + 12 + m [(d * 2) % 7]); }
   }
   lead [31] = 0;
   static const uint8_t prog [8] = { 0, 0, 5, 5, 3, 3, 4, 4 };   // degrees of the bass line
   for (int i = 0; i < 8; i++) bass [i] = (uint8_t) (tu [0] - 24 + m [prog [i] % 7]);
   step_frames = tu [2];
}

void psnd_init (void) {
   enum { DRUM_LEN = 2048 };
   uint32_t ph = 0, inc = 1100u << 8, word = 0;
   for (int i = 0; i < DRUM_LEN; i++) {
      int tt = (int) ((ph >> 16) & 255);
      int tri = tt < 128 ? tt * 2 - 128 : 383 - tt * 2;
      int lvl = 255 - (i * 255) / DRUM_LEN;
      int v = (tri * lvl) / 256;
      word |= (uint32_t) (v & 255) << (8 * (i & 3));
      if ((i & 3) == 3) { w (APU_WAVE + (uint32_t) (i & ~3), word); word = 0; }
      ph += inc; inc -= inc / 300;
   }
   w (APU_MODE (0), APU_PULSE | APU_DUTY (1));     w (APU_VOL (0), 0x4858);
   w (APU_ADSR (0), apu_adsr (60, 6, 120, 8));
   w (APU_MODE (1), APU_TRIANGLE);                 w (APU_VOL (1), 0x8888);
   w (APU_ADSR (1), apu_adsr (90, 2, 190, 12));
   w (APU_MODE (2), APU_NOISE | APU_SHORT);        w (APU_VOL (2), 0x2018);
   w (APU_ADSR (2), apu_adsr (255, 50, 0, 50));   w (APU_PITCH (2), 62000);
   w (APU_MODE (3), APU_SAMPLE);                   w (APU_VOL (3), 0x9090);
   w (APU_ADSR (3), apu_adsr (0, 0, 0, 0));       w (APU_PITCH (3), 0x1000);
   w (APU_START (3), 0); w (APU_LOOP (3), 0);      w (APU_END (3), DRUM_LEN);
   w (APU_MODE (4), APU_PULSE | APU_DUTY (2));     w (APU_VOL (4), 0x5050);
   w (APU_ADSR (4), apu_adsr (255, 10, 0, 10));
   w (APU_MODE (5), APU_NOISE);                    w (APU_VOL (5), 0x7070);
   w (APU_ADSR (5), apu_adsr (255, 2, 0, 3));     w (APU_PITCH (5), 12000);
   w (APU_MODE (6), APU_PULSE | APU_DUTY (0));     w (APU_VOL (6), 0x6060);
   w (APU_ADSR (6), apu_adsr (255, 8, 0, 8));
   w (APU_MODE (7), APU_PULSE | APU_DUTY (3));     w (APU_VOL (7), 0x3838);
   w (APU_ADSR (7), apu_adsr (255, 30, 0, 30));   w (APU_PITCH (7), note_pitch (96));
   w (APU_MASTER, 24);                     // the worst case of all voices at peak stays under full scale
   w (APU_CTRL, 1);
   frame = 0; jump_t = shot_t = cue_t = 0;
   compose (8); tune = 8;
}

void psnd_tune (int n) {
   if (n < 0 || n > 9 || n == tune) return;
   tune = n; compose (n); frame = 0;
   w (APU_KEYOFF, 0x03);
}

void psnd_frame (void) {
   if (frame % (unsigned) step_frames == 0) {
      int s = (int) ((frame / (unsigned) step_frames) % 32);
      uint32_t on = 0, off = 0;
      if (lead [s]) { w (APU_PITCH (0), note_pitch (lead [s])); on |= 1; }
      else if (s % 2 == 0) off |= 1;
      if (s % 4 == 0) { w (APU_PITCH (1), note_pitch (bass [s / 4])); on |= 2; }
      if (s % 2 == 1) on |= 4;
      if (s % 8 == 0 || (s % 8 == 6 && tune != 8)) on |= 8;
      if (off) w (APU_KEYOFF, off);
      if (on) w (APU_KEYON, on);
   }
   if (jump_t) { jump_t--; w (APU_PITCH (4), note_pitch (72 + 2 * (6 - jump_t))); }   // a rising sweep
   if (shot_t) { shot_t--; w (APU_PITCH (4), note_pitch (88 - 3 * (3 - shot_t))); }
   if (cue_t) { cue_t--; if (cue_t == 6) { w (APU_PITCH (6), note_pitch (79)); w (APU_KEYON, 0x40); } }
   frame++;
}

void psnd_jump (void) { jump_t = 6; shot_t = 0; w (APU_PITCH (4), note_pitch (72)); w (APU_KEYON, 0x10); }
void psnd_shot (void) { if (jump_t) return; shot_t = 3; w (APU_PITCH (4), note_pitch (88)); w (APU_KEYON, 0x10); }
void psnd_hurt (void) { w (APU_PITCH (5), 9000); w (APU_KEYON, 0x20); }
void psnd_boom (void) { w (APU_PITCH (5), 4000); w (APU_KEYON, 0x20); }
void psnd_boss_hit (void) { w (APU_PITCH (6), note_pitch (60)); w (APU_KEYON, 0x40); }
void psnd_tink (void) { w (APU_KEYON, 0x80); }
void psnd_cue (void) { w (APU_PITCH (6), note_pitch (74)); w (APU_KEYON, 0x40); cue_t = 12; }
