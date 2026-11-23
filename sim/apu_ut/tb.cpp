// sim/apu_ut/tb.cpp: src/Apu.v against the reference model sw/apu/apu_ref.c, sample for sample.
// The bench records the clock each bus write is taken at; at each sample tick it hands the model
// the writes taken before the tick (the queue's rule), runs a model tick, and compares that
// sample with the one the RTL outputs when tr_done rises.  Also checks register read-back, the
// ENV / STATUS reads and that the queue never fills.
#include "Vapu.h"
#include "verilated.h"
#include "../../sw/apu/apu.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <vector>

static Vapu *t;
static uint64_t cyc;
static apu_state m;
struct W { uint64_t c; uint32_t a, d, s; };
static std::deque<W> pend;                    // taken, not yet handed to the model
static std::deque<std::pair<int16_t, int16_t>> want;
static long n_checked, n_fail, n_ticks, n_loud;
static int scene_fail;
static const char *scene = "";
static uint32_t rs = 12345;
static uint32_t rnd () { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }

static void fail (const char *what) {
   if (scene_fail++ < 5) printf ("FAIL %-22s %s (cycle %llu)\n", scene, what, (unsigned long long) cyc);
   n_fail++;
}

// one clock: evaluate, note a tick / done, posedge
static void clk () {
   t->clk = 0; t->eval ();
   if (t->tr_tick && !t->rst) {               // the tick happens at this edge
      while (!pend.empty () && pend.front ().c < cyc) {
         apu_ref_write (&m, pend.front ().a, pend.front ().d, pend.front ().s); pend.pop_front ();
      }
      int16_t l, r; apu_ref_tick (&m, &l, &r); want.push_back ({l, r}); n_ticks++;
   }
   if (t->tr_level >= 1024) fail ("queue full");
   t->clk = 1; t->eval (); cyc++;
   if (t->tr_done) {
      if (want.empty ()) fail ("done with no tick");
      else {
         auto w = want.front (); want.pop_front (); n_checked++;
         if (w.first || w.second) n_loud++;
         if ((int16_t) t->out_l != w.first || (int16_t) t->out_r != w.second) {
            char b [96]; snprintf (b, sizeof b, "sample %d/%d, model %d/%d", (int16_t) t->out_l,
                                   (int16_t) t->out_r, w.first, w.second);
            fail (b);
         }
      }
   }
}
static void idle (int n) { while (n--) clk (); }
// run n ticks, then until the last one's sample is out (the sequencer idle)
static void ticks (int n) {
   long e = n_ticks + n; while (n_ticks < e) clk ();
   for (int w = 0; !want.empty (); w++) {      // the watchdog: a sample is due within a tick
      if (w > (int) APU_TICK_CLKS) { fail ("no sample within a tick"); printf ("APU_UT FAIL (hung)\n"); exit (1); }
      clk ();
   }
   idle (2);
}

static uint32_t bus (bool we, uint32_t a, uint32_t d, uint32_t s) {
   t->rb_valid = 1; t->rb_we = we; t->rb_addr = a; t->rb_wdata = d; t->rb_wstrb = we ? s : 0;
   if (we) pend.push_back ({cyc, a, d, s});    // taken at this edge (nothing pending)
   int n = 0;
   do { clk (); if (++n > 10) { fail ("no ack"); break; } } while (!t->rb_ack);
   uint32_t r = t->rb_rdata;
   if (n != 2) fail ("ack not 2 cycles after take");
   t->rb_valid = 0; t->rb_we = 0;
   clk ();                                    // the bus protocol: valid low the clock after ack
   return r;
}
static void wr (uint32_t a, uint32_t d, uint32_t s = 15) { bus (true, a, d, s); }
static uint32_t rd (uint32_t a) { return bus (false, a, 0, 0); }

static void reset () {
   t->rst = 1; idle (4); t->rst = 0;
   apu_ref_reset (&m); pend.clear (); want.clear ();
   // the voice registers and the wave RAM are not reset: write them all
   for (int v = 0; v < 8; v++) for (int r = 0; r < 7; r++) wr (APU_VOICE (v) + 4 * r, 0);
   for (uint32_t i = 0; i < APU_WAVE_BYTES; i += 4) wr (APU_WAVE + i, rnd ());
   ticks (2);
}
static void voice (int v, uint32_t mode, uint32_t pitch, uint32_t vol, uint32_t adsr,
                   uint32_t start = 0, uint32_t loop = 0, uint32_t end = 0) {
   wr (APU_MODE (v), mode); wr (APU_PITCH (v), pitch); wr (APU_VOL (v), vol); wr (APU_ADSR (v), adsr);
   wr (APU_START (v), start); wr (APU_LOOP (v), loop); wr (APU_END (v), end);
}
// ENV and STATUS of every voice against the model's state (call with the sequencer idle)
static void check_env () {
   uint32_t snd = 0;
   for (int v = 0; v < 8; v++) {
      uint32_t e = rd (APU_ENV (v)), x = (m.stage [v] << 8) | (m.e [v] >> 8);
      if (e != x) { char b [64]; snprintf (b, sizeof b, "ENV %d = %03x, model %03x", v, e, x); fail (b); }
      if (m.stage [v]) snd |= 1u << v;
   }
   if (((rd (APU_STATUS) >> 16) & 255) != snd) fail ("STATUS voices");
}
static void ticks_env (int n) { while (n--) { ticks (1); check_env (); } }
static void begin (const char *s) { scene = s; scene_fail = 0; }
static void end () { printf ("%s %-22s\n", scene_fail ? "FAIL" : "ok  ", scene); }

