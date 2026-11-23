// sw/apu/apu_ref.c: the APU1 reference model (the behaviour sw/apu/apu.h specifies).  src/Apu.v is
// compared against it sample for sample (sim/apu_ut, and the game2d sound check).
#include "apu.h"
#include <string.h>

enum { ST_OFF = 0, ST_ATTACK = 1, ST_DECAY = 2, ST_SUSTAIN = 3, ST_RELEASE = 4 };
#define QMAX 4096
static struct { uint32_t a, d, s; } q [QMAX];   // writes queued for the next tick (one model)
static int nq;

void apu_ref_reset (apu_state *s) {
   memset (s, 0, sizeof *s);
   s->master = 64;
   nq = 0;
}

void apu_ref_write (apu_state *s, uint32_t addr, uint32_t data, uint32_t strb) {
   (void) s;
   if (nq < QMAX) { q [nq].a = addr; q [nq].d = data; q [nq].s = strb; nq++; }
}

static uint32_t merge (uint32_t old, uint32_t d, uint32_t strb) {
   for (int b = 0; b < 4; b++)
      if (strb & (1u << b)) old = (old & ~(0xFFu << (8 * b))) | (d & (0xFFu << (8 * b)));
   return old;
}

static const uint32_t reg_mask [8] = { 0x0337, 0xFFFF, 0xFFFF, 0xFFFFFFFFu, 0x7FFF, 0x7FFF, 0xFFFF, 0 };

static void key_on (apu_state *s, int v) {
   s->p [v] = 0;
   s->e [v] = 0;
   s->lfsr [v] = 1;
   s->stage [v] = ST_ATTACK;
}

static void apply (apu_state *s, uint32_t a, uint32_t d, uint32_t strb) {
   uint32_t off = a & 0xFFFF;
   if (off >= 0x8000) {                               // wave RAM
      for (int b = 0; b < 4; b++)
         if (strb & (1u << b)) s->wave [(off & 0x7FFC) + b] = (int8_t) (d >> (8 * b));
      return;
   }
   off &= 0xFFC;
   if (off == 0x004) s->ctrl = merge (s->ctrl, d, strb) & 1;
   else if (off == 0x008) s->master = merge (s->master, d, strb) & 255;
   else if (off == 0x014 && (strb & 1)) { for (int v = 0; v < 8; v++) if (d & (1u << v)) key_on (s, v); }
   else if (off == 0x018 && (strb & 1)) {
      for (int v = 0; v < 8; v++)
         if ((d & (1u << v)) && s->stage [v] != ST_OFF) s->stage [v] = ST_RELEASE;
   }
   else if (off >= 0x100 && off < 0x200) {
      int v = (off - 0x100) >> 5, r = (off >> 2) & 7;
      s->reg [v][r] = merge (s->reg [v][r], d, strb) & reg_mask [r];
   }
}

static int32_t sat16 (int64_t x) { return x > 32767 ? 32767 : x < -32768 ? -32768 : (int32_t) x; }
static int32_t asr (int64_t x, int n) { return (int32_t) (x >> n); }   // arithmetic (gcc, clang)

void apu_ref_tick (apu_state *s, int16_t *left, int16_t *right) {
   for (int i = 0; i < nq; i++) apply (s, q [i].a, q [i].d, q [i].s);
   nq = 0;
   int64_t al = 0, ar = 0;
   for (int v = 0; v < 8; v++) {
      if (s->stage [v] == ST_OFF) continue;
      uint32_t mode = s->reg [v][0] & 7, pitch = s->reg [v][1], vol = s->reg [v][2], adsr = s->reg [v][3];
      uint32_t p = s->p [v], step = (p >> 14) & 31;
      int w;
      switch (mode) {
         case APU_PULSE: {
            static const uint32_t h [4] = { 4, 8, 16, 24 };
            w = step < h [(s->reg [v][0] >> 4) & 3] ? 96 : -96; break;
         }
         case APU_TRIANGLE: w = 16 * (int) (step < 16 ? step : 31 - step) - 120; break;
         case APU_NOISE:    w = (s->lfsr [v] & 1) ? 96 : -96; break;
         case APU_SAMPLE:   w = s->wave [(s->reg [v][4] + (p >> 12)) & 0x7FFF]; break;
         default:           w = 0; break;
      }
      int32_t e = w * (int32_t) (s->e [v] >> 8);
      al += asr ((int64_t) e * (vol & 255), 8);
      ar += asr ((int64_t) e * ((vol >> 8) & 255), 8);
      // advance
      if (mode == APU_SAMPLE) {
         p = (p + pitch) & 0x7FFFFFF;
         uint32_t a = s->reg [v][4] + (p >> 12), end = s->reg [v][6];
         if (a >= end) {
            if (s->reg [v][0] & APU_LOOPED)
               p = ((((p >> 12) - (end - s->reg [v][5])) & 0x7FFF) << 12) | (p & 0xFFF);
            else { s->stage [v] = ST_OFF; s->e [v] = 0; s->p [v] = p; continue; }
         }
      } else {
         uint32_t np = (p + pitch) & 0x7FFFF;
         if (mode == APU_NOISE) {
            uint32_t n = (((p + pitch) >> 14) - (p >> 14)) & 63;
            for (uint32_t k = 0; k < n; k++) {
               uint32_t l = s->lfsr [v];
               uint32_t fb = (l ^ (l >> ((s->reg [v][0] & APU_SHORT) ? 6 : 1))) & 1;
               s->lfsr [v] = (l >> 1) | (fb << 14);
            }
         }
         p = np;
      }
      s->p [v] = p;
      uint32_t A = adsr & 255, D = (adsr >> 8) & 255, S = (adsr >> 16) & 255, R = adsr >> 24, E = s->e [v];
      switch (s->stage [v]) {
         case ST_ATTACK:
            E = (A == 0 || E + A >= 0xFFFF) ? 0xFFFF : E + A;
            if (E == 0xFFFF) s->stage [v] = ST_DECAY;
            break;
         case ST_DECAY:
            if (D == 0) s->stage [v] = ST_SUSTAIN;
            else if (E < D || E - D <= (S << 8)) { E = S << 8; s->stage [v] = ST_SUSTAIN; }
            else E -= D;
            break;
         case ST_RELEASE:
            if (R == 0 || E <= R) { E = 0; s->stage [v] = ST_OFF; }
            else E -= R;
            break;
         default: break;
      }
      s->e [v] = E;
   }
   int32_t m = (int32_t) (s->master & 255);
   int32_t ol = sat16 ((al * m) >> 6), or_ = sat16 ((ar * m) >> 6);
   if (!(s->ctrl & 1)) ol = or_ = 0;
   *left = (int16_t) ol; *right = (int16_t) or_;
   s->ticks++;
}
