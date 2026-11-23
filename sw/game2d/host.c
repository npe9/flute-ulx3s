// sw/game2d/host.c: hw.h against the VDP reference model.  Runs the title for n frames with no
// buttons pressed (what the strict sim's board does) and writes the picture the SoC must then
// show, 640x480 as the DVI block scans it out (each VDP pixel doubled), to a PPM.
//   cc -O2 -o build/game2d/lantern_host sw/game2d/host.c sw/game2d/lantern.c sw/vdp/vdp_ref.c
//   build/game2d/lantern_host <n> <out.ppm> [<apu writes>]   (the APU writes, one "addr data" a line)
#include "hw.h"
#include "lantern.h"
#include "../vdp/vdp.h"
#include <stdio.h>
#include <stdlib.h>

static vdp_state s;
static uint32_t pal [256];

void hw_vdp_write (uint32_t a, uint32_t v) {
   if (a == VDP_CTRL) s.ctrl = v & 3;
   else if (a == VDP_BG_SCROLL) s.scroll = v & 0x00FF01FFu;
   else if (a == VDP_BACKDROP) s.backdrop = v & 255;
   else if (a >= VDP_SPRITES && a < VDP_SPRITES + 512) s.spr [(a - VDP_SPRITES) / 4] = v;
   else if (a >= VDP_MAP && a < VDP_MAP + 0x1000) {
      s.map [(a - VDP_MAP) / 2] = (uint16_t) v; s.map [(a - VDP_MAP) / 2 + 1] = (uint16_t) (v >> 16);
   }
   else if (a >= VDP_PATTERNS && a < VDP_PATTERNS + 0x8000) s.pat [(a - VDP_PATTERNS) / 4] = v;
   else { fprintf (stderr, "host: write to %08x\n", a); exit (2); }
}
void hw_palette (int i, uint32_t rgb) { pal [i & 255] = rgb & 0xFFFFFF; }
void hw_video_on (void) {}
void hw_wait_frame (void) {}
uint32_t hw_buttons (void) { return 0; }
// APU writes: logged (the frame check compares them with the SoC's), in order
static FILE *apu_log;
void hw_apu_write (uint32_t a, uint32_t v) { if (apu_log) fprintf (apu_log, "%08x %08x\n", a, v); }

int main (int argc, char **argv) {
   if (argc != 3 && argc != 4) { fprintf (stderr, "usage: %s <frames> <out.ppm> [apu writes]\n", argv [0]); return 2; }
   int n = atoi (argv [1]), score = 0;
   if (argc == 4 && !(apu_log = fopen (argv [3], "w"))) { perror (argv [3]); return 1; }
   lantern_init ();
   for (int f = 0; f < n; f++) {
      if (apu_log) fprintf (apu_log, "# frame %d\n", f);
      score = lantern_frame (0);
   }
   static uint8_t img [VDP_H][VDP_W];
   int over = vdp_ref_frame (&s, img);
   FILE *o = fopen (argv [2], "wb");
   if (!o) { perror (argv [2]); return 1; }
   fprintf (o, "P6\n640 480\n255\n");
   for (int y = 0; y < 480; y++)
      for (int x = 0; x < 640; x++) {
         uint32_t c = pal [img [y / 2][x / 2]];
         fputc ((c >> 16) & 255, o); fputc ((c >> 8) & 255, o); fputc (c & 255, o);
      }
   fclose (o);
   if (apu_log) fclose (apu_log);
   printf ("host: %d frames, score %d, sprite overflow %d\n", n, score, over);
   return 0;
}
