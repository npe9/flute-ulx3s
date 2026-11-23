// sw/apu/render.c: plays a write log through the reference model (sw/apu/apu_ref.c) into a WAV
// (stereo, 16-bit, 31,990 Hz), for listening and for level checks.  The log is sw/game2d/host.c's:
// "addr data" lines, "# frame n" lines between frames; a frame is 840,000 / APU_TICK_CLKS ticks
// (the game2d SoC: a 420,000-pixel-clock frame at 25 MHz, the APU at 50 MHz).
//   cc -O2 -o build/apu_render sw/apu/render.c sw/apu/apu_ref.c
//   build/apu_render <log> <out.wav>
#include "apu.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static apu_state s;
static void le (FILE *o, uint32_t v, int n) { while (n--) { fputc (v & 255, o); v >>= 8; } }

int main (int argc, char **argv) {
   if (argc != 3) { fprintf (stderr, "usage: %s <log> <out.wav>\n", argv [0]); return 2; }
   FILE *in = fopen (argv [1], "r"), *o = fopen (argv [2], "wb");
   if (!in || !o) { perror ("open"); return 1; }
   apu_ref_reset (&s);
   le (o, 0x46464952, 4); le (o, 0, 4); le (o, 0x45564157, 4); le (o, 0x20746d66, 4); le (o, 16, 4);
   le (o, 1, 2); le (o, 2, 2); le (o, 31990, 4); le (o, 31990 * 4, 4); le (o, 4, 2); le (o, 16, 2);
   le (o, 0x61746164, 4); le (o, 0, 4);
   char line [128]; long nt = 0, frames = 0, sat = 0, peak = 0; uint64_t clk = 0;
   while (fgets (line, sizeof line, in)) {
      uint32_t a, d;
      if (line [0] == '#') {                     // a frame boundary: the ticks of one frame
         if (frames++ == 0) continue;
         clk += 840000;
         while ((uint64_t) (nt + 1) * APU_TICK_CLKS <= clk) {
            int16_t l, r; apu_ref_tick (&s, &l, &r); nt++;
            le (o, (uint16_t) l, 2); le (o, (uint16_t) r, 2);
            if (l == 32767 || l == -32768 || r == 32767 || r == -32768) sat++;
            if (abs (l) > peak) peak = abs (l);
            if (abs (r) > peak) peak = abs (r);
         }
      } else if (sscanf (line, "%x %x", &a, &d) == 2) apu_ref_write (&s, a, d, 15);
   }
   long bytes = nt * 4;
   fseek (o, 4, SEEK_SET); le (o, (uint32_t) (36 + bytes), 4);
   fseek (o, 40, SEEK_SET); le (o, (uint32_t) bytes, 4);
   fclose (o);
   printf ("render: %ld frames, %ld samples (%.1f s), peak %ld, %ld saturated\n", frames, nt, nt / 31990.0, peak, sat);
   return 0;
}
