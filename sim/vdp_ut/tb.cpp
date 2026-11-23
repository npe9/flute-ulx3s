// sim/vdp_ut/tb.cpp: src/Vdp.v against the reference model sw/vdp/vdp_ref.c, frame by frame.
// Each scene writes the whole state over the register bus, lets a frame pass, then captures the
// next frame from the stage-2 index output (each VDP pixel must be the same on its four screen
// pixels) and compares it with vdp_ref_frame, plus STATUS.OVERFLOW.  Directed scenes cover the
// flips, scroll and sprite wrap, behind sprites, more than 16 sprites on a line, the layer
// enables and a scroll write mid-frame (it must apply from the next line rendered); random
// scenes cover the rest.  Bus reads check the registers, VRAM and sprite table read back.
// Also checks every render finishes before its line is shown.
#include "Vvdp_tb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
extern "C" {
#include "../../sw/vdp/vdp.h"
}

static Vvdp_tb *t;
static uint64_t cyc;
static int errors;
static int deadline_err;
// render tracking: the line each start was for, and whether it finished before being shown
static int cur_line = -1;
static bool cur_done = true;

static void check_deadline () {
   // a render of line L must be done before scanline 2L (L = 0: before scanline 0)
   if (cur_line >= 0 && !cur_done) {
      int vc = t->vc0, hc = t->hc0;
      int show = 2 * cur_line;
      if (vc == show && hc == 0 && cur_line != 0) { if (deadline_err++ < 5) printf ("DEADLINE line %d\n", cur_line); }
      if (cur_line == 0 && vc == 0 && hc == 0) { if (deadline_err++ < 5) printf ("DEADLINE line 0\n"); }
   }
}

// one system clock; the pixel clock rises every second system clock
static void cycle () {
   t->clk = 1;
   bool prise = (cyc & 1) == 0;
   if (prise) t->pclk = 1;
   t->eval ();
   if (prise) {
      check_deadline ();
      if (t->r_start) { cur_line = t->r_line; cur_done = false; }
      if (t->r_done) cur_done = true;
   }
   t->clk = 0;
   if (!prise) t->pclk = 0;
   t->eval ();
   if (prise) { t->pclk = 0; t->eval (); }
   cyc++;
}

static uint32_t bus (bool we, uint32_t a, uint32_t d, unsigned strb = 0xF) {
   t->rb_valid = 1; t->rb_we = we; t->rb_addr = a; t->rb_wdata = d; t->rb_wstrb = strb;
   int n = 0;
   for (;;) {
      cycle ();
      if (t->rb_ack) break;
      if (++n > 300) { printf ("BUS TIMEOUT %08x\n", a); errors++; break; }
   }
   uint32_t r = t->rb_rdata;
   t->rb_valid = 0;
   cycle ();
   return r;
}
static void wr (uint32_t a, uint32_t d) { bus (true, a, d); }
static uint32_t rd (uint32_t a) { return bus (false, a, 0); }

static void load (const vdp_state &s) {
   for (int i = 0; i < 1024; i++) wr (VDP_MAP + 4 * i, s.map [2 * i] | ((uint32_t) s.map [2 * i + 1] << 16));
   for (int i = 0; i < 8192; i++) wr (VDP_PATTERNS + 4 * i, s.pat [i]);
   for (int i = 0; i < 128; i++) wr (VDP_SPRITES + 4 * i, s.spr [i]);
   wr (VDP_CTRL, s.ctrl); wr (VDP_BG_SCROLL, s.scroll); wr (VDP_BACKDROP, s.backdrop);
}

// run until the scan counters are at (vc, hc)
static void run_to (int vc, int hc) {
   for (long n = 0; n < 4000000; n++) {
      if (t->vc0 == vc && t->hc0 == hc && (cyc & 1) == 0) return;
      cycle ();
   }
   printf ("run_to timeout\n"); errors++;
}

static uint8_t got [VDP_H][VDP_W];
static uint8_t exp_ [VDP_H][VDP_W];

