// sw/game2d/board.c: hw.h on the game2d SoC, and the title's main loop.  Built by build.sh with
// test/bench's runtime (bench_rt.c: start-up, UART printf, mcycle), loaded at 0x80000000 by
// scripts/loader.py or the strict sim.
//   GAME_FRAMES=0 (board): runs forever, printing the frame-time statistics every 10 s.
//   GAME_FRAMES=n (sim, the frame check): stops after n frames, holds the picture for two more,
//   prints the statistics, then "Hello from Flute" / "tick 00000000" (the strict sim's PASS).
//   The title: Lantern Drift, or with -DTITLE_PROOF Proof Obligation (proof.c).
#include "hw.h"
#ifdef TITLE_PROOF
#include "proof.h"
#define TITLE_INIT  proof_init
#define TITLE_FRAME proof_frame
#else
#include "lantern.h"
#define TITLE_INIT  lantern_init
#define TITLE_FRAME lantern_frame
#endif
#include "../vdp/vdp.h"
#include "../apu/apu.h"
#include <stdint.h>

#ifndef GAME_FRAMES
#define GAME_FRAMES 0
#endif
#define REG(a) (*(volatile uint32_t *) (uintptr_t) (a))
#define VIDEO_MODE    REG (0xC0010004)
#define VIDEO_FRAME   REG (0xC001000C)
#define VIDEO_PALETTE 0xC0010400u
#define BTN           REG (0xC0008004)
#define AUD_CTRL      REG (0xC0009004)
#define AUD_VOLUME    REG (0xC0009008)

int bench_printf (const char *f, ...);
uint64_t bench_cycles (void);

void hw_vdp_write (uint32_t addr, uint32_t value) { REG (addr) = value; }
void hw_palette (int index, uint32_t rgb) { REG (VIDEO_PALETTE + 4 * (uint32_t) index) = rgb; }
void hw_video_on (void) { VIDEO_MODE = 4; }
void hw_wait_frame (void) { uint32_t f = VIDEO_FRAME; while (VIDEO_FRAME == f) ; }
uint32_t hw_buttons (void) { return BTN & 0x7C; }
void hw_apu_write (uint32_t addr, uint32_t value) { REG (addr) = value; }

static uint64_t sum, worst;
static uint32_t n;
static void stats (void) {
   bench_printf ("game2d: %u frames, CPU cycles per frame: mean %u, worst %u\n", n,
                 (unsigned) (n ? sum / n : 0), (unsigned) worst);
}

int main (void) {
   if (VDP_REG (VDP_ID) != VDP_ID_VALUE) { bench_printf ("game2d: no VDP\n"); return 1; }
   if (REG (APU_ID) != APU_ID_VALUE) { bench_printf ("game2d: no APU\n"); return 1; }
   AUD_VOLUME = 4;                  // the jack: the APU goes through Audio's VOLUME (0 = mute)
   TITLE_INIT ();
   for (uint32_t f = 0; GAME_FRAMES == 0 || f < GAME_FRAMES; f++) {
      uint32_t b = hw_buttons ();
      hw_wait_frame ();
      uint64_t c0 = bench_cycles ();
      TITLE_FRAME (b);
      uint64_t d = bench_cycles () - c0;
      sum += d; n++; if (d > worst) worst = d;
      if (GAME_FRAMES == 0 && n % 600 == 0) stats ();
   }
   hw_wait_frame (); hw_wait_frame ();
   stats ();
   bench_printf ("Hello from Flute\ntick 00000000\n");
   return 0;
}