int main (int argc, char **argv) {
   Verilated::commandArgs (argc, argv);
   t = new Vapu;
   reset ();

   begin ("id and reset values");
   if (rd (APU_ID) != APU_ID_VALUE) fail ("ID");
   if (rd (APU_CTRL) != 0) fail ("CTRL reset");
   if (rd (APU_MASTER) != 64) fail ("MASTER reset");
   wr (APU_ADSR (3), 0x11223344); wr (APU_ADSR (3), 0xAABB0000, 0xC);
   if (rd (APU_ADSR (3)) != 0xAABB3344) fail ("byte lanes");
   wr (APU_MODE (5), 0xFFFFFFFF);
   if (rd (APU_MODE (5)) != 0x337) fail ("MODE mask");
   if (rd (APU_BASE + 0x40) != 0) fail ("unmapped read");
   wr (APU_MASTER, 0x1A5); wr (APU_CTRL, 3);
   if (rd (APU_MASTER) != 0xA5 || rd (APU_CTRL) != 1) fail ("MASTER / CTRL read-back");
   wr (APU_MASTER, 64); wr (APU_CTRL, 0);
   end ();

   wr (APU_CTRL, 1);
   begin ("pulse duties");
   for (int d = 0; d < 4; d++) {
      voice (0, APU_PULSE | APU_DUTY (d), 1000 + 977 * d, 0x80FF, apu_adsr (0, 0, 0, 0));
      wr (APU_KEYON, 1); ticks (300);
   }
   end ();
   begin ("triangle");
   voice (1, APU_TRIANGLE, 4321, 0xFF40, apu_adsr (40, 3, 128, 9));
   wr (APU_KEYON, 2); ticks (600); wr (APU_KEYOFF, 2); ticks (400);
   end ();
   begin ("noise long and short");
   voice (2, APU_NOISE, 20000, 0x6060, apu_adsr (0, 0, 0, 0)); wr (APU_KEYON, 4); ticks (300);
   voice (2, APU_NOISE | APU_SHORT, 65535, 0x6060, apu_adsr (0, 0, 0, 0)); wr (APU_KEYON, 4); ticks (300);
   wr (APU_KEYOFF, 4); ticks (5);
   end ();
   begin ("sample one-shot");
   voice (3, APU_SAMPLE, 0x1800, 0xFFFF, apu_adsr (0, 0, 0, 0), 1000, 0, 1200); wr (APU_KEYON, 8); ticks (200);
   end ();
   begin ("sample looped");
   voice (3, APU_SAMPLE | APU_LOOPED, 0x2345, 0x7F7F, apu_adsr (200, 50, 100, 7), 32700, 32750, 32768);
   wr (APU_KEYON, 8); ticks (500); wr (APU_KEYOFF, 8); ticks (300);
   voice (3, APU_SAMPLE | APU_LOOPED, 0xFFFF, 0x7F7F, apu_adsr (0, 0, 0, 0), 5, 100, 140);
   wr (APU_KEYON, 8); ticks (300); wr (APU_KEYOFF, 8); ticks (2);
   end ();
   begin ("envelope edges");
   voice (4, APU_PULSE | APU_DUTY (2), 3000, 0xFFFF, apu_adsr (255, 255, 0, 255)); wr (APU_KEYON, 16); ticks (300);
   voice (4, APU_PULSE | APU_DUTY (2), 3000, 0xFFFF, apu_adsr (1, 0, 0, 0)); wr (APU_KEYON, 16); ticks (100);
   wr (APU_KEYOFF, 16); ticks (3);
   voice (4, APU_TRIANGLE, 3000, 0xFFFF, apu_adsr (7, 1, 250, 1)); wr (APU_KEYON, 16); ticks (50);
   wr (APU_KEYOFF, 16); ticks (50); wr (APU_KEYON, 16); ticks (50); wr (APU_KEYOFF, 16); ticks (2);
   // the boundaries, stage by stage: decay landing exactly on S (65535 = 257 * 255), release
   // landing exactly on 0, D = 0, KEYOFF of a stopped voice
   voice (4, APU_PULSE, 3000, 0x4040, apu_adsr (0, 255, 0, 0)); wr (APU_KEYON, 16); ticks_env (260);
   voice (4, APU_PULSE, 3000, 0x4040, apu_adsr (0, 0, 0, 255)); wr (APU_KEYON, 16); ticks_env (3);
   wr (APU_KEYOFF, 16); ticks_env (260);
   wr (APU_KEYOFF, 16); ticks_env (3);
   voice (4, APU_PULSE, 3000, 0x4040, apu_adsr (255, 0, 0, 0)); wr (APU_KEYON, 16); ticks_env (260);
   voice (4, APU_PULSE, 3000, 0x4040, apu_adsr (0, 17, 0x80, 0)); wr (APU_KEYON, 16); ticks_env (200);
   wr (APU_KEYOFF, 16); ticks_env (3);
   end ();
   begin ("mix saturation");
   for (int v = 0; v < 8; v++) voice (v, APU_PULSE | APU_DUTY (v & 3), 500 + 300 * v, 0xFFFF, apu_adsr (0, 0, 0, 0));
   wr (APU_MASTER, 255); wr (APU_KEYON, 0xFF); ticks (300);
   wr (APU_MASTER, 3); ticks (100);
   wr (APU_CTRL, 0); ticks (20); wr (APU_CTRL, 1); wr (APU_MASTER, 64);
   wr (APU_KEYOFF, 0xFF); ticks (5);
   end ();
   begin ("env and status reads");
   voice (6, APU_PULSE, 3000, 0x1010, apu_adsr (100, 20, 90, 30)); wr (APU_KEYON, 64); ticks (400);
   {
      uint32_t e = rd (APU_ENV (6)), s = rd (APU_STATUS);
      if (e != (((m.stage [6]) << 8) | (m.e [6] >> 8))) fail ("ENV read");
      if (((s >> 16) & 255) != 64) fail ("STATUS voices");
   }
   wr (APU_KEYOFF, 64); ticks (400);
   end ();

   begin ("write on the tick clock");
   // a write taken on the tick's own clock belongs to the next tick (the snapshot excludes it)
   for (int v = 0; v < 4; v++) voice (v, APU_PULSE | APU_DUTY (v & 3), 900 + 500 * v, 0xC0C0, apu_adsr (0, 0, 0, 0));
   wr (APU_KEYON, 15); ticks (4);
   // (with a write already queued, so the tick drains: an empty queue skips the drain)
   for (int n = 0; n < 40; n++) {
      for (;;) { t->clk = 0; t->eval (); if (t->tr_tick) break; clk (); }
      clk (); idle ((int) APU_TICK_CLKS - 12);                 // ~10 clocks before the next tick
      wr (APU_VOL ((n + 1) & 3), 0x0808 * (n & 31));            // queued before the tick
      for (;;) { t->clk = 0; t->eval (); if (t->tr_tick) break; clk (); }   // the next edge ticks
      if (n & 1) wr (APU_MASTER, 20 + 7 * n); else wr (APU_VOL (n & 3), 0x1010 * (n & 15));
      ticks (1);
   }
   wr (APU_KEYOFF, 15); wr (APU_MASTER, 64); ticks (3);
   end ();

   begin ("random");
   for (int sc = 0; sc < 30; sc++) {
      for (int n = 0; n < 300; n++) {
         uint32_t x = rnd () % 100;
         if (x < 50) {
            int v = rnd () & 7, r = rnd () % 7;
            uint32_t d = rnd ();
            if (r == 0) d &= 0x337;
            wr (APU_VOICE (v) + 4 * r, d, (rnd () % 3) ? 15 : (rnd () & 15) | 1);
         } else if (x < 60) wr (APU_KEYON, rnd () & 0xFF);
         else if (x < 66) wr (APU_KEYOFF, rnd () & 0xFF);
         else if (x < 70) wr (APU_MASTER, rnd () & 0xFF);
         else if (x < 72) wr (APU_CTRL, rnd () & 1 ? 1 : (rnd () & 1));
         else if (x < 85) wr (APU_WAVE + (rnd () & 0x7FFC), rnd (), rnd () & 15);
         else if (x < 90) rd (APU_VOICE (rnd () & 7) + 4 * (rnd () & 7));
         else idle (rnd () % 3000);
      }
      ticks (49); check_env (); ticks_env (1);
   }
   end ();

   begin ("queue stress");
   for (int n = 0; n < 6000; n++) wr (APU_VOICE (n & 7) + 4 * (n % 7), rnd ());
   wr (APU_KEYON, 0xFF);
   for (int n = 0; n < 6000; n++) wr (APU_WAVE + 4 * (n & 8191), rnd ());
   ticks (20);
   end ();

   printf ("%ld samples compared (%ld not silent), %ld ticks\n", n_checked, n_loud, n_ticks);
   printf (n_fail ? "APU_UT FAIL (%ld)\n" : "APU_UT PASS\n", n_fail);
   t->final (); delete t;
   return n_fail ? 1 : 0;
}
