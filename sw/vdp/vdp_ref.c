// sw/vdp/vdp_ref.c: the VDP1 reference model (the behaviour vdp.h specifies).  The RTL bench
// (sim/vdp_ut) compares src/Vdp.v against it pixel for pixel; programs can use it to predict a
// frame.
#include "vdp.h"

static int tile_px (const vdp_state *s, int tile, int row, int col) {
   uint32_t w = s->pat [8 * (tile & 1023) + (row & 7)];
   return (w >> (4 * (col & 7))) & 15;
}

int vdp_ref_line (const vdp_state *s, int y, uint8_t out [VDP_W]) {
   uint8_t  idx [VDP_W];
   uint8_t  bgop [VDP_W];
   int      bd = s->backdrop & 255;
   int      sx = s->scroll & 511, sy = (s->scroll >> 16) & 255;
   for (int x = 0; x < VDP_W; x++) { idx [x] = 0; bgop [x] = 0; }
   if (s->ctrl & 1)
      for (int x = 0; x < VDP_W; x++) {
         int px = (x + sx) & 511, py = (y + sy) & 255;
         uint16_t e = s->map [(py >> 3) * 64 + (px >> 3)];
         int r = py & 7, c = px & 7;
         if (e & 0x8000) r = 7 - r;
         if (e & 0x4000) c = 7 - c;
         int n = tile_px (s, e & 1023, r, c);
         if (n) { idx [x] = (uint8_t) (16 * ((e >> 10) & 15) + n); bgop [x] = 1; }
      }
   int list [16], nl = 0, over = 0;
   if (s->ctrl & 2)
      for (int i = 0; i < 64; i++) {
         uint32_t w0 = s->spr [2 * i], w1 = s->spr [2 * i + 1];
         if (!(w1 & (1u << 16))) continue;
         int j = (y - (int) ((w0 >> 16) & 511)) & 511;
         if (j >= 16) continue;
         if (nl < 16) list [nl++] = i; else over = 1;
      }
   for (int k = nl - 1; k >= 0; k--) {
      int i = list [k];
      uint32_t w0 = s->spr [2 * i], w1 = s->spr [2 * i + 1];
      int sx0 = w0 & 511, j = (y - (int) ((w0 >> 16) & 511)) & 511;
      int hf = (w1 >> 14) & 1, vf = (w1 >> 15) & 1, behind = (w1 >> 17) & 1;
      int bank = (w1 >> 10) & 15, t = w1 & 1023;
      int r = vf ? 15 - j : j;
      for (int i2 = 0; i2 < 16; i2++) {
         int x = (sx0 + i2) & 511;
         if (x >= VDP_W) continue;
         int c = hf ? 15 - i2 : i2;
         int tt = t + (r >= 8 ? 2 : 0) + (c >= 8 ? 1 : 0);
         int n = tile_px (s, tt, r & 7, c & 7);
         if (!n || (behind && bgop [x])) continue;
         idx [x] = (uint8_t) (16 * bank + n);
      }
   }
   for (int x = 0; x < VDP_W; x++) out [x] = idx [x] ? idx [x] : (uint8_t) bd;
   return over;
}

int vdp_ref_frame (const vdp_state *s, uint8_t out [VDP_H][VDP_W]) {
   int o = 0;
   for (int y = 0; y < VDP_H; y++) o |= vdp_ref_line (s, y, out [y]);
   return o;
}
