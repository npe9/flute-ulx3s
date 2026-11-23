// sw/game2d/sound.c: Lantern Drift's sound (sound.h).  Voices: 0 lead (pulse), 1 bass (triangle),
// 2 hats (short noise), 3 drum (a sample in the wave RAM), 6 firefly chime (pulse), 7 crash
// (long noise).  The tune is an original 32-step loop in A minor pentatonic, a step every 8
// frames.
#include "hw.h"
#include "sound.h"
#include "../apu/apu.h"

static void w (uint32_t a, uint32_t d) { hw_apu_write (a, d); }

// PITCH for a MIDI note (69 = A4 = 440 Hz): octave 4 in hundredths of a Hz, shifted
static uint32_t note_pitch (int n) {
   static const uint32_t c4 [12] = { 26163, 27718, 29366, 31113, 32963, 34923,
                                     36999, 39200, 41530, 44000, 46616, 49388 };
   int o = n / 12 - 5;                       // MIDI 60-71 is octave 4
   uint32_t f = c4 [n % 12];
   f = o >= 0 ? f << o : f >> -o;
   return apu_pitch_cHz (f);
}

static const unsigned char lead [32] = {
   69, 0, 72, 0, 74, 0, 76, 74, 72, 0, 69, 0, 67, 0, 69, 0,
   69, 0, 72, 0, 74, 0, 79, 76, 74, 0, 72, 74, 69, 0, 0, 0 };
static const unsigned char bass [8] = { 45, 45, 41, 41, 48, 48, 43, 40 };   // a note every 4 steps
static const unsigned char drum [32] = {
   1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0,
   1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0 };

enum { DRUM_LEN = 2048 };                    // bytes of wave RAM: the drum sample at offset 0
static int frame, fly_t;

void sound_init (void) {
   // the drum: a falling-pitch triangle under a falling level (integers only)
   uint32_t ph = 0, inc = 900u << 8, word = 0;
   for (int i = 0; i < DRUM_LEN; i++) {
      int t = (int) ((ph >> 16) & 255);
      int tri = t < 128 ? t * 2 - 128 : 383 - t * 2;            // -128..127
      int lvl = 255 - (i * 255) / DRUM_LEN;
      int s = (tri * lvl) / 256;
      word |= (uint32_t) (s & 255) << (8 * (i & 3));
      if ((i & 3) == 3) { w (APU_WAVE + (uint32_t) (i & ~3), word); word = 0; }
      ph += inc; inc -= inc / 400;
   }
   w (APU_MODE (0), APU_PULSE | APU_DUTY (2));     w (APU_VOL (0), 0x5060);
   w (APU_ADSR (0), apu_adsr (40, 8, 140, 6));
   w (APU_MODE (1), APU_TRIANGLE);                 w (APU_VOL (1), 0x9090);
   w (APU_ADSR (1), apu_adsr (80, 2, 200, 10));
   w (APU_MODE (2), APU_NOISE | APU_SHORT);        w (APU_VOL (2), 0x3020);
   w (APU_ADSR (2), apu_adsr (255, 40, 0, 40));   w (APU_PITCH (2), 60000);
   w (APU_MODE (3), APU_SAMPLE);                   w (APU_VOL (3), 0xA0A0);
   w (APU_ADSR (3), apu_adsr (0, 0, 0, 0));       w (APU_PITCH (3), 0x1000);
   w (APU_START (3), 0); w (APU_LOOP (3), 0);      w (APU_END (3), DRUM_LEN);
   w (APU_MODE (6), APU_PULSE | APU_DUTY (1));     w (APU_VOL (6), 0x7070);
   w (APU_ADSR (6), apu_adsr (255, 6, 0, 6));
   w (APU_MODE (7), APU_NOISE);                    w (APU_VOL (7), 0x8080);
   w (APU_ADSR (7), apu_adsr (255, 1, 0, 2));     w (APU_PITCH (7), 9000);
   // the worst case (all six voices at their peaks together) sums to about 74,000: MASTER 28
   // keeps it under full scale, so the mix never clips
   w (APU_MASTER, 28);
   w (APU_CTRL, 1);
   frame = 0; fly_t = 0;
}

void sound_frame (void) {
   if (frame % 8 == 0) {
      int s = (frame / 8) % 32;
      uint32_t on = 0, off = 0;
      if (lead [s]) { w (APU_PITCH (0), note_pitch (lead [s])); on |= 1; }
      else if (s % 2 == 0) off |= 1;
      if (s % 4 == 0) { w (APU_PITCH (1), note_pitch (bass [s / 4])); on |= 2; }
      if (s % 2 == 1) on |= 4;
      if (drum [s]) on |= 8;
      if (off) w (APU_KEYOFF, off);
      if (on) w (APU_KEYON, on);
   }
   if (fly_t && --fly_t == 0) w (APU_PITCH (6), note_pitch (96));   // the chime's second note
   frame++;
}

void sound_fly (void) {
   w (APU_PITCH (6), note_pitch (91)); w (APU_KEYON, 0x40); fly_t = 4;
}

void sound_crash (void) { w (APU_KEYON, 0x80); }
