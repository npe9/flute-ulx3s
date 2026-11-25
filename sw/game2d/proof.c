// sw/game2d/proof.c: Proof Obligation, the game2d platformer (an original game): the engine,
// graphics, title, stages and player.  You are a tombstone (the end-of-proof mark); run and jump
// with the D-pad (UP jumps), throw lemmas with FIRE2.  Each of the seven stages ends in an arena
// where a boss attacks with their ideas (proof_boss.c); discharge all seven proof obligations.
// With no input the game plays itself (the attract demo, which visits every boss in turn).
// Everything on screen is generated here; the machine is reached only through hw.h, so host.c
// can run the same frames against the VDP reference model.
//
// Each frame first flushes the previous frame's shadow state (palette, map, sprites, scroll) to
// the machine -- in the vertical blank -- and then simulates; so the writes land in the blank and
// their number is bounded (the map flush is limited per frame).
#include "proof_int.h"
#ifdef PROOF_TEST
#include <stdio.h>
#endif
#include "proof.h"

uint8_t kind [ROWS][WMAX];
int wcols, arena_x;
unsigned t;
static uint32_t rs = 0x9E3779B9u;
uint32_t rnd (void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }
int iabs (int v) { return v < 0 ? -v : v; }
int isgn (int v) { return (v > 0) - (v < 0); }
static int cam;                       // the camera's left edge (world pixels)

// ================================================================ shadow state and its flush
static uint32_t pal_sh [256];
static uint8_t  pal_dirty [256];
static uint16_t plane [32][64];
static uint8_t  pdirty [1024];        // per map word (row * 32 + column / 2)
static uint16_t plist [1024];
static int      pn;
static uint32_t spr_sh [128], spr_hw [128];
static uint32_t scroll_sh, scroll_hw = 0xFFFFFFFFu, ctrl_sh = 3, ctrl_hw = 0xFFFFFFFFu;
#define MAP_FLUSH_MAX 640             // map words a frame (a screen takes two frames)

static void pal_set (int i, uint32_t c) { pal_sh [i & 255] = c; pal_dirty [i & 255] = 1; }
static void bank_set (int b, const uint32_t *c, int n) { for (int i = 0; i < n; i++) pal_set (16 * b + 1 + i, c [i]); }
static void plane_set (int pc, int r, uint16_t e) {
   pc &= 63; r &= 31;
   if (plane [r][pc] == e) return;
   plane [r][pc] = e;
   int w = r * 32 + (pc >> 1);
   if (!pdirty [w]) { pdirty [w] = 1; plist [pn++] = (uint16_t) w; }
}
static void spr (int i, int x, int y, int tile, int bnk, int flags) {
   spr_sh [2 * i] = (uint32_t) (x & 511) | ((uint32_t) (y & 511) << 16);
   spr_sh [2 * i + 1] = (uint32_t) (tile & 1023) | ((uint32_t) (bnk & 15) << 10) | ((uint32_t) (flags & 15) << 14);
}
static void spr_off (int i) { spr_sh [2 * i + 1] = 0; }

static void flush (void) {
   for (int i = 0; i < 256; i++)
      if (pal_dirty [i]) { pal_dirty [i] = 0; hw_palette (i, pal_sh [i]); }
   int k = 0;
   while (pn > 0 && k < MAP_FLUSH_MAX) {
      int w = plist [--pn];
      pdirty [w] = 0;
      int r = w / 32, c = 2 * (w % 32);
      hw_vdp_write (VDP_MAP + 4 * (uint32_t) w, (uint32_t) plane [r][c] | ((uint32_t) plane [r][c + 1] << 16));
      k++;
   }
   for (int i = 0; i < 128; i++)
      if (spr_sh [i] != spr_hw [i]) { spr_hw [i] = spr_sh [i]; hw_vdp_write (VDP_SPRITES + 4 * (uint32_t) i, spr_sh [i]); }
   if (scroll_sh != scroll_hw) { scroll_hw = scroll_sh; hw_vdp_write (VDP_BG_SCROLL, scroll_sh); }
   if (ctrl_sh != ctrl_hw) { ctrl_hw = ctrl_sh; hw_vdp_write (VDP_CTRL, ctrl_sh); }
}

// ================================================================ tiles
static uint32_t tl [8];
static void tile_put (int n) { for (int r = 0; r < 8; r++) hw_vdp_write (VDP_PATTERNS + 4 * (uint32_t) (8 * n + r), tl [r]); }
static void px (int r, int c, int n) { if (r >= 0 && r < 8 && c >= 0 && c < 8) tl [r] = (tl [r] & ~(15u << (4 * c))) | ((uint32_t) (n & 15) << (4 * c)); }
static void tile_fill (int n) { for (int r = 0; r < 8; r++) tl [r] = 0x11111111u * (uint32_t) n; }

static uint8_t g16 [16][16];
static void g16_clear (void) { for (int r = 0; r < 16; r++) for (int c = 0; c < 16; c++) g16 [r][c] = 0; }
static void g16_put (int n) {
   for (int q = 0; q < 4; q++) {
      for (int r = 0; r < 8; r++) { tl [r] = 0; for (int c = 0; c < 8; c++) px (r, c, g16 [r + 8 * (q >> 1)][c + 8 * (q & 1)]); }
      tile_put (n + q);
   }
}
static void g16_rows (const char *const rows [16]) {
   for (int r = 0; r < 16; r++)
      for (int c = 0; c < 16; c++) {
         char ch = rows [r][c];
         g16 [r][c] = (uint8_t) (ch >= '1' && ch <= '9' ? ch - '0' : (ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : 0));
      }
}
static void g16_disc (int cx2, int cy2, int rad, int edge, int fill, int hi) {   // centre in half pixels
   for (int r = 0; r < 16; r++)
      for (int c = 0; c < 16; c++) {
         int dx = 2 * c + 1 - cx2, dy = 2 * r + 1 - cy2, d = dx * dx + dy * dy;
         if (d <= 4 * rad * rad) {
            int v = d > 4 * (rad - 1) * (rad - 1) ? edge : fill;
            if (hi && dx < 0 && dy < 0 && d < rad * rad) v = hi;
            g16 [r][c] = (uint8_t) v;
         }
      }
}

