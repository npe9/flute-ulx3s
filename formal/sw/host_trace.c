// formal/sw/host_trace.c: the specification side of S2 (notes/sw-verification-plan.md).  The
// title's C code compiled for the host, with hw.h implemented as the device writes board.c
// makes on the SoC (same addresses, same data, same order), and board.c's main loop: the
// trace is what the RISC-V binary must produce on Sail (formal/sw/sail/socdev.c).
//   host_trace <frames> <buttons file> <trace out>
#include "../../sw/game2d/hw.h"
#ifdef TITLE_PROOF
#include "../../sw/game2d/proof_spec.h"
#include "../../sw/game2d/proof.h"
#define TITLE_INIT  proof_init
#define TITLE_FRAME proof_frame
#else
#include "../../sw/game2d/lantern.h"
#define TITLE_INIT  lantern_init
#define TITLE_FRAME lantern_frame
#endif
#include <stdio.h>
#include <stdlib.h>

static FILE *o;
static void wr (uint32_t a, uint32_t d) { fprintf (o, "W %08x %08x\n", a, d); }

void hw_vdp_write (uint32_t a, uint32_t v) { wr (a, v); }
void hw_palette (int i, uint32_t rgb) { wr (0xC0010400u + 4 * (uint32_t) i, rgb); }
void hw_video_on (void) { wr (0xC0010004u, 4); }
void hw_wait_frame (void) {}
static uint32_t btn;
uint32_t hw_buttons (void) { return btn & 0x7C; }
void hw_apu_write (uint32_t a, uint32_t v) { wr (a, v); }

int main (int argc, char **argv) {
   if (argc != 4) { fprintf (stderr, "usage: %s <frames> <buttons> <trace>\n", argv [0]); return 2; }
   int n = atoi (argv [1]);
   FILE *b = fopen (argv [2], "r");
   if (!b || !(o = fopen (argv [3], "w"))) { perror ("host_trace"); return 1; }
   wr (0xC0009008u, 4);                        // board.c: AUD_VOLUME = 4
   TITLE_INIT ();
#ifdef TITLE_PROOF
   // the game's specification (notes/proof-obligation-spec.md), checked on every frame of the
   // fuzz script; a violation goes to stderr (fuzz.sh: SPEC)
   spec_state pre, post;
   proof_observe (&pre);
   const char *e = spec_init (&pre); if (!e) e = spec_inv (&pre);
   if (e) fprintf (stderr, "SPEC init: %s\n", e);
#endif
   for (int f = 0; f < n; f++) {
      if (fscanf (b, "%x", &btn) != 1) btn = 0;
      fprintf (o, "F\n");                      // board.c reads the buttons once a frame
      TITLE_FRAME (hw_buttons ());
#ifdef TITLE_PROOF
      proof_observe (&post);
      e = spec_inv (&post); if (!e) e = spec_step (&pre, hw_buttons (), &post);
      if (e) fprintf (stderr, "SPEC frame %d: %s\n", f, e);
      pre = post;
#endif
   }
   fclose (o);
   return 0;
}
