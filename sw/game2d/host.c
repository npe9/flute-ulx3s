// sw/game2d/host.c: hw.h against the VDP reference model.  Runs the title for n frames with no
// buttons pressed (what the strict sim's board does) and writes the picture the SoC must then
// show, 640x480 as the DVI block scans it out (each VDP pixel doubled), to a PPM.
//   cc -O2 -o build/game2d/lantern_host sw/game2d/host.c sw/game2d/lantern.c sw/vdp/vdp_ref.c
//   build/game2d/lantern_host <n> <out.ppm> [<apu writes>]   (the APU writes, one "addr data" a line)
// The title: Lantern Drift, or with -DTITLE_PROOF Proof Obligation (proof.c).  Optional, from the
// environment (for looking at a title, not used by the frame check):
//   HOST_BUTTONS=<file>   the buttons, one hex value a line per frame (then 0)
//   HOST_SHOTS=<f1,f2,..> also write the frame after those frames to <out.ppm>.<f>.ppm
//   HOST_OVERFLOW=1       render every frame and count those with a sprite overflow (2: print
//                         each one's frame and first line)
//   HOST_STATS=1          print the per-frame write counts (VDP, APU): mean and worst
//   HOST_SPEC=1           (Proof Obligation) check proof_spec.c's clauses on every frame
#include "hw.h"
#ifdef TITLE_PROOF
#include "proof_spec.h"
#include "proof.h"
#define TITLE_INIT  proof_init
#define TITLE_FRAME proof_frame
#else
#include "lantern.h"
#define TITLE_INIT  lantern_init
#define TITLE_FRAME lantern_frame
#endif
#include <string.h>
#include "../vdp/vdp.h"
#include <stdio.h>
#include <stdlib.h>

static vdp_state s;
static uint32_t pal [256];
static long nw_vdp, nw_apu;

void hw_vdp_write (uint32_t a, uint32_t v) {
   nw_vdp++;
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
void hw_palette (int i, uint32_t rgb) { nw_vdp++; pal [i & 255] = rgb & 0xFFFFFF; }
void hw_video_on (void) {}
void hw_wait_frame (void) {}
uint32_t hw_buttons (void) { return 0; }
// APU writes: logged (the frame check compares them with the SoC's), in order
static FILE *apu_log;
void hw_apu_write (uint32_t a, uint32_t v) { nw_apu++; if (apu_log) fprintf (apu_log, "%08x %08x\n", a, v); }

static int write_ppm (const char *name) {
   static uint8_t img [VDP_H][VDP_W];
   int over = vdp_ref_frame (&s, img);
   FILE *o = fopen (name, "wb");
   if (!o) { perror (name); exit (1); }
   fprintf (o, "P6\n640 480\n255\n");
   for (int y = 0; y < 480; y++)
      for (int x = 0; x < 640; x++) {
         uint32_t c = pal [img [y / 2][x / 2]];
         fputc ((c >> 16) & 255, o); fputc ((c >> 8) & 255, o); fputc (c & 255, o);
      }
   fclose (o);
   return over;
}

int main (int argc, char **argv) {
   if (argc != 3 && argc != 4) { fprintf (stderr, "usage: %s <frames> <out.ppm> [apu writes]\n", argv [0]); return 2; }
   int n = atoi (argv [1]), score = 0;
   if (argc == 4 && !(apu_log = fopen (argv [3], "w"))) { perror (argv [3]); return 1; }
   FILE *btn = getenv ("HOST_BUTTONS") ? fopen (getenv ("HOST_BUTTONS"), "r") : NULL;
   const char *shots = getenv ("HOST_SHOTS");
   int count_over = getenv ("HOST_OVERFLOW") != NULL, stats = getenv ("HOST_STATS") != NULL, overs = 0;
   long wv_max = 0, wa_max = 0, wv_sum = 0;
   TITLE_INIT ();
#ifdef TITLE_PROOF
   // HOST_SPEC=1: check notes/proof-obligation-spec.md's clauses on every frame (proof_spec.c)
   int spec = getenv ("HOST_SPEC") != NULL; long spec_bad = 0;
   spec_state sp_pre, sp_post;
   if (spec) { proof_observe (&sp_pre); const char *e = spec_init (&sp_pre); if (!e) e = spec_inv (&sp_pre);
               if (e) { printf ("spec: init: %s\n", e); spec_bad++; } }
#endif
   for (int f = 0; f < n; f++) {
      if (apu_log) fprintf (apu_log, "# frame %d\n", f);
      unsigned b = 0;
      if (btn && fscanf (btn, "%x", &b) != 1) b = 0;
      long v0 = nw_vdp, a0 = nw_apu;
      score = TITLE_FRAME (b);
#ifdef TITLE_PROOF
      if (spec) {
         proof_observe (&sp_post);
         const char *e = spec_inv (&sp_post);
         if (!e) e = spec_step (&sp_pre, b, &sp_post);
         if (e && spec_bad++ < 20) printf ("spec: frame %d: %s\n", f, e);
         sp_pre = sp_post;
      }
#endif
      long dv = nw_vdp - v0, da = nw_apu - a0;
      if (f > 0) { wv_sum += dv; if (dv > wv_max) wv_max = dv; if (da > wa_max) wa_max = da; }
      if (count_over) { static uint8_t img [VDP_H][VDP_W]; int ov = vdp_ref_frame (&s, img); overs += ov != 0; if (ov && getenv ("HOST_OVERFLOW")[0] == '2')
            for (int y = 0; y < VDP_H; y++) if (vdp_ref_line (&s, y, img [y])) { printf ("overflow: frame %d line %d\n", f, y); break; } }
      if (shots) {
         char key [16]; snprintf (key, sizeof key, ",%d,", f);
         char list [4096]; snprintf (list, sizeof list, ",%s,", shots);
         if (strstr (list, key)) { char name [512]; snprintf (name, sizeof name, "%s.%d.ppm", argv [2], f); write_ppm (name); }
      }
   }
   int over = write_ppm (argv [2]);
   if (apu_log) fclose (apu_log);
   if (count_over) printf ("host: %d frames with a sprite overflow\n", overs);
   if (stats) printf ("host: writes a frame: VDP mean %ld, worst %ld; APU worst %ld\n", n > 1 ? wv_sum / (n - 1) : 0, wv_max, wa_max);
#ifdef TITLE_PROOF
   if (spec) printf ("host: spec: %ld frame%s violate a clause\n", spec_bad, spec_bad == 1 ? "" : "s");
#endif
   printf ("host: %d frames, score %d, sprite overflow %d\n", n, score, over);
   return 0;
}