// capture one frame starting at scanline 0; optional mid-frame write at (wvc, whc)
static void capture (int wvc = -1, int whc = 0, uint32_t wa = 0, uint32_t wd = 0) {
   run_to (0, 0);
   bool inconsistent = false;
   static int seen [VDP_H][VDP_W];
   memset (seen, 0, sizeof seen);
   bool wrote = false;
   for (long n = 0; n < 2 * 800 * 525 + 8; n++) {
      if (!wrote && wvc >= 0 && t->vc0 == wvc && t->hc0 == whc) { wr (wa, wd); wrote = true; }
      bool prise = (cyc & 1) == 0;
      cycle ();
      if (!prise) continue;
      int h = t->hc2, v = t->vc2;
      if (h < 640 && v < 480) {
         int x = h >> 1, y = v >> 1;
         if (seen [y][x]++ == 0) got [y][x] = t->idx;
         else if (got [y][x] != t->idx) inconsistent = true;
      }
      if (t->vc0 == 480 && t->hc0 == 0 && n > 10) break;
   }
   if (inconsistent) { printf ("doubled pixels differ\n"); errors++; }
}

static int compare (const char *name, int over_exp) {
   int bad = 0, fx = -1, fy = -1;
   for (int y = 0; y < VDP_H; y++)
      for (int x = 0; x < VDP_W; x++)
         if (got [y][x] != exp_ [y][x]) { if (!bad) { fx = x; fy = y; } bad++; }
   uint32_t st = rd (VDP_STATUS);
   int over = st & 1;
   wr (VDP_STATUS, 0);
   if (bad || over != over_exp) {
      printf ("FAIL %-22s %d pixels differ (first x=%d y=%d got %02x exp %02x), overflow %d exp %d\n",
              name, bad, fx, fy, fx >= 0 ? got [fy][fx] : 0, fx >= 0 ? exp_ [fy][fx] : 0, over, over_exp);
      errors++;
      return 1;
   }
   printf ("ok   %-22s\n", name);
   return 0;
}

static void scene (const char *name, const vdp_state &s) {
   load (s);
   wr (VDP_STATUS, 0);
   run_to (0, 0); run_to (1, 0);      // a whole frame renders with the new state
   wr (VDP_STATUS, 0);
   capture ();
   int over = vdp_ref_frame (&s, exp_);
   compare (name, over);
}

static std::mt19937 rng (12345);
static uint32_t r32 () { return rng (); }

static void random_state (vdp_state &s, int sprites_per_line_hint) {
   for (auto &m : s.map) m = (uint16_t) r32 ();
   for (auto &p : s.pat) { uint32_t w = r32 (); if (r32 () % 4 == 0) w &= r32 (); s.pat [&p - s.pat] = w; }
   for (int i = 0; i < 64; i++) {
      int x = r32 () % 512, y = sprites_per_line_hint ? 100 + r32 () % 8 : r32 () % 512;
      s.spr [2 * i] = x | ((uint32_t) y << 16) | (r32 () & 0xFE00FE00u);
      s.spr [2 * i + 1] = r32 () & 0xFFFFFFFFu;
   }
   s.ctrl = 3; s.scroll = r32 () & 0x00FF01FF; s.backdrop = r32 () & 255;
}