// ---- the 5x7 font (bit 4 = left column)
static const char FONT_CHARS [] = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789(){}!.:-?=><',#\\@*/+%&";
static const uint8_t font7 [][7] = {
   {0,0,0,0,0,0,0},
   {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11}, {0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E}, {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},
   {0x1E,0x11,0x11,0x11,0x11,0x11,0x1E}, {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F}, {0x1F,0x10,0x10,0x1E,0x10,0x10,0x10},
   {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F}, {0x11,0x11,0x11,0x1F,0x11,0x11,0x11}, {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E},
   {0x07,0x02,0x02,0x02,0x02,0x12,0x0C}, {0x11,0x12,0x14,0x18,0x14,0x12,0x11}, {0x10,0x10,0x10,0x10,0x10,0x10,0x1F},
   {0x11,0x1B,0x15,0x15,0x11,0x11,0x11}, {0x11,0x11,0x19,0x15,0x13,0x11,0x11}, {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E},
   {0x1E,0x11,0x11,0x1E,0x10,0x10,0x10}, {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D}, {0x1E,0x11,0x11,0x1E,0x14,0x12,0x11},
   {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E}, {0x1F,0x04,0x04,0x04,0x04,0x04,0x04}, {0x11,0x11,0x11,0x11,0x11,0x11,0x0E},
   {0x11,0x11,0x11,0x11,0x11,0x0A,0x04}, {0x11,0x11,0x11,0x15,0x15,0x15,0x0A}, {0x11,0x11,0x0A,0x04,0x0A,0x11,0x11},
   {0x11,0x11,0x11,0x0A,0x04,0x04,0x04}, {0x1F,0x01,0x02,0x04,0x08,0x10,0x1F},
   {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}, {0x04,0x0C,0x04,0x04,0x04,0x04,0x0E}, {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F},
   {0x1F,0x02,0x04,0x02,0x01,0x11,0x0E}, {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}, {0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
   {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E}, {0x1F,0x01,0x02,0x04,0x08,0x08,0x08}, {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},
   {0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C},
   {0x02,0x04,0x08,0x08,0x08,0x04,0x02}, {0x08,0x04,0x02,0x02,0x02,0x04,0x08},       // ( )
   {0x06,0x08,0x08,0x10,0x08,0x08,0x06}, {0x0C,0x02,0x02,0x01,0x02,0x02,0x0C},       // { }
   {0x04,0x04,0x04,0x04,0x04,0x00,0x04}, {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C},       // ! .
   {0x00,0x0C,0x0C,0x00,0x0C,0x0C,0x00}, {0x00,0x00,0x00,0x1F,0x00,0x00,0x00},       // : -
   {0x0E,0x11,0x01,0x02,0x04,0x00,0x04}, {0x00,0x00,0x1F,0x00,0x1F,0x00,0x00},       // ? =
   {0x08,0x04,0x02,0x01,0x02,0x04,0x08}, {0x02,0x04,0x08,0x10,0x08,0x04,0x02},       // > <
   {0x04,0x04,0x08,0x00,0x00,0x00,0x00}, {0x00,0x00,0x00,0x00,0x0C,0x04,0x08},       // ' ,
   {0x00,0x1F,0x1F,0x1F,0x1F,0x1F,0x00},                                             // # = the tombstone
   {0x08,0x04,0x04,0x0A,0x0A,0x11,0x11},                                             // \ = lambda
   {0x11,0x11,0x1F,0x11,0x0A,0x0A,0x04},                                             // @ = for all
   {0x00,0x04,0x15,0x0E,0x15,0x04,0x00}, {0x01,0x01,0x02,0x04,0x08,0x10,0x10},       // * /
   {0x00,0x04,0x04,0x1F,0x04,0x04,0x00},                                             // +
   {0x0E,0x15,0x15,0x17,0x11,0x11,0x0E},                                             // % = a clock
   {0x00,0x1F,0x00,0x1F,0x00,0x1F,0x00} };                                           // & = triple bar
#define T_FONT 32
static int glyph (char c) {
   if (c >= 'a' && c <= 'z') c = (char) (c - 'a' + 'A');
   for (int i = 0; FONT_CHARS [i]; i++) if (FONT_CHARS [i] == c) return i;
   return 0;
}
int sfont (char c) {
   for (int i = 0; SFONT_CHARS [i]; i++) if (SFONT_CHARS [i] == c) return T_SFONT + 4 * i;
   return 0;
}

// ---- background tiles
enum { BT_TOP = 1, BT_FILL, BT_BRICK, BT_NULL, BT_GONE, BT_PILLAR, BT_PIVOT, BT_GATE, BT_ZONE,
       BT_RED, BT_GREEN, BT_BLUE, BT_MARKED, BT_DOOMED, BT_STAR1, BT_STAR2, BT_BAR, BT_BAREMPTY };

static void make_bg_tiles (void) {
   tile_fill (0); tile_put (0);
   tile_fill (2); for (int c = 0; c < 8; c++) { px (0, c, 3); px (1, c, (c & 1) ? 3 : 2); }
   px (4, 2, 1); px (6, 6, 4); tile_put (BT_TOP);
   tile_fill (2); px (1, 1, 1); px (3, 5, 4); px (6, 3, 1); px (5, 7, 1); tile_put (BT_FILL);
   tile_fill (2);
   for (int c = 0; c < 8; c++) { px (0, c, 1); px (4, c, 1); px (1, c, 3); }
   for (int r = 1; r < 4; r++) px (r, 0, 1);
   for (int r = 5; r < 8; r++) px (r, 4, 1);
   tile_put (BT_BRICK);
   tile_fill (2); for (int c = 0; c < 8; c++) { px (0, c, (c & 1) ? 0 : 3); px (1, c, 2); }
   px (4, 2, 1); px (6, 6, 4); tile_put (BT_NULL);   // a dashed top: the tell of a null tile
   tile_fill (0);
   for (int c = 0; c < 8; c += 2) { px (0, c, 3); px (7, c + 1, 3); px (c, 0, 3); px (c + 1, 7, 3); }
   tile_put (BT_GONE);
   tile_fill (1); for (int r = 0; r < 8; r++) { px (r, 1, 2); px (r, 2, 2); px (r, 5, 3); px (r, 6, 2); }
   tile_put (BT_PILLAR);
   tile_fill (4); for (int r = 0; r < 8; r++) { px (r, 1, 5); px (r, 2, 5); px (r, 6, 5); }
   tile_put (BT_PIVOT);
   tile_fill (0); for (int r = 0; r < 8; r++) { px (r, 1, 5); px (r, 2, 4); px (r, 5, 5); px (r, 6, 4); }
   px (3, 0, 5); px (3, 3, 5); px (3, 4, 5); px (3, 7, 5);
   tile_put (BT_GATE);
   tile_fill (2); for (int c = 0; c < 8; c++) { px (0, c, 4); px (1, c, 4); px (2, c, (c & 1) ? 4 : 2); }
   tile_put (BT_ZONE);
   tile_fill (0); px (2, 2, 3); px (2, 6, 3); px (6, 2, 3); px (6, 6, 3); px (4, 4, 4);   // a visited state
   tile_put (BT_RED);
   tile_fill (5); for (int c = 0; c < 8; c++) { px (0, c, 4); px (1, c, 2); px (3, c, (c & 2) ? 2 : 5); px (5, c, (c & 2) ? 5 : 2); }
   tile_put (BT_GREEN);                                                                        // a belt
   tile_fill (1); for (int c = 0; c < 8; c++) { px (0, c, 4); px (2, c, (c & 1) ? 4 : 1); px ((c * 3) & 7, c, 5); }
   tile_put (BT_BLUE);                                                                         // hot floor
   tile_fill (4);
   for (int c = 0; c < 8; c++) { px (0, c, 1); px (4, c, 1); px (1, c, 3); }
   for (int r = 1; r < 4; r++) px (r, 0, 1);
   for (int r = 5; r < 8; r++) px (r, 4, 1);
   tile_put (BT_MARKED);
   tile_fill (2);
   for (int c = 0; c < 8; c++) { px (0, c, 1); px (4, c, 1); px (c, c, 5); px (c, 7 - c, 5); }
   tile_put (BT_DOOMED);
   tile_fill (0); px (3, 3, 1); tile_put (BT_STAR1);
   tile_fill (0); px (2, 4, 2); px (3, 3, 2); px (3, 4, 1); px (3, 5, 2); px (4, 4, 2); tile_put (BT_STAR2);
   tile_fill (0); for (int r = 1; r < 7; r++) for (int c = 0; c < 7; c++) px (r, c, r == 1 ? 3 : 2); tile_put (BT_BAR);
   tile_fill (0); for (int c = 0; c < 7; c++) { px (1, c, 1); px (6, c, 1); } px (2, 0, 1); px (5, 0, 1); px (3, 0, 1); px (4, 0, 1);
   tile_put (BT_BAREMPTY);
   // the font: BG text tiles (nibble 1) and the sprite glyphs (top left of a 16x16 sprite)
   for (int g = 0; FONT_CHARS [g]; g++) {
      tile_fill (0);
      for (int r = 0; r < 7; r++) for (int c = 0; c < 5; c++) if (font7 [g][r] & (16 >> c)) px (r, c + 1, 1);
      tile_put (T_FONT + g);
   }
   for (int i = 0; SFONT_CHARS [i]; i++) {
      g16_clear ();
      int g = glyph (SFONT_CHARS [i]);
      for (int r = 0; r < 7; r++) for (int c = 0; c < 5; c++)
         if (font7 [g][r] & (16 >> c)) g16 [r + 1][c + 1] = 1;
      for (int r = 0; r < 9; r++) for (int c = 0; c < 7; c++)       // an outline, readable anywhere
         if (!g16 [r][c] && ((r > 0 && g16 [r - 1][c] == 1) || (g16 [r + 1][c] == 1) || (c > 0 && g16 [r][c - 1] == 1) || g16 [r][c + 1] == 1))
            g16 [r][c] = 2;
      g16_put (T_SFONT + 4 * i);
   }
}

// ---- sprites
static const char *const player_img [16] = {
   "................", "....11111111....", "...1222222221...", "..122222222231..",
   "..122422422231..", "..122422422231..", "..122222222231..", "..122222222231..",
   "..122111112231..", "..122222222231..", "..122222222231..", "..122222222231..",
   "..133333333331..", "...1111111111...", "................", "................" };
static const char *const feet [4][2] = {
   { "...55......55...", "..555......555.." },     // standing
   { "...55.......55..", "..555........55." },     // running
   { "....55.....55...", "....555...555..." },
   { "....55....55....", "................" } };   // jumping
static const char *const enemy_img [2][16] = {
   { "................", "................", "...1........1...", "....1......1....",
     ".....111111.....", "....12222221....", "...1223223221...", "...1222332221...",
     "...1223223221...", "....12222221....", ".....111111.....", "....1......1....",
     "...1........1...", "..44........44..", "................", "................" },
   { "................", "................", "....1......1....", "....1......1....",
     ".....111111.....", "....12222221....", "...1223223221...", "...1222332221...",
     "...1223223221...", "....12222221....", ".....111111.....", ".....1....1.....",
     "....1......1....", "....44....44....", "................", "................" } };
static const char *const heart_img [16] = {
   "................", "..11...11.......", ".1221.1221......", "122221222221....",
   "12222222221.....", ".122222221......", "..1222221.......", "...12221........",
   "....121.........", ".....1..........", "................", "................",
   "................", "................", "................", "................" };
static const char *const cons_img [16] = {
   "................", "................", "................", "1111111111111...",
   "1222221333331...", "1222221333331...", "1222221333331...", "1222221333331...",
   "1222221333331...", "1111111111111...", "................", "................",
   "................", "................", "................", "................" };
static const char *const paren_img [16] = {
   ".....111........", "....1221........", "...1221.........", "..1221..........",
   "..121...........", ".1221...........", ".121............", ".121............",
   ".121............", ".121............", ".1221...........", "..121...........",
   "..1221..........", "...1221.........", "....1221........", ".....111........" };
static const char *const arrow_img [16] = {
   "................", "................", "................", "................",
   "........1.......", "........11......", "1111111112 1....", "1222222222221...",
   "1222222222221...", "1111111112 1....", "........11......", "........1.......",
   "................", "................", "................", "................" };
static const char *const wave_img [16] = {
   "................", "................", "................", "................",
   "................", "................", "................", "......11........",
   ".....1221.......", "....122221......", "...12233221.....", "..1223333221....",
   ".122333333221...", "12233333333221..", "1233333333333211", "1111111111111111" };
static const char *const switch_img [16] = {
   "................", "....11111111....", "...1222222221...", "...1211111121...",
   "...1213333121...", "...1213333121...", "...1211111121...", "...1222222221...",
   "....11111111....", "......1441......", "......1441......", "......1441......",
   ".....155551.....", "....15555551....", "....11111111....", "................" };
static const char *const light_img [16] = {
   "......1111......", ".....133331.....", "....13444431....", "....13444431....",
   ".....133331.....", "......1221......", "......1221......", "......1221......",
   "......1221......", "......1221......", "......1221......", "......1221......",
   ".....122221.....", "....12222221....", "...1111111111...", "................" };
static const char *const clock_img [16] = {
   "................", ".....111111.....", "....12222221....", "...1222142221...",
   "..122221422221..", "..122221422221..", "..122221444221..", "..122222222221..",
   "..122222222221..", "...1222222221...", "....12222221....", ".....111111.....",
   "......1551......", ".....155551.....", "................", "................" };
static const char *const minion_img [16] = {
   "................", "................", "................", "................",
   "................", "................", "......1111......", ".....122221.....",
   "....12322321....", "....12222221....", "....12222221....", ".....122221.....",
   "......1111......", ".....1....1.....", "....44....44....", "................" };
static const char *const bigmin_img [16] = {
   "................", "....11111111....", "...1222222221...", "..122222222221..",
   "..123322223321..", "..123422224321..", "..122222222221..", "..122222222221..",
   "..122111111221..", "..122222222221..", "..122222222221..", "...1222222221...",
   "....11111111....", "...11......11...", "..444......444..", "................" };
static const char *const ghost_img [16] = {
   ".....111111.....", "....1......1....", "...1..1111..1...", "...1.1....1.1...",
   "........1..1....", ".......1...1....", "......1....1....", "......1...1.....",
   "......1..1......", "................", "......11........", "......11........",
   "................", "................", "................", "................" };
static const char *const cursor_img [16] = {
   "................", "..11............", "..121...........", "..1221..........",
   "..12221.........", "..122221........", "..12221.........", "..1221..........",
   "..121...........", "..11............", "................", "................",
   "................", "................", "................", "................" };

static void put_rows (int n, const char *const rows [16]) { g16_rows (rows); g16_put (n); }

static void make_sprites (void) {
   for (int f = 0; f < 4; f++) {
      g16_rows (player_img);
      for (int k = 0; k < 2; k++)
         for (int c = 0; c < 16; c++) { char ch = feet [f][k][c]; g16 [14 + k][c] = (uint8_t) (ch == '5' ? 5 : 0); }
      if (f == 3) for (int c = 0; c < 16; c++) { g16 [12][c] = g16 [13][c]; }
      g16_put (T_PLAYER + 4 * f);
   }
   g16_clear ();                                   // the lemma: a little glowing bar, "L"
   for (int c = 2; c < 10; c++) { g16 [6][c] = 1; g16 [7][c] = 2; g16 [8][c] = 1; }
   g16 [5][2] = g16 [4][2] = 1; g16 [5][3] = 2; g16 [4][3] = 1; g16 [7][9] = 3;
   g16_put (T_SHOT);
   put_rows (T_HEART, heart_img);
   put_rows (T_ENEMY, enemy_img [0]); put_rows (T_ENEMY + 4, enemy_img [1]);
   g16_clear (); g16_disc (16, 16, 4, 1, 2, 3); g16_put (T_ORB);
   g16_clear (); g16_disc (16, 16, 2, 1, 2, 0); g16_put (T_ORB_S);
   g16_clear (); g16_disc (16, 16, 6, 1, 2, 3); g16_put (T_ORB_M);
   g16_clear (); g16_disc (16, 16, 8, 1, 2, 3); g16_put (T_ORB_L);
   put_rows (T_CONS, cons_img);
   put_rows (T_PAREN_L, paren_img);
   g16_rows (paren_img);                           // the closing paren: the mirror image
   for (int r = 0; r < 16; r++) for (int c = 0; c < 8; c++) { uint8_t v = g16 [r][c]; g16 [r][c] = g16 [r][15 - c]; g16 [r][15 - c] = v; }
   g16_put (T_PAREN_R);
   g16_clear (); g16_disc (16, 16, 6, 1, 0, 0); g16_disc (16, 16, 3, 1, 2, 3); g16_put (T_NODE);
   put_rows (T_ARROW, arrow_img);
   put_rows (T_WAVE, wave_img);
   g16_clear ();
   for (int i = 0; i < 12; i++) { g16 [2][2 + i] = g16 [13][2 + i] = 1; g16 [2 + i][2] = g16 [2 + i][13] = 1; }
   g16_put (T_VEC);
   g16_clear (); g16_disc (16, 16, 2, 1, 2, 0); g16_put (T_DOT);
   put_rows (T_LIGHT, light_img);
   put_rows (T_SWITCH, switch_img);
   put_rows (T_CLOCK, clock_img);
   put_rows (T_MINION, minion_img);
   put_rows (T_BIGMIN, bigmin_img);
   g16_clear ();                                   // a drop
   for (int r = 2; r < 14; r++) { int w = r < 8 ? (r - 2) / 2 : (14 - r) / 2 + 1; for (int c = 8 - w; c <= 7 + w; c++) g16 [r][c] = (uint8_t) (c == 8 - w || c == 7 + w || r == 13 ? 1 : 2); }
   g16_put (T_DROP);
   g16_clear (); for (int i = 0; i < 16; i += 2) { g16 [i][i] = 3; g16 [i][15 - i] = 2; g16 [7][i] = 3; g16 [i][7] = 2; } g16_put (T_SPARK);
   g16_clear (); for (int k = 0; k < 8; k++) { uint32_t r = rnd (); g16_disc ((int) (r % 20) + 6, (int) ((r >> 8) % 20) + 6, 3, 1, 2, 0); } g16_put (T_PUFF);
   put_rows (T_GHOST, ghost_img);
   put_rows (T_CURSOR, cursor_img);
}

// ---- the bosses: a robed figure with the boss's emblem on the chest (not a likeness)
static uint8_t g32 [32][32];
static void make_boss_tiles (int b) {
   const char *em = bosses [b].emblem;
   if (b < 6) {                                     // a caricature; frame 1 (attacking) hops a row up
      for (int f = 0; f < 2; f++) {
         for (int r = 0; r < 32; r++)
            for (int c = 0; c < 32; c++) {
               int sr = r + f;
               char ch = sr < 32 ? portrait_rows [b][sr][c] : '0';
               g32 [r][c] = (uint8_t) (ch <= '9' ? ch - '0' : ch - 'a' + 10);
            }
         for (int q = 0; q < 4; q++) {
            for (int r = 0; r < 16; r++) for (int c = 0; c < 16; c++) g16 [r][c] = g32 [r + 16 * (q >> 1)][c + 16 * (q & 1)];
            g16_put (T_BOSS + 32 * b + 16 * f + 4 * q);
         }
      }
      return;
   }
   for (int f = 0; f < 2; f++) {
      for (int r = 0; r < 32; r++) for (int c = 0; c < 32; c++) g32 [r][c] = 0;
      for (int r = 0; r < 32; r++)                 // the robe: wider toward the hem
         for (int c = 0; c < 32; c++) {
            int half = r < 12 ? 0 : 6 + (r - 12) / 2;
            if (r >= 12 && c >= 16 - half && c < 16 + half) g32 [r][c] = (uint8_t) (c == 16 - half || c == 15 + half || r == 31 ? 1 : (c < 16 ? 3 : 6));
         }
      for (int r = 0; r < 14; r++)                 // the head
         for (int c = 0; c < 32; c++) {
            int dx = 2 * c + 1 - 32, dy = 2 * r + 1 - 14, d = dx * dx + dy * dy;
            if (d <= 4 * 36) g32 [r][c] = (uint8_t) (d > 4 * 25 ? 1 : 2);
         }
      g32 [6][13] = g32 [6][18] = 5; g32 [7][13] = g32 [7][18] = 5;      // eyes
      g32 [10][14] = g32 [10][15] = g32 [10][16] = g32 [10][17] = 1;     // mouth
      for (int c = 10; c < 22; c++) g32 [1][c] = g32 [2][c] = 7;         // a cap in the trim colour
      g32 [3][10] = g32 [3][21] = 7;
      for (int k = 0; k < 2; k++) {                 // arms: down, or raised in the attack frame
         int side = k ? 1 : -1;
         for (int i = 0; i < 7; i++) {
            int r = f ? 16 - i : 14 + i, c = 16 + side * (8 + i / 2);
            if (r >= 0 && r < 32 && c >= 0 && c < 32) { g32 [r][c] = 3; if (c + 1 < 32) g32 [r][c + 1] = 1; }
         }
         int hr = f ? 9 : 21, hc = 16 + side * 12;
         if (hc >= 1 && hc < 31) { g32 [hr][hc] = g32 [hr][hc - 1] = g32 [hr + 1][hc] = 2; }
      }
      int g = glyph (em [0]);                       // the emblem, 2x, on the chest
      for (int r = 0; r < 7; r++)
         for (int c = 0; c < 5; c++)
            if (font7 [g][r] & (16 >> c))
               for (int k = 0; k < 4; k++) g32 [15 + 2 * r + (k >> 1)][11 + 2 * c + (k & 1)] = 4;
      for (int q = 0; q < 4; q++) {
         for (int r = 0; r < 16; r++) for (int c = 0; c < 16; c++) g16 [r][c] = g32 [r + 16 * (q >> 1)][c + 16 * (q & 1)];
         g16_put (T_BOSS + 32 * b + 16 * f + 4 * q);
      }
   }
}

// ================================================================ the world map
int k_solid (int k) { return k == K_GROUND || k == K_BRICK || k == K_PILLAR || k == K_PIVOT || k == K_GATE || k == K_ZONE
                             || k == K_BELT || k == K_HOT || k == K_MARKED || k == K_DOOMED; }
int solid_px (int x, int y) {
   if (y < 0 || y >= 8 * ROWS) return 0;
   if (x < 0 || x >= 8 * wcols) return 1;
   return k_solid (kind [y >> 3][x >> 3]);
}
static int plane_owner [64];          // which world column each plane column shows
static int text_rows [ROWS];          // rows holding text (not drawn from the kinds) ...
static int text_c0 = 1 << 30;         // ... from this world column on (the screen's)
static uint16_t kind_entry (int c, int r) {
   int k = kind [r][c];
   switch (k) {
   case K_GROUND: return vdp_map_entry (r > 0 && k_solid (kind [r - 1][c]) ? BT_FILL : BT_TOP, B_TERRAIN, (c * 7 + r) & 1, 0);
   case K_NULL:   return vdp_map_entry (BT_NULL, B_TERRAIN, 0, 0);
   case K_BRICK:  return vdp_map_entry (BT_BRICK, B_BRICK, 0, 0);
   case K_GONE:   return vdp_map_entry (BT_GONE, B_BRICK, 0, 0);
   case K_PILLAR: return vdp_map_entry (BT_PILLAR, B_PROP, 0, 0);
   case K_PIVOT:  return vdp_map_entry (BT_PIVOT, B_PROP, 0, 0);
   case K_GATE:   return vdp_map_entry (BT_GATE, B_PROP, 0, 0);
   case K_ZONE:   return vdp_map_entry (BT_ZONE, B_TERRAIN, 0, 0);
   case K_STATE:  return vdp_map_entry (BT_RED, B_COLOR, 0, 0);
   case K_BELT:   return vdp_map_entry (BT_GREEN, B_COLOR, 0, 0);
   case K_HOT:    return vdp_map_entry (BT_BLUE, B_COLOR, 0, 0);
   case K_MARKED: return vdp_map_entry (BT_MARKED, B_BRICK, 0, 0);
   case K_DOOMED: return vdp_map_entry (BT_DOOMED, B_BRICK, 0, 0);
   default: {
      uint32_t h = (uint32_t) (c * 2654435761u) ^ (uint32_t) (r * 40503u);
      h ^= h >> 13;
      if (r < 22 && h % 29 == 0) return vdp_map_entry ((h >> 8) & 1 ? BT_STAR1 : BT_STAR2, B_SKY, 0, 0);
      return 0;
   } }
}
static void draw_cell (int c, int r) {
   if (c < 0 || c >= wcols || r < 0 || r >= ROWS) return;
   if (plane_owner [c & 63] != c) return;
   if (text_rows [r] && c >= text_c0 && c < text_c0 + ACOLS + 1) return;
   plane_set (c, r, kind_entry (c, r));
   if (r + 1 < ROWS && kind [r + 1][c] == K_GROUND) plane_set (c, r + 1, kind_entry (c, r + 1));   // top or fill
}
void tile_set (int c, int r, int k) {
   if (c < 0 || c >= wcols || r < 0 || r >= ROWS || kind [r][c] == k) return;
   kind [r][c] = (uint8_t) k;
   draw_cell (c, r);
}
static void draw_column (int c) {
   plane_owner [c & 63] = c;
   for (int r = 0; r < ROWS; r++) {
      if (text_rows [r] && c >= text_c0 && c < text_c0 + ACOLS + 1) continue;
      plane_set (c, r, c >= 0 && c < wcols ? kind_entry (c, r) : 0);
   }
}
static void stream (void) {
   for (int c = (cam >> 3) - 1; c <= (cam >> 3) + 41; c++)
      if (c >= 0 && c < wcols && plane_owner [c & 63] != c) draw_column (c);
}
static void text_put (int col, int row, const char *s, int bnk) {    // plane columns (world col)
   for (int i = 0; s [i]; i++) plane_set (col + i, row, vdp_map_entry (T_FONT + glyph (s [i]), bnk, 0, 0));
}
static int slen (const char *s) { int n = 0; while (s [n]) n++; return n; }
void arena_text (int row, const char *s) {
   if (row < 0 || row >= ROWS) return;
   int a = cam >> 3;
   text_c0 = a;
   text_rows [row] = 1;
   for (int c = 0; c < ACOLS; c++) plane_set (a + c, row, kind_entry (a + c, row));
   int n = slen (s); if (n > ACOLS) n = ACOLS;
   for (int i = 0; i < n; i++) plane_set (a + (ACOLS - n) / 2 + i, row, vdp_map_entry (T_FONT + glyph (s [i]), B_TEXT, 0, 0));
}
void arena_clear_text (int row) {
   if (row < 0 || row >= ROWS) return;
   int a = text_c0;
   if (a > WMAX) return;
   text_rows [row] = 0;
   for (int c = 0; c < ACOLS; c++)
      if (a + c < wcols && plane_owner [(a + c) & 63] == a + c) plane_set (a + c, row, kind_entry (a + c, row));
}

// ================================================================ objects
bullet bul [NBUL];
prop props [NPROP];
minion mins [NMIN];
boss_t boss;
int cur_boss;
int pl_x, pl_y, pl_dead;
static int pl_fx, pl_fy, pl_vy, pl_face, pl_ground, pl_hurt, pl_lives, pl_cool, pl_anim, pl_prev;
static int score;
static int spawn_x, spawn_y;
typedef struct { int on, x, y, vx, proved; } shot_t;
int pl_certs, shot_proved;
static shot_t shots [3];

int bullet_new (int k, int x, int y, int vx, int vy, int tile, int bnk) {
   for (int i = 0; i < NBUL; i++)
      if (!bul [i].on) {
         bullet *b = &bul [i];
         b->on = 1; b->x = x; b->y = y; b->vx = vx; b->vy = vy; b->kind = k; b->t = 0;
         b->a = b->b = b->c = 0; b->tile = tile; b->bank = bnk; b->flags = 0; b->harm = 4;
         return i;
      }
   return -1;
}
int bullet_solid (const bullet *b) { return solid_px ((b->x >> 4) + 8, (b->y >> 4) + 8); }
int minion_new (int x, int y, int vx, int hp, int tile, int bnk) {
   for (int i = 0; i < NMIN; i++)
      if (!mins [i].on) {
         minion *m = &mins [i];
         m->on = 1; m->x = x << 4; m->y = y << 4; m->vx = vx; m->vy = 0; m->hp = hp; m->kind = 0;
         m->t = 0; m->tile = tile; m->bank = bnk; m->label = -1;
         return i;
      }
   return -1;
}

// ---- the player
static int box_solid (int x, int y) {        // the player's box with its sprite at (x, y)
   for (int yy = y + 2; yy <= y + 15; yy += 4)
      for (int xx = x + 3; xx <= x + 12; xx += 3)
         if (solid_px (xx, yy) || solid_px (x + 12, yy) || solid_px (xx, y + 15)) return 1;
   return 0;
}
void player_bump_up (void) {
   for (int i = 0; i < 40 && box_solid (pl_x, pl_y); i++) pl_y--;
   pl_fy = pl_y << 4;
}
static int g_state;
enum { G_TITLE, G_PLAY, G_ARENA, G_FIGHT, G_WIN, G_OVER, G_END };
static int g_timer;
#ifdef PROOF_TEST
// host test hook (never in the board build): PROOF_TEST=<boss>,<move> starts the demo pilot at
// that boss's arena, invulnerable, with the fight opening on that move
#include <stdlib.h>
static int test_boss = -1, test_move;
#endif
void player_hurt (void) {
#ifdef PROOF_TEST
   if (test_boss >= 0) return;
#endif
   if (pl_hurt || pl_dead || g_state == G_WIN) return;
   pl_lives--; pl_hurt = 90; psnd_hurt ();
   if (pl_lives <= 0) pl_dead = 1;
}
void set_spawn (int x, int y) { spawn_x = x; spawn_y = y; }
void player_push (int dx) {
   int nx = (pl_fx + dx) >> 4;
   if (nx != pl_x && box_solid (nx, pl_y)) return;
   pl_fx += dx; pl_x = pl_fx >> 4;
}
static void pit_respawn (void) {
   player_hurt ();
   pl_x = spawn_x; pl_y = spawn_y; pl_fx = pl_x << 4; pl_fy = pl_y << 4; pl_vy = 0;
   player_bump_up ();
}

static void player_update (uint32_t b) {
   if (pl_dead) return;
   int dx = 0;
   if (b & BTN_LEFT)  { dx = -24; pl_face = 1; }
   if (b & BTN_RIGHT) { dx = 24; pl_face = 0; }
   int nx = (pl_fx + dx) >> 4;
   for (int s = 0; s < 2 && pl_x != nx; s++) {
      int step = isgn (nx - pl_x);
      if (box_solid (pl_x + step, pl_y)) break;
      pl_x += step;
   }
   pl_fx = pl_x == nx ? pl_fx + dx : pl_x << 4;
   if ((b & BTN_UP) && !(pl_prev & BTN_UP) && pl_ground) { pl_vy = -84; psnd_jump (); }
   if (!(b & BTN_UP) && pl_vy < -30) pl_vy = -30;
   pl_vy += 5; if (pl_vy > 112) pl_vy = 112;
   int ny = (pl_fy + pl_vy) >> 4;
   pl_ground = 0;
   for (int s = 0; s < 8 && pl_y != ny; s++) {
      int step = isgn (ny - pl_y);
      if (box_solid (pl_x, pl_y + step)) { if (step > 0) pl_ground = 1; pl_vy = 0; ny = pl_y; break; }
      pl_y += step;
   }
   pl_fy = pl_y == ny ? pl_fy + pl_vy : pl_y << 4;
   if (!pl_ground && pl_vy >= 0 && box_solid (pl_x, pl_y + 1)) pl_ground = 1;
   if (pl_x < cam) { pl_x = cam; pl_fx = pl_x << 4; }
   if (pl_y > 8 * ROWS) pit_respawn ();
   if (pl_cool) pl_cool--;
   if ((b & BTN_FIRE2) && !pl_cool)
      for (int i = 0; i < 3; i++) if (!shots [i].on) {
         shots [i].on = 1; shots [i].x = pl_x + (pl_face ? -4 : 8); shots [i].y = pl_y + 3;
         shots [i].vx = pl_face ? -5 : 5; pl_cool = 10; psnd_shot ();
         shots [i].proved = pl_certs > 0; if (pl_certs > 0) pl_certs--;
         break;
      }
   if (pl_hurt) pl_hurt--;
   pl_anim = !pl_ground ? 3 : dx ? 1 + ((t >> 3) & 1) : 0;
   pl_prev = (int) b;
}

static int overlap (int ax, int ay, int aw, int ah, int bx, int by, int bw, int bh) {
   return ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah;
}
static void shots_update (void) {
   for (int i = 0; i < 3; i++) {
      shot_t *s = &shots [i];
      if (!s->on) continue;
      s->x += s->vx;
      int cx = s->x + 6, cy = s->y + 7;
      if (s->x < cam - 16 || s->x > cam + 320 || solid_px (cx, cy)) { s->on = 0; continue; }
      for (int m = 0; m < NMIN && s->on; m++)
         if (mins [m].on && overlap (cx - 3, cy - 2, 6, 4, (mins [m].x >> 4) + 2, (mins [m].y >> 4) + 2, 12, 14)) {
            s->on = 0;
            if (--mins [m].hp <= 0) {
               mins [m].on = 0; score += 100;
               int k = bullet_new (2, mins [m].x, mins [m].y, 0, 0, T_PUFF, B_BUL2);
               if (k >= 0) bul [k].harm = 0;
               psnd_boss_hit ();
            } else psnd_tink ();
         }
      if (!s->on) continue;
      shot_proved = s->proved;
      if (g_state == G_FIGHT && bosses [cur_boss].shot_other (cx, cy)) { s->on = 0; continue; }
      if (g_state == G_FIGHT && boss.on && !boss.hidden && cx >= boss.x + 2 && cx < boss.x + 30 && cy >= boss.y + 2 && cy < boss.y + 32) {
         s->on = 0;
         if (bosses [cur_boss].shot_hits (cx, cy)) boss_damage (boss.stun ? 2 : 1);
         else { psnd_tink (); int k = bullet_new (2, (cx - 8) << 4, (cy - 8) << 4, 0, 0, T_SPARK, B_BUL2); if (k >= 0) bul [k].harm = 0; }
      }
   }
}

static void bullets_update (void) {
   for (int i = 0; i < NBUL; i++) {
      bullet *b = &bul [i];
      if (!b->on) continue;
      b->t++;
      if (b->kind == 0) { b->x += b->vx; b->y += b->vy; if (bullet_solid (b) && b->t > 4) b->on = 0; }
      else if (b->kind == 1) { b->vy += 4; b->x += b->vx; b->y += b->vy; if (bullet_solid (b)) b->on = 0; }
      else if (b->kind == 2) { if (b->t > 16) b->on = 0; }
      int x = b->x >> 4, y = b->y >> 4;
      if (x < cam - 48 || x > cam + 360 || y > 8 * ROWS + 16 || y < -96) { b->on = 0; continue; }
      if (b->harm && !pl_dead && overlap (pl_x + 3, pl_y + 2, 10, 14, x + 8 - b->harm, y + 8 - b->harm, 2 * b->harm, 2 * b->harm))
         player_hurt ();
   }
}
static void minions_update (void) {
   for (int i = 0; i < NMIN; i++) {
      minion *m = &mins [i];
      if (!m->on) continue;
      m->t++;
      int x = m->x >> 4, y = m->y >> 4;
      if (m->kind == 1 && (m->t & 31) == 0) m->vx = pl_x > x ? iabs (m->vx) : -iabs (m->vx);   // chasers
      int nx = (m->x + m->vx) >> 4;
      int ahead = m->vx > 0 ? nx + 13 : nx + 2;
      if (solid_px (ahead, y + 8) || (m->kind == 0 && !solid_px (ahead, y + 17) && solid_px (x + 8, y + 17))) m->vx = -m->vx;
      else m->x += m->vx;
      m->vy += 4; if (m->vy > 96) m->vy = 96;
      int ny = (m->y + m->vy) >> 4;
      if (m->vy > 0 && solid_px ((m->x >> 4) + 8, ny + 16)) { m->vy = 0; m->y = (((ny + 16) & ~7) - 16) << 4; }
      else m->y += m->vy;
      if ((m->y >> 4) > 8 * ROWS) { m->on = 0; continue; }
      if (!pl_dead && overlap (pl_x + 3, pl_y + 2, 10, 14, (m->x >> 4) + 3, (m->y >> 4) + 4, 10, 12)) player_hurt ();
   }
}

// ================================================================ the boss's framework
void boss_damage (int n) {
   if (boss.flash) return;
   boss.hp -= n; boss.flash = 14; score += 10 * n;
   psnd_boss_hit ();
}
void boss_cue (const char *s) { arena_text (3, s); psnd_cue (); }
static void boss_bar (void) {
   int a = arena_x >> 3;
   text_c0 = a;
   text_rows [1] = 1;
   int cells = (boss.hp * 20 + BOSS_HP - 1) / BOSS_HP;
   for (int i = 0; i < 20; i++)
      plane_set (a + 10 + i, 1, vdp_map_entry (i < cells ? BT_BAR : BT_BAREMPTY, B_HUD, 0, 0));
}

// ================================================================ stages
static const uint32_t sky_cols [] = { 0x9090C0, 0xFFFFFF };
static void stage_palette (int b) {
   const boss_def *d = &bosses [b];
   uint32_t sky = d->sky;
   pal_set (1, sky);
   uint32_t terr [4] = { 0x101018, 0, 0, 0xE0D0A0 };
   terr [1] = ((d->trim >> 2) & 0x3F3F3F) + 0x202020;
   terr [2] = ((d->trim >> 1) & 0x7F7F7F) + 0x202020;
   bank_set (B_TERRAIN, terr, 4);
   uint32_t brick [5] = { 0x201810, 0x8C5A3C, 0xC08860, 0x60FF90, 0xFF3030 };
   brick [1] = ((d->body >> 1) & 0x7F7F7F) + 0x303030;
   brick [2] = ((d->body >> 1) & 0x7F7F7F) + 0x606060;
   bank_set (B_BRICK, brick, 5);
   uint32_t bossc [7] = { 0x101010, 0xE8C8A0, 0, 0, 0x101010, 0, 0 };
   bossc [2] = d->body; bossc [3] = d->trim; bossc [5] = (d->body >> 1) & 0x7F7F7F; bossc [6] = d->trim;
   if (b < 6) bank_set (B_BOSS, portrait_pal [b], 15);
   else bank_set (B_BOSS, bossc, 7);
   (void) sky_cols;
}

static void build_stage (int b) {
   uint32_t save = rs;
   rs = 0x1234567u * (uint32_t) (b + 1) | 1;
   wcols = 112 + ACOLS + 8 * (b > 3);
   arena_x = 8 * (wcols - ACOLS);
   for (int r = 0; r < ROWS; r++) for (int c = 0; c < WMAX; c++) kind [r][c] = K_AIR;
   for (int r = 0; r < ROWS; r++) text_rows [r] = 0;
   int c = 0, g = 24;
   while (c < wcols - ACOLS) {
      int len = 5 + (int) (rnd () % 6);
      if (c + len > wcols - ACOLS - 6 || c < 12) { len = c < 12 ? 12 - c : wcols - ACOLS - c; }
      int last = c + len >= wcols - ACOLS;
      if (last) g = FLOOR;
      for (int i = c; i < c + len && i < wcols - ACOLS; i++)
         for (int r = g; r < ROWS; r++) kind [r][i] = K_GROUND;
      if (!last && len >= 6 && rnd () % 3 == 0) {        // a floating ledge above
         int lr = g - 4 - (int) (rnd () % 2), lc = c + 1 + (int) (rnd () % 2);
         for (int i = lc; i < lc + 3 + (int) (rnd () % 2); i++) if (lr > 4) kind [lr][i] = K_BRICK;
      }
      if (!last && c > 14 && rnd () % 6 == 0) {           // an enemy on this segment
         int k = minion_new (8 * (c + len / 2), 8 * g - 16, rnd () & 1 ? 8 : -8, 1, T_ENEMY, B_ENEMY);
         (void) k;
      }
      c += len;
      if (c < wcols - ACOLS - 10 && c > 14 && rnd () % 4 == 0) c += 2 + (int) (rnd () % 2);   // a gap
      int ng = g + (int) (rnd () % 5) - 2;
      g = ng < 18 ? 18 : ng > 26 ? 26 : ng;
   }
   int a = wcols - ACOLS;
   for (int i = a; i < wcols; i++) for (int r = FLOOR; r < ROWS; r++) kind [r][i] = K_GROUND;
   for (int r = 0; r < FLOOR; r++) kind [r][wcols - 1] = K_BRICK;
   rs = save;
   stage_palette (b);
   bosses [b].arena ();
   for (int i = 0; i < 64; i++) plane_owner [i] = -1;
}

// ================================================================ game flow
static int demo, demo_boss, idle, sel, defeated;
static uint32_t pilot (void);

static void clear_objects (void) {
   for (int i = 0; i < NBUL; i++) bul [i].on = 0;
   for (int i = 0; i < NPROP; i++) props [i].on = 0;
   for (int i = 0; i < NMIN; i++) mins [i].on = 0;
   for (int i = 0; i < 3; i++) shots [i].on = 0;
   boss.on = 0;
}
static void start_stage (int b) {
   cur_boss = b;
   clear_objects ();
   build_stage (b);
   pl_x = spawn_x = 24; pl_y = spawn_y = 8 * 24 - 16;
   pl_fx = pl_x << 4; pl_fy = pl_y << 4; pl_vy = 0; pl_lives = 5; pl_dead = 0; pl_hurt = 0; pl_face = 0; pl_certs = 0;
   player_bump_up ();
   cam = 0;
   g_state = G_PLAY; g_timer = 0;
   psnd_tune (7);
}
static void title_screen (void) {
   clear_objects ();
   wcols = 40; arena_x = 0;
   for (int r = 0; r < ROWS; r++) { text_rows [r] = 0; for (int c = 0; c < WMAX; c++) kind [r][c] = r >= FLOOR ? K_GROUND : K_AIR; }
   stage_palette (sel);
   for (int i = 0; i < 64; i++) plane_owner [i] = -1;
   cam = 0;
   for (int c = 0; c < 64; c++) draw_column (c);
   text_put (12, 3, "PROOF OBLIGATION", B_TEXT);
   text_put (7, 5, "A FORMAL METHODS PLATFORMER", B_HUD);
   for (int i = 0; i < 7; i++) {
      text_put (6, 8 + 2 * i, bosses [i].name, B_TEXT);
      text_put (22, 8 + 2 * i, bosses [i].field, B_HUD);
      if (defeated & (1 << i)) text_put (4, 8 + 2 * i, "#", B_TEXT);
   }
   text_put (5, 24, "UP DOWN: CHOOSE  FIRE: PROVE IT", B_HUD);
   if (demo) text_put (17, 1, "DEMO", B_HUD);
   g_state = G_TITLE; g_timer = 0;
   psnd_tune (8);
}

void proof_init (void) {
   make_bg_tiles ();
   make_sprites ();
   for (int b = 0; b < 7; b++) make_boss_tiles (b);
   static const uint32_t text [] = { 0xFFFFFF, 0x404040 };
   static const uint32_t hud [] = { 0xA0A0B0, 0xFF4040, 0xFFA0A0 };
   static const uint32_t player [] = { 0x202028, 0xF0F0F0, 0xA0A0B0, 0x101010, 0x806040 };
   static const uint32_t enemy [] = { 0x300808, 0xE03030, 0xFFE0E0, 0x602020 };
   static const uint32_t shot [] = { 0xFFFF80, 0xFFFFFF, 0xFFC040 };
   static const uint32_t b1 [] = { 0x400000, 0xFF6040, 0xFFE0A0 };
   static const uint32_t b2 [] = { 0x102040, 0x60C0FF, 0xE0FFFF };
   static const uint32_t prop [] = { 0x202020, 0x808890, 0xC0C8D0, 0xFFD040, 0xFFF0A0 };
   static const uint32_t sky [] = { 0xA0A0C0, 0xFFFFFF };
   static const uint32_t col [] = { 0xD03030, 0x30B040, 0x3060E0, 0xFFFFFF, 0x202020 };
   pal_set (0, 0x000000);
   bank_set (B_TEXT, text, 2); bank_set (B_HUD, hud, 3); bank_set (B_PLAYER, player, 5);
   bank_set (B_ENEMY, enemy, 4); bank_set (B_SHOT, shot, 3); bank_set (B_BUL, b1, 3);
   bank_set (B_BUL2, b2, 3); bank_set (B_PROP, prop, 5); bank_set (B_SKY, sky, 2);
   bank_set (B_COLOR, col, 5);
   psnd_init ();
   hw_vdp_write (VDP_BACKDROP, 1);
   for (int i = 0; i < 128; i++) { spr_sh [i] = 0; spr_hw [i] = 0xFFFFFFFFu; }
   ctrl_sh = 3;
   hw_video_on ();
   demo = 1; demo_boss = 0; idle = 0; sel = 0;
#ifdef PROOF_TEST
   if (getenv ("PROOF_TEST")) {
      sscanf (getenv ("PROOF_TEST"), "%d,%d", &test_boss, &test_move);
      demo_boss = test_boss;
      start_stage (test_boss);
      pl_x = spawn_x = arena_x - 16; pl_fx = pl_x << 4; pl_fy = pl_y << 4; player_bump_up ();
      return;
   }
#endif
   start_stage (0);
}

// ---- the attract pilot: runs right, jumps gaps, walls and dangers, throws lemmas
static uint32_t pilot (void) {
   uint32_t b = 0;
   if (g_state == G_TITLE) return 0;
   int fx = pl_x + 8, feet = pl_y + 16;
   if (g_state == G_PLAY || g_state == G_ARENA) {
      b |= BTN_RIGHT;
      int wall = solid_px (fx + 10, pl_y + 8) || solid_px (fx + 10, pl_y + 14);
      int gap = !solid_px (fx + 12, feet + 2) && !solid_px (fx + 12, feet + 10);
      int foe = 0;
      for (int i = 0; i < NMIN; i++) if (mins [i].on && iabs ((mins [i].x >> 4) - pl_x) < 40 && (mins [i].x >> 4) > pl_x) foe = 1;
      if ((wall || gap || (foe && (t & 15) < 3)) && (t & 1)) b |= BTN_UP;
      if (pl_vy < 0) b |= BTN_UP;
      if ((t & 7) == 0) b |= BTN_FIRE2;
   } else if (g_state == G_FIGHT) {
      int want = arena_x + 64 + (int) ((t >> 6) % 3) * 40;
      if (boss.shield && pl_certs == 0)                   // a checker wants proofs: fetch a floor certificate
         for (int i = 0; i < NPROP; i++)
            if (props [i].on && props [i].tile == sfont ('#') && props [i].y > pl_y - 8) want = props [i].x;
      if (pl_x < want - 4) b |= BTN_RIGHT;
      if (pl_x > want + 4) b |= BTN_LEFT;
      int danger = 0;
      for (int i = 0; i < NBUL; i++)
         if (bul [i].on && bul [i].harm) {
            int dx = (bul [i].x >> 4) - pl_x, dy = (bul [i].y >> 4) - pl_y;
            if (iabs (dx) < 36 && dy > -40 && dy < 16) danger = 1;
         }
      if (danger && (t & 1)) b |= BTN_UP;
      if (pl_vy < 0 && danger) b |= BTN_UP;
      if (boss.x < pl_x && (t & 1)) b = (b & ~BTN_RIGHT) | BTN_LEFT;
      if ((t & 3) == 0) b |= BTN_FIRE2;
   }
   return b;
}

// ---- drawing (into the shadow)
enum { S_HEART = 0, S_SCORE = 5, S_PLAYER = 11, S_SHOT = 12, S_BOSS = 15, S_BUL = 19, S_MIN = 43, S_PROP = 51, S_CURSOR = 61 };
static void draw (void) {
   for (int i = 0; i < 5; i++)
      if (g_state != G_TITLE && i < pl_lives) spr (S_HEART + i, 4 + 12 * i, 226, T_HEART, B_HUD, VDP_SPR_ON); else spr_off (S_HEART + i);
   int v = score;
   for (int i = 5; i >= 0; i--) {
      if (g_state != G_TITLE) spr (S_SCORE + i, 266 + 8 * i, 226, sfont ((char) ('0' + v % 10)), B_TEXT, VDP_SPR_ON); else spr_off (S_SCORE + i);
      v /= 10;
   }
   int blink = pl_hurt && (t & 4);
   if (g_state == G_TITLE || pl_dead || blink) spr_off (S_PLAYER);
   else spr (S_PLAYER, pl_x - cam, pl_y, T_PLAYER + 4 * pl_anim, B_PLAYER, (pl_face ? VDP_SPR_HFLIP : 0) | VDP_SPR_ON);
   for (int i = 0; i < 3; i++)
      if (shots [i].on) spr (S_SHOT + i, shots [i].x - cam, shots [i].y, T_SHOT, shots [i].proved ? B_BUL2 : B_SHOT, VDP_SPR_ON | (shots [i].vx < 0 ? VDP_SPR_HFLIP : 0));
      else spr_off (S_SHOT + i);
   if (boss.on && !boss.hidden && !(boss.flash & 2)) {
      int base = T_BOSS + 32 * cur_boss + 16 * boss.frame;
      for (int q = 0; q < 4; q++) spr (S_BOSS + q, boss.x - cam + 16 * (q & 1), boss.y + 16 * (q >> 1), base + 4 * q, B_BOSS, VDP_SPR_ON);
   } else if (g_state == G_TITLE) {                   // the chosen boss, top right
      for (int q = 0; q < 4; q++) spr (S_BOSS + q, 278 + 16 * (q & 1), 8 + 16 * (q >> 1), T_BOSS + 32 * sel + 4 * q, B_BOSS, VDP_SPR_ON);
   } else for (int q = 0; q < 4; q++) spr_off (S_BOSS + q);
   for (int i = 0; i < NBUL; i++)
      if (bul [i].on && (bul [i].y >> 4) <= 210)   // lower, it is in the ground and would cost HUD-line slots
         spr (S_BUL + i, (bul [i].x >> 4) - cam, bul [i].y >> 4, bul [i].tile, bul [i].bank, VDP_SPR_ON | bul [i].flags);
      else spr_off (S_BUL + i);
   for (int i = 0; i < NMIN; i++)
      if (mins [i].on) spr (S_MIN + i, (mins [i].x >> 4) - cam, mins [i].y >> 4, mins [i].tile + ((mins [i].t >> 3) & 1) * (mins [i].tile == T_ENEMY ? 4 : 0), mins [i].bank, VDP_SPR_ON | (mins [i].vx > 0 ? VDP_SPR_HFLIP : 0));
      else spr_off (S_MIN + i);
   for (int i = 0; i < NPROP; i++)
      if (props [i].on) spr (S_PROP + i, props [i].x - cam, props [i].y, props [i].tile, props [i].bank, VDP_SPR_ON | props [i].flags);
      else spr_off (S_PROP + i);
   if (g_state == G_TITLE) spr (S_CURSOR, 32, 8 * (8 + 2 * sel) - 4, T_CURSOR, B_TEXT, VDP_SPR_ON);
   else spr_off (S_CURSOR);
   scroll_sh = (uint32_t) (cam & 511);
}

static void next_demo (void) { demo_boss = (demo_boss + 1) % 7; sel = demo_boss; title_screen (); }

int proof_frame (uint32_t buttons) {
   flush ();
   t++;
   if (buttons) { idle = 0; if (demo) { demo = 0; title_screen (); } }
   else if (idle < 1200) idle++;
   if (demo) buttons = pilot ();
   psnd_frame ();
   g_timer++;
   switch (g_state) {
   case G_TITLE: {
      static uint32_t prev;
      uint32_t edge = buttons & ~prev; prev = buttons;
      if (edge & BTN_UP) sel = (sel + 6) % 7;
      if (edge & BTN_DOWN) sel = (sel + 1) % 7;
      if ((edge & (BTN_UP | BTN_DOWN)) && !demo) stage_palette (sel);
      if (demo && g_timer > 180) start_stage (demo_boss);
      else if (!demo && (edge & BTN_FIRE2) && g_timer > 20) start_stage (sel);
      else if (!demo && idle >= 1200) { demo = 1; demo_boss = sel; title_screen (); }
      break;
   }
   case G_PLAY: case G_ARENA:
      player_update (buttons);
      shots_update (); minions_update (); bullets_update ();
      if (g_state == G_PLAY) {
         int want = pl_x - 140;
         cam = want < 0 ? 0 : want > arena_x ? arena_x : want;
         if (pl_x >= arena_x + 24) { g_state = G_ARENA; g_timer = 0; }
      } else {
         if (cam < arena_x) cam += 4;
         if (cam > arena_x) cam = arena_x;
         if (cam == arena_x && g_timer > 10) {
            int a = arena_x >> 3;
            for (int r = 0; r < FLOOR; r++) tile_set (a, r, K_BRICK);
            for (int i = 0; i < NMIN; i++) mins [i].on = 0;
            spawn_x = arena_x + 24; spawn_y = 8 * FLOOR - 16;
            boss.on = 1; boss.hp = BOSS_HP; boss.flash = 0; boss.frame = 0; boss.hidden = 0;
            boss.timer = 0; boss.attack = 0; boss.cycle = 0; boss.phase = 0; boss.stun = 0; boss.shield = 0;
            for (int i = 0; i < 8; i++) boss.a [i] = 0;
            boss.x = arena_x + 8 * 30; boss.y = 8 * FLOOR - 32;
            arena_text (0, bosses [cur_boss].name);
#ifdef PROOF_TEST
            if (test_boss >= 0) boss.attack = test_move;
#endif
            g_state = G_FIGHT; g_timer = 0;
            psnd_tune (cur_boss);
         }
      }
      break;
   case G_FIGHT:
      player_update (buttons);
      if (g_timer > 60) bosses [cur_boss].update ();
      else if (g_timer == 2) arena_text (3, bosses [cur_boss].field);
      else if (g_timer == 60) arena_clear_text (3);
      shots_update (); minions_update (); bullets_update ();
      if (boss.flash) boss.flash--;
      if (boss.on && !boss.hidden && !pl_dead && overlap (pl_x + 3, pl_y + 2, 10, 14, boss.x + 6, boss.y + 4, 20, 28)) player_hurt ();
      boss_bar ();
      if (boss.hp <= 0) {
         boss.on = 0; g_state = G_WIN; g_timer = 0; score += 1000; psnd_boom (); psnd_tune (9);
         for (int i = 0; i < NBUL; i++) bul [i].on = 0;
         for (int i = 0; i < NMIN; i++) mins [i].on = 0;
         for (int i = 0; i < NPROP; i++) props [i].on = 0;
         for (int r = 3; r <= 7; r++) arena_clear_text (r);
         arena_text (3, "Q.E.D.");
         arena_text (5, "PROOF OBLIGATION DISCHARGED");
         if (!demo) defeated |= 1 << cur_boss;
      }
      break;
   case G_WIN:
      player_update (buttons & ~BTN_FIRE2);
      if (g_timer > 240) {
         if (demo) next_demo ();
         else if (defeated == 127) {
            g_state = G_END; g_timer = 0;
            arena_text (8, "ALL SEVEN OBLIGATIONS");
            arena_text (9, "ARE DISCHARGED.");
            arena_text (11, "THE SYSTEM IS CORRECT.");
            arena_text (13, "#");
         } else title_screen ();
      }
      break;
   case G_OVER:
      if (g_timer > 180) { if (demo) next_demo (); else title_screen (); }
      break;
   case G_END:
      if (g_timer > 120 && (buttons & BTN_FIRE2)) { defeated = 0; title_screen (); }
      break;
   }
   if ((g_state == G_PLAY || g_state == G_ARENA || g_state == G_FIGHT) && pl_dead) {
      g_state = G_OVER; g_timer = 0;
      for (int r = 3; r <= 7; r++) arena_clear_text (r);
      arena_text (3, "PROOF FAILED"); arena_text (5, "COUNTEREXAMPLE FOUND");
   }
   if (demo && (g_state == G_PLAY || g_state == G_ARENA) && g_timer > 2400) next_demo ();
   if (demo && g_state == G_FIGHT && g_timer > 2400) next_demo ();
   if (g_state != G_TITLE) stream ();
   draw ();
   return score;
}