int main (int argc, char **argv) {
   Verilated::commandArgs (argc, argv);
   t = new Vvdp_tb;
   t->rst = 1; t->rb_valid = 0;
   for (int i = 0; i < 8; i++) cycle ();
   t->rst = 0;
   for (int i = 0; i < 8; i++) cycle ();

   // ---- bus read-back
   if (rd (VDP_ID) != VDP_ID_VALUE) { printf ("FAIL ID %08x\n", rd (VDP_ID)); errors++; }
   wr (VDP_CTRL, 0xFFFFFFFF); wr (VDP_BG_SCROLL, 0xFFFFFFFF); wr (VDP_BACKDROP, 0xFFFFFFFF);
   if (rd (VDP_CTRL) != 3 || rd (VDP_BG_SCROLL) != 0x00FF01FF || rd (VDP_BACKDROP) != 0xFF) {
      printf ("FAIL register read-back\n"); errors++;
   }
   wr (VDP_MAP + 0x40, 0x12345678); bus (true, VDP_MAP + 0x40, 0xAB, 1);
   wr (VDP_PATTERNS + 0x7FFC, 0xCAFEF00D); bus (true, VDP_PATTERNS + 0x7FFC, 0x99000000, 8);
   wr (VDP_SPRITES + 0x1FC, 0x01020304);
   if (rd (VDP_MAP + 0x40) != 0x123456AB || rd (VDP_PATTERNS + 0x7FFC) != 0x99FEF00D
       || rd (VDP_SPRITES + 0x1FC) != 0x01020304) { printf ("FAIL VRAM read-back\n"); errors++; }
   else printf ("ok   bus read-back\n");

   vdp_state s;
   // ---- directed: a checkerboard of 4 tiles, flips on every other map entry
   memset (&s, 0, sizeof s);
   for (int tl = 0; tl < 4; tl++)
      for (int r = 0; r < 8; r++) {
         uint32_t w = 0;
         for (int c = 0; c < 8; c++) w |= (uint32_t) ((c + r + tl) % 16) << (4 * c);
         s.pat [8 * tl + r] = w;
      }
   for (int e = 0; e < 2048; e++) s.map [e] = vdp_map_entry (e % 4, e % 16, (e >> 1) & 1, (e >> 2) & 1);
   s.ctrl = 1; s.scroll = 0; s.backdrop = 7;
   scene ("bg flips", s);
   s.scroll = 505 | (250u << 16);
   scene ("bg scroll wrap", s);
   s.ctrl = 0;
   scene ("all off (backdrop)", s);
   // sprites: tiles 4-7 a numbered pattern; at the four edges, wrapping, flipped
   s.ctrl = 3; s.scroll = 0;
   for (int tl = 4; tl < 8; tl++)
      for (int r = 0; r < 8; r++) s.pat [8 * tl + r] = 0x12345678u * (uint32_t) (tl + r) | 0x11111111u;
   int xs [] = { 0, 310, 505, 100, 200, 300, 150, 250 };
   int ys [] = { 0, 230, 500, 100, 120, 200, 239, 10 };
   for (int i = 0; i < 8; i++) {
      s.spr [2 * i] = xs [i] | ((uint32_t) ys [i] << 16);
      s.spr [2 * i + 1] = 4 | ((uint32_t) (i % 16) << 10) | ((uint32_t) (i & 3) << 14) | (1u << 16) | ((i == 3 ? 1u : 0u) << 17);
   }
   scene ("sprites edges flips", s);
   // more than 16 sprites on one band of lines: overflow
   for (int i = 0; i < 64; i++) {
      s.spr [2 * i] = (i * 5) | (100u << 16);
      s.spr [2 * i + 1] = 4 | ((uint32_t) (i % 16) << 10) | (1u << 16) | ((i % 5 == 0) << 17);
   }
   scene ("overflow behind", s);
   s.ctrl = 2;
   scene ("sprites only", s);

   // ---- mid-frame scroll write: during the render of line 60 (scanline 118): applies from 61
   s.ctrl = 3; s.scroll = 0;
   load (s); run_to (0, 0); run_to (1, 0); wr (VDP_STATUS, 0);
   capture (118, 100, VDP_BG_SCROLL, 37 | (5u << 16));
   {
      vdp_state s2 = s; s2.scroll = 37 | (5u << 16);
      int over = 0;
      for (int y = 0; y < VDP_H; y++) over |= vdp_ref_line (y <= 60 ? &s : &s2, y, exp_ [y]);
      compare ("raster scroll", over);
   }

   // the copy point: a write at scanline 119, pixel clock 400 is before line 61's copy (119,
   // 784), so it applies from line 61
   load (s); run_to (0, 0); run_to (1, 0); wr (VDP_STATUS, 0);
   capture (119, 400, VDP_BG_SCROLL, 3 | (9u << 16));
   {
      vdp_state s2 = s; s2.scroll = 3 | (9u << 16);
      int over = 0;
      for (int y = 0; y < VDP_H; y++) over |= vdp_ref_line (y <= 60 ? &s : &s2, y, exp_ [y]);
      compare ("raster copy point", over);
   }

   // ---- random scenes
   for (int k = 0; k < 8; k++) {
      char name [32]; snprintf (name, sizeof name, "random %d", k);
      random_state (s, k & 1);
      scene (name, s);
   }

   if (deadline_err) { printf ("FAIL %d renders missed their line\n", deadline_err); errors++; }
   printf (errors ? "VDP_UT FAIL (%d)\n" : "VDP_UT PASS\n", errors);
   delete t;
   return errors ? 1 : 0;
}
