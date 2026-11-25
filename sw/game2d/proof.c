// sw/game2d/proof.c: Proof Obligation, the game2d platformer (an original game): the engine,
// graphics, title, stages and player.  You are a tombstone (the end-of-proof mark); run and jump
// with the D-pad (UP jumps), throw lemmas with FIRE2.  Each of the seven stages has its own
// gimmick and enemies and ends in an arena where a boss attacks with their ideas (proof_boss.c);
// discharge all seven proof obligations.  A defeated boss gives you their tactic (a weapon; DOWN
// changes it), and each boss is weak to one tactic (weakness []).  With no input the game plays
// itself (the attract demo, which owns every tactic and visits every boss in turn).
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
static int8_t belt_dir [WMAX];        // a stage conveyor in this column: +1 right, -1 left (0: the arena's)
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

static int flush_pal, flush_map, flush_spr, flush_reg;   // this frame's writes (the spec's V2)
static void flush (void) {
   flush_pal = flush_map = flush_spr = flush_reg = 0;
   for (int i = 0; i < 256; i++)
      if (pal_dirty [i]) { pal_dirty [i] = 0; hw_palette (i, pal_sh [i]); flush_pal++; }
   int k = 0;
   while (pn > 0 && k < MAP_FLUSH_MAX) {
      int w = plist [--pn];
      pdirty [w] = 0;
      int r = w / 32, c = 2 * (w % 32);
      hw_vdp_write (VDP_MAP + 4 * (uint32_t) w, (uint32_t) plane [r][c] | ((uint32_t) plane [r][c + 1] << 16));
      k++;
   }
   flush_map = k;
   for (int i = 0; i < 128; i++)
      if (spr_sh [i] != spr_hw [i]) { spr_hw [i] = spr_sh [i]; hw_vdp_write (VDP_SPRITES + 4 * (uint32_t) i, spr_sh [i]); flush_spr++; }
   if (scroll_sh != scroll_hw) { scroll_hw = scroll_sh; hw_vdp_write (VDP_BG_SCROLL, scroll_sh); flush_reg++; }
   if (ctrl_sh != ctrl_hw) { ctrl_hw = ctrl_sh; hw_vdp_write (VDP_CTRL, ctrl_sh); flush_reg++; }
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
       BT_RED, BT_GREEN, BT_BLUE, BT_MARKED, BT_DOOMED, BT_STAR1, BT_STAR2, BT_BAR, BT_BAREMPTY,
       BT_BELT = 31 };                  // 19-30 free (the font starts at 32)

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
   tile_fill (5);                                     // a stage conveyor: chevrons show its way
   for (int c = 0; c < 8; c++) { px (0, c, 4); px (6, c, 3); px (7, c, 3); }
   for (int k = 0; k < 2; k++) { px (1, 1 + 4 * k, 4); px (2, 2 + 4 * k, 4); px (3, 3 + 4 * k, 4); px (4, 2 + 4 * k, 4); px (5, 1 + 4 * k, 4); }
   px (7, 1, 5); px (7, 5, 5);
   tile_put (BT_BELT);
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

// ---- the weapons (tactics), the HUD gauge, the stage enemies and pickups (tiles 672-767)
// weapon art: 1 the edge, 2 the core, 3 the glow (bank B_SHOT; B_BUL2 when it carries a proof)
static const char *const icon_img [7][16] = {
   { "................", "................", "................", "................",    // CONS: a cell
     "1111111111111...", "1222221333331...", "1222221333331...", "1222221333331...",
     "1222221333331...", "1111111111111...", "................", "................",
     "................", "................", "................", "................" },
   { "................", "..........111...", ".........12221..", ".........12321..",    // PATH: a path
     ".........12221..", "........3.111...", ".......3........", "..111.3.........",
     ".12223..........", ".12321..........", ".12221..........", "..111...........",
     "................", "................", "................", "................" },
   { "................", "...111....111...", "..122......221..", "..12........21..",    // BRACES: { }
     "..12........21..", "..12........21..", ".122........221.", "122..........221",
     ".122........221.", "..12........21..", "..12........21..", "..12........21..",
     "..122......221..", "...111....111...", "................", "................" },
   { "................", ".....111111.....", "...1122222211...", "..122222322221..",    // TICK: a clock
     "..122222322221..", ".12222223222221.", ".12222223222221.", ".12222223333321.",
     ".12222222222221.", ".12222222222221.", "..122222222221..", "..122222222221..",
     "...1122222211...", ".....111111.....", "................", "................" },
   { "................", "..........1111..", ".........12221..", "........12221...",    // CPS: there
     ".......12221....", "......12221.....", ".....12221......", "....12221.......",    // and back
     "....12221.......", ".....12221......", "......12221.....", ".......12221....",
     "........12221...", ".........12221..", "..........1111..", "................" },
   { "................", "......111.......", ".....12221......", ".....12321......",    // TRINITY
     ".....12221......", "......111.......", "................", "................",
     "..111......111..", ".12221....12221.", ".12321....12321.", ".12221....12221.",
     "..111......111..", "................", "................", "................" },
   { "................", "................", "................", "................",    // CRUSH: a wave
     "................", "................", ".......11.......", "......1221......",
     ".....123321.....", "....12333321....", "...1233333321...", "..123333333321..",
     ".12333333333321.", "1233333333333321", "1222222222222221", "1111111111111111" } };
static const char *const energy_img [16] = {
   "................", "................", "....11111111....", "...1222222221...",
   "...1233333321...", "...1233333321...", "...1222222221...", "...1233333321...",
   "...1233333321...", "...1222222221...", "....11111111....", "................",
   "................", "................", "................", "................" };
// stage enemies (bank B_ENEMY: 1 dark, 2 red, 3 pale, 4 darker; the crusher B_PROP)
static const char *const flyer_img [2][16] = {
   { "................", "................", "1..............1", "11............11",
     "121...1111...121", "1221.122221.1221", ".12212333321221.", "..122233332221..",
     "...1122332211...", ".....122221.....", "......1111......", "................",
     "................", "................", "................", "................" },
   { "................", "................", "................", "................",
     "......1111......", ".....122221.....", "...1123333211...", "..122233332221..",
     ".12212233221221.", "1221.122221.1221", "121...1111...121", "11............11",
     "1..............1", "................", "................", "................" } };
static const char *const hopper_img [2][16] = {
   { "................", "................", ".....111111.....", "....12222221....",
     "...1232222321...", "...1222222221...", "...1222222221...", "....12222221....",
     ".....111111.....", "......1..1......", ".....1....1.....", "......1..1......",
     ".....1....1.....", "......1..1......", "....444..444....", "................" },
   { "................", "................", "................", "................",
     "................", "................", ".....111111.....", "....12222221....",
     "...1232222321...", "...1222222221...", "...1222222221...", "....12222221....",
     ".....111111.....", ".....1.11.1.....", "....444..444....", "................" } };
static const char *const turret_img [16] = {
   "................", "................", "................", "................",
   "................", "................", "1111111.........", "1222221111......",
   "11111112221.....", "......123321....", ".....12333321...", "....1222222221..",
   "...122222222221.", "...144444444441.", "...111111111111.", "................" };
static const char *const crusher_img [16] = {
   "......1111......", "......1221......", "1111111111111111", "1333333333333331",
   "1322222222222231", "1322222222222231", "1322111111112231", "1322222222222231",
   "1322222222222231", "1333333333333331", "1111111111111111", "1212121212121212",
   ".1.1.1.1.1.1.1.1", "................", "................", "................" };
static void make_weapon_sprites (void) {
   for (int w = 0; w < 7; w++) put_rows (T_ICON + 4 * w, icon_img [w]);
   for (int lv = 0; lv < 8; lv++) {               // the gauge: a dark frame, 2 pixels a level
      g16_clear ();
      for (int c = 0; c < 16; c++) { g16 [5][c] = g16 [10][c] = 1; }
      for (int r = 5; r <= 10; r++) g16 [r][0] = g16 [r][15] = 1;
      for (int r = 6; r <= 9; r++)
         for (int c = 1; c < 15; c++) g16 [r][c] = (uint8_t) (c <= 2 * lv ? (r == 6 ? 5 : 4) : 1);
      g16_put (T_GAUGE + 4 * lv);
   }
   put_rows (T_ENERGY, energy_img);
   put_rows (T_FLYER, flyer_img [0]); put_rows (T_FLYER + 4, flyer_img [1]);
   put_rows (T_HOPPER, hopper_img [0]); put_rows (T_HOPPER + 4, hopper_img [1]);
   put_rows (T_TURRET, turret_img);
   put_rows (T_CRUSHER, crusher_img);
   g16_clear (); g16_disc (16, 16, 4, 1, 2, 3); g16_put (T_PELLET);
   g16_clear ();                                  // a brace, '{' (flipped: '}'), 16 tall
   for (int r = 0; r < 16; r++) {
      int c = r < 6 ? 6 : r < 10 ? (r == 7 || r == 8 ? 3 : 4) : 6;
      if (r == 0 || r == 15) c = 7;
      g16 [r][c] = 2; g16 [r][c + 1] = 2; g16 [r][c - 1] = 1; g16 [r][c + 2] = 1;
   }
   g16 [0][9] = g16 [15][9] = 2; g16 [0][10] = g16 [15][10] = 1;
   g16_put (T_BRACE);
}
// ---- the boss framework's sprites, tiles 768-831 (T_BLOCK ... in proof_int.h) and their banks
// 14-15: blue bullets are a pause sign (stand still), orange ones a play sign (keep moving), pink
// ones a diamond drawn in nibbles 4-6 of bank 15 (parry it)
static void make_mode_sprites (void) {
   g16_clear ();                                   // T_BLOCK: a rounded square, a pause sign
   for (int r = 2; r < 14; r++) for (int c = 2; c < 14; c++)
      if (!((r == 2 || r == 13) && (c == 2 || c == 13))) g16 [r][c] = (uint8_t) (r == 2 || r == 13 || c == 2 || c == 13 ? 1 : 2);
   for (int r = 5; r < 11; r++) { g16 [r][6] = g16 [r][9] = 3; }
   g16_put (T_BLOCK);
   g16_clear ();                                   // T_CHEV: a play sign (points right)
   for (int r = 2; r < 14; r++) {
      int w = r < 8 ? r - 2 : 13 - r;
      for (int c = 3; c <= 3 + 2 * w && c < 15; c++) g16 [r][c] = (uint8_t) (c == 3 || c == 3 + 2 * w || r == 2 || r == 13 ? 1 : (r == 7 || r == 8) && c < 2 + 2 * w ? 3 : 2);
   }
   g16_put (T_CHEV);
   g16_clear ();                                   // T_PINK: a diamond, nibbles 4-6
   for (int r = 0; r < 16; r++) for (int c = 0; c < 16; c++) {
      int d = iabs (2 * r + 1 - 16) + iabs (2 * c + 1 - 16);
      if (d <= 13) g16 [r][c] = (uint8_t) (d > 10 ? 4 : d < 4 ? 6 : 5);
   }
   g16_put (T_PINK);
   g16_clear ();                                   // T_RING: a dashed warning ring with a !
   for (int r = 0; r < 16; r++) for (int c = 0; c < 16; c++) {
      int dx = 2 * c + 1 - 16, dy = 2 * r + 1 - 16, d = dx * dx + dy * dy;
      if (d >= 4 * 36 && d <= 4 * 56 && ((r + c) & 2)) g16 [r][c] = 3;
   }
   for (int r = 4; r < 12; r++) if (r != 9) g16 [r][7] = g16 [r][8] = 3;
   g16_put (T_RING);
   g16_clear ();                                   // T_FORK
   for (int r = 1; r < 15; r++) { g16 [r][7] = 2; g16 [r][8] = 1; }
   for (int c = 4; c < 12; c++) g16 [6][c] = 1;
   for (int r = 1; r < 6; r++) { g16 [r][4] = 2; g16 [r][11] = 2; }
   g16_put (T_FORK);
   g16_clear (); g16_disc (16, 16, 7, 1, 2, 0);   // T_PHIL: a philosopher, thinking
   g16 [6][5] = g16 [6][10] = 1; for (int c = 6; c < 10; c++) g16 [10][c] = 1;
   g16 [3][7] = g16 [3][8] = 3;
   g16_put (T_PHIL);
   g16_clear ();                                   // T_MIRROR: a tall glass
   for (int r = 0; r < 16; r++) { g16 [r][5] = 1; g16 [r][6] = 3; g16 [r][7] = 2; g16 [r][8] = 2; g16 [r][9] = 3; g16 [r][10] = 1; }
   for (int r = 2; r < 14; r += 4) g16 [r][7] = 3;
   g16_put (T_MIRROR);
   g16_clear ();                                   // T_TRAMP: a trampoline
   for (int c = 0; c < 16; c++) { g16 [9][c] = 1; g16 [10][c] = 3; g16 [11][c] = 1; }
   for (int r = 12; r < 16; r++) { g16 [r][2] = 2; g16 [r][13] = 2; }
   g16_put (T_TRAMP);
   for (int k = 0; k < 2; k++) {                   // T_POS, T_NEG: polarized orbs
      g16_clear (); g16_disc (16, 16, 6, 1, 2, 0);
      for (int c = 5; c < 11; c++) g16 [7][c] = g16 [8][c] = 3;
      if (k == 0) for (int r = 5; r < 11; r++) g16 [r][7] = g16 [r][8] = 3;
      g16_put (k ? T_NEG : T_POS);
   }
   g16_clear (); g16_put (T_BLANK);                // T_BLANK: nothing (a blinking warning's off phase)
}
static void mode_palettes (void) {
   static const uint32_t blue [] = { 0x10106A, 0x2848FF, 0xF0F4FF };
   static const uint32_t mode [] = { 0x803000, 0xFF8418, 0xFFE860, 0x80104A, 0xFF5CC8, 0xFFFFFF };
   bank_set (B_BLUE, blue, 3); bank_set (B_MODE, mode, 6);
}

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
   make_weapon_sprites ();
   make_mode_sprites ();
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
   case K_NULL:   return vdp_map_entry (r > 0 && kind [r - 1][c] == K_NULL ? BT_FILL : BT_NULL, B_TERRAIN, 0, 0);
   case K_BRICK:  return vdp_map_entry (BT_BRICK, B_BRICK, 0, 0);
   case K_GONE:   return vdp_map_entry (BT_GONE, B_BRICK, 0, 0);
   case K_PILLAR: return vdp_map_entry (BT_PILLAR, B_PROP, 0, 0);
   case K_PIVOT:  return vdp_map_entry (BT_PIVOT, B_PROP, 0, 0);
   case K_GATE:   return vdp_map_entry (BT_GATE, B_PROP, 0, 0);
   case K_ZONE:   return vdp_map_entry (BT_ZONE, B_TERRAIN, 0, 0);
   case K_STATE:  return vdp_map_entry (BT_RED, B_COLOR, 0, 0);
   case K_BELT:   return belt_dir [c] ? vdp_map_entry (BT_BELT, B_COLOR, belt_dir [c] < 0, 0) : vdp_map_entry (BT_GREEN, B_COLOR, 0, 0);
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
#ifdef PROOF_TEST
   for (int i = 0; s [i]; i++) if (s [i] != ' ' && !glyph (s [i])) fprintf (stderr, "text: no glyph for '%c' in \"%s\"\n", s [i], s);
   if (slen (s) > ACOLS) fprintf (stderr, "text: longer than %d: \"%s\"\n", ACOLS, s);
#endif
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
// a player projectile: kind is the weapon that threw it; fx, fy, vx, vy in SUB units, x, y the
// sprite's top left in pixels; t its age; a its state (braces: 0 orbiting, 1 thrown; CPS: 0 out,
// 1 back); hit: the minions a piercing CPS has already hit (bit i)
typedef struct { int on, kind, x, y, fx, fy, vx, vy, proved, t, a, hit; } shot_t;
int pl_certs, shot_proved;
static shot_t shots [3];

// ---- the weapons (tactics): weapon b + 1 is won by beating boss b
int pl_weapon, pl_owned = 1, pl_energy [NWEAPON];
static unsigned got_hearts, got_energy;   // pickups taken since power-on (the spec's S2, W5)
int clock_stop;
static const int w_cost [NWEAPON] = { 0, 1, 2, 4, 7, 2, 1, 3 };
static const char *const w_name [NWEAPON] = { "LEMMA", "CONS", "PATH", "BRACES", "TICK", "CPS", "TRINITY", "CRUSH" };
static const char *const w_says [NWEAPON] = {      // what a tactic does (36 characters at most)
   "", "THE CAR FLIES UP, THE CDR STRAIGHT", "THE SHORTEST PATH TO THE NEAREST FOE",
   "{P} {Q} GUARD YOU. FIRE THROWS THEM", "STOPS THE CLOCK: NOTHING ELSE MOVES",
   "OUT, THEN THE CONTINUATION RETURNS", "THREE WAYS AT ONCE, ALL THE SAME",
   "SHOCKWAVES BOTH WAYS ALONG THE FLOOR" };
// the weakness cycle, boss b's weakness (a weapon); each a real connection (the notes say which):
// McCarthy <- CRUSH, Dijkstra <- TICK, Hoare <- PATH, Lamport <- BRACES, Appel <- CONS,
// Harper <- CPS, Chlipala <- TRINITY
const int weakness [7] = { W_CRUSH, W_TICK, W_PATH, W_BRACES, W_CONS, W_CPS, W_TRINITY };
static const int cos32 [32] = { 64, 63, 59, 53, 45, 36, 24, 12, 0, -12, -24, -36, -45, -53, -59, -63,
                                -64, -63, -59, -53, -45, -36, -24, -12, 0, 12, 24, 36, 45, 53, 59, 63 };
static int c32 (int a) { return cos32 [a & 31]; }
static int s32 (int a) { return cos32 [(a - 8) & 31]; }
static void aim (int x0, int y0, int x1, int y1, int speed, int *vx, int *vy) {   // SUB a frame
   int dx = x1 - x0, dy = y1 - y0, ax = iabs (dx), ay = iabs (dy);
   int d = ax > ay ? ax + ay / 2 : ay + ax / 2;
   if (d == 0) { *vx = speed; *vy = 0; return; }
   *vx = dx * speed / d; *vy = dy * speed / d;
}

int bullet_new (int k, int x, int y, int vx, int vy, int tile, int bnk) {
   for (int i = 0; i < NBUL; i++)
      if (!bul [i].on) {
         bullet *b = &bul [i];
         b->on = 1; b->x = x; b->y = y; b->vx = vx; b->vy = vy; b->kind = k; b->t = 0;
         b->a = b->b = b->c = 0; b->tile = tile; b->bank = bnk; b->flags = 0; b->harm = 4; b->mode = M_NORMAL;
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
         m->t = 0; m->tile = tile; m->bank = bnk; m->label = -1; m->a = m->b = m->c = 0;
         return i;
      }
   return -1;
}

// ---- the stages' gimmicks: timed or triggered map cells (only while a stage runs, not a fight)
// GM_ALLOC (McCarthy): cons cells over a pit, allocated two columns at a time, then freed in
// order; GM_CLOCK (Lamport): platforms that blink and vanish on the shared tick; GM_CRUMBLE
// (Appel): marked platforms freed after you stand on them, reallocated later; GM_HOT (Harper):
// floor strips that warn, then burn.  Belts (Dijkstra, Chlipala) are static, belt_dir.
enum { GM_ALLOC, GM_CLOCK, GM_CRUMBLE, GM_HOT };
#define NGM 16
typedef struct { int type, c0, c1, r, a, b; } gimmick;     // columns c0..c1 of row r
static gimmick gm [NGM];
static int ngm;
static int gclk;                       // the stages' shared tick (stops with the clock, TICK)
#define ALLOC_T 240                    // a bridge's cycle: cell i at 14 i, all up at 14 n, freed from 150
#define CLOCK_T 150                    // solid to 84, blinking to 114, gone to 150
#define HOT_T   200                    // ground to 90, warning to 130, hot to 200
static int gm_cell_on (const gimmick *g, int c, int when) {     // solid at time `when`?
   switch (g->type) {
   case GM_ALLOC: {
      int p = (when + g->a) % ALLOC_T, i = (c - g->c0) / 2;
      return p >= 14 * i && p < 150 + 18 * i;
   }
   case GM_CLOCK: return (when + g->a) % CLOCK_T < 114;
   case GM_CRUMBLE: return g->a < 3;
   default: return 1;
   } }
static int gm_cell_hot (const gimmick *g, int when) { return g->type == GM_HOT && (when + g->a) % HOT_T >= 130; }
static int gm_at (int c, int r) {
   for (int i = 0; i < ngm; i++) if (gm [i].r == r && c >= gm [i].c0 && c <= gm [i].c1) return i;
   return -1;
}
static int box_solid (int x, int y);
static void gimmicks_update (void) {
   int changed = 0;
   for (int i = 0; i < ngm; i++) {
      gimmick *g = &gm [i];
      for (int c = g->c0; c <= g->c1; c++) {
         int k = kind [g->r][c], nk = k;
         switch (g->type) {
         case GM_ALLOC: nk = gm_cell_on (g, c, gclk) ? K_BRICK : K_GONE; break;
         case GM_CLOCK: {
            int p = (gclk + g->a) % CLOCK_T;
            nk = p < 84 ? K_BRICK : p < 114 ? (((p - 84) >> 3) & 1 ? K_BRICK : K_DOOMED) : K_GONE;
            break;
         }
         case GM_CRUMBLE: nk = g->a == 0 ? K_MARKED : g->a == 1 ? K_MARKED : g->a == 2 ? K_DOOMED : K_GONE; break;
         case GM_HOT: {
            int p = (gclk + g->a) % HOT_T;
            nk = p < 90 ? K_GROUND : p < 130 ? (((p - 90) >> 3) & 1 ? K_ZONE : K_GROUND) : K_HOT;
            break;
         } }
         if (nk != k) { tile_set (c, g->r, nk); changed |= k_solid (nk); }
      }
      if (g->type == GM_CRUMBLE) {                    // 0 idle, 1 stood on, 2 failing, 3 freed
         int pc = (pl_x + 8) >> 3;                    // stood on: your feet's centre on it
         int on = pl_y + 16 == 8 * g->r && pc >= g->c0 && pc <= g->c1;
         if (g->a == 0 && on) { g->a = 1; g->b = 0; }
         else if (g->a) {
            g->b++;
            if (g->a == 1 && g->b >= 26) g->a = 2;
            else if (g->a == 2 && g->b >= 44) g->a = 3;
            else if (g->a == 3 && g->b >= 230) g->a = 0;
         }
      }
   }
   if (changed && box_solid (pl_x, pl_y)) player_bump_up ();     // a cell came back where you are
}
// the stage's enemies wait in a list and enter when the camera nears them
#define NSPAWN 24
typedef struct { int x, y, kind, done; } spawn_t;
static spawn_t spawns [NSPAWN];
static int nspawn;
static void minion_spawn (int k, int x, int y) {
   static const int hp [6] = { 1, 1, 1, 2, 3, 99 };
   static const int tile [6] = { T_ENEMY, T_ENEMY, T_FLYER, T_HOPPER, T_TURRET, T_CRUSHER };
   int i = minion_new (x, y, k == MK_FLY ? -6 : k == MK_HOP || k >= MK_TURRET ? 0 : -8, hp [k], tile [k], k == MK_CRUSH ? B_PROP : B_ENEMY);
   if (i < 0) return;
   mins [i].kind = k; mins [i].a = x << 4; mins [i].b = y << 4; mins [i].c = 0;
   if (k == MK_CRUSH) mins [i].c = 40 + (x & 63);          // its first fall
}
static void spawns_update (int cam_x) {
   for (int i = 0; i < nspawn; i++)
      if (!spawns [i].done && spawns [i].x < cam_x + 336) {
         int free = 0;
         for (int m = 0; m < NMIN; m++) free += !mins [m].on;
         if (!free) return;
         spawns [i].done = 1;
         if (spawns [i].x > cam_x - 16) minion_spawn (spawns [i].kind, spawns [i].x, spawns [i].y);
      }
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
// host test hook (never in the board build): PROOF_TEST=<boss>,<move>[,<weapon>] starts the demo
// pilot at that boss's arena, invulnerable, with the fight opening on that move (and that weapon
// owned, selected, never running dry, the pilot firing it); PROOF_STAGE=<boss> starts the demo at
// that stage's beginning, damage on; PROOF_TRACE=1 prints state changes and hurts to stderr,
// PROOF_DBG=<from>,<to> the player frame by frame; a text line with a character the font lacks,
// or over 40, is reported (text:)
#include <stdlib.h>
static int test_boss = -1, test_move, test_weapon = -1, test_hp, test_clean, test_parry, test_poke;
void boss_poke (int k);
#endif
static int move_hit;                  // the player was hit during this boss move (no clean proof)
void player_hurt (void) {
#ifdef PROOF_TEST
   if (test_boss >= 0) { if (!test_clean) move_hit = 1; return; }
#endif
   if (pl_hurt || pl_dead || g_state == G_WIN) return;
   move_hit = 1;
   pl_lives--; pl_hurt = 90; psnd_hurt ();
#ifdef PROOF_TEST
   if (getenv ("PROOF_TRACE")) fprintf (stderr, "trace: frame %u boss %d hurt at x %d y %d (state %d)\n", t, cur_boss, pl_x, pl_y, g_state);
#endif
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

// ---- throwing: a weapon's projectiles take free shot slots; a tactic costs energy only if it fires
static int shots_free (void) { int n = 0; for (int i = 0; i < 3; i++) n += !shots [i].on; return n; }
static shot_t *shot_new (int k, int x, int y, int vx, int vy) {   // pixels; SUB a frame
   for (int i = 0; i < 3; i++)
      if (!shots [i].on) {
         shot_t *s = &shots [i];
         s->on = 1; s->kind = k; s->x = x; s->y = y; s->fx = x * SUB; s->fy = y * SUB; s->vx = vx; s->vy = vy;
         s->t = 0; s->a = 0; s->hit = 0;
         s->proved = pl_certs > 0; if (pl_certs > 0) pl_certs--;
         return s;
      }
   return 0;
}
static int braces_out (void) { for (int i = 0; i < 3; i++) if (shots [i].on && shots [i].kind == W_BRACES && shots [i].a == 0) return 1; return 0; }
static int cps_out (void) { for (int i = 0; i < 3; i++) if (shots [i].on && shots [i].kind == W_CPS) return 1; return 0; }
static void freeze_start (int n);
static void fire (int pressed) {
   int w = pl_weapon, dir = pl_face ? -1 : 1, fx0 = pl_x + (pl_face ? -4 : 8), cool = 10;
   if (w == W_BRACES && braces_out ()) {              // FIRE again: throw them
      if (!pressed) return;
      for (int i = 0; i < 3; i++)
         if (shots [i].on && shots [i].kind == W_BRACES && shots [i].a == 0) { shots [i].a = 1; shots [i].vx = 80 * dir; shots [i].vy = 0; }
      pl_cool = 10; psnd_fire (w);
      return;
   }
   if (pl_energy [w] < w_cost [w]) { if (pressed) psnd_tink (); return; }
   int need = w == W_CONS || w == W_BRACES || w == W_CRUSH ? 2 : 1;
   if (w == W_TICK) need = 0;
   if (shots_free () < need || (w == W_TICK && clock_stop) || (w == W_CPS && cps_out ()) || (w == W_CRUSH && !pl_ground)) return;
   switch (w) {
   case W_LEMMA: shot_new (W_LEMMA, fx0, pl_y + 3, 80 * dir, 0); break;
   case W_CONS: shot_new (W_CONS, fx0, pl_y - 2, 64 * dir, -32); shot_new (W_CONS, fx0, pl_y + 1, 80 * dir, 0); cool = 14; break;
   case W_PATH: shot_new (W_PATH, fx0, pl_y, 56 * dir, -16); cool = 16; break;
   case W_BRACES: {
      shot_t *s = shot_new (W_BRACES, pl_x, pl_y, 0, 0); if (s) s->hit = 0;
      s = shot_new (W_BRACES, pl_x, pl_y, 0, 0); if (s) s->hit = 16;   // half a turn behind
      cool = 20; break;
   }
   case W_TICK: {
      int weak = 0;
      if (g_state == G_FIGHT) weak = weakness [cur_boss] == W_TICK;
      freeze_start (weak ? 90 : 40); cool = 30; break;
   }
   case W_CPS: shot_new (W_CPS, fx0, pl_y, 112 * dir, 0); cool = 12; break;
   case W_TRINITY: {
      int n = shots_free ();
      shot_new (W_TRINITY, fx0, pl_y + 1, 80 * dir, 0);
      if (n >= 2) shot_new (W_TRINITY, fx0, pl_y + 1, 76 * dir, -28);
      if (n >= 3) shot_new (W_TRINITY, fx0, pl_y + 1, 76 * dir, 28);
      cool = 14; break;
   }
   case W_CRUSH: shot_new (W_CRUSH, pl_x + 6, pl_y, 64, 0); shot_new (W_CRUSH, pl_x - 6, pl_y, -64, 0); cool = 24; break;
   }
   int keep = 0;
#ifdef PROOF_TEST
   keep = test_weapon >= 0;                            // the test hook never runs dry
#endif
   if (!keep) pl_energy [w] -= w_cost [w];
   pl_cool = cool; psnd_fire (w);
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
   uint32_t edge = b & ~(uint32_t) pl_prev;
   if (edge & BTN_DOWN) {                              // the next owned weapon
      for (int k = 1; k <= NWEAPON; k++) {
         int w = (pl_weapon + k) % NWEAPON;
         if (pl_owned & (1 << w)) { pl_weapon = w; break; }
      }
      psnd_tink ();
   }
   if ((b & BTN_FIRE2) && !pl_cool) fire (edge & BTN_FIRE2);
   if (pl_hurt) pl_hurt--;
   pl_anim = !pl_ground ? 3 : dx ? 1 + ((t >> 3) & 1) : 0;
   pl_prev = (int) b;
}

static int overlap (int ax, int ay, int aw, int ah, int bx, int by, int bw, int bh) {
   return ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah;
}
static void minion_hit (int m, int dmg) {             // a projectile hit minion m
   minion *n = &mins [m];
   if (n->kind == MK_CRUSH) { psnd_tink (); return; }  // a crusher is not refuted
   n->hp -= dmg;
   if (n->hp > 0) { psnd_tink (); return; }
   n->on = 0; score += 100;
   int k = bullet_new (2, n->x, n->y, 0, 0, T_PUFF, B_BUL2);
   if (k >= 0) bul [k].harm = 0;
   if (g_state != G_FIGHT && rnd () % 3 == 0) {        // a drop: weapon energy, or a heart
      int heart = rnd () % 3 == 0;
      int j = bullet_new (heart ? BK_HEART : BK_ENERGY, n->x, n->y - (4 << 4), 0, -32, heart ? T_HEART : T_ENERGY, heart ? B_HUD : B_SHOT);
      if (j >= 0) bul [j].harm = 0;
   }
   psnd_boss_hit ();
}
// orbiting braces erase the harmful bullets they touch: only the engine's own kinds (0 straight,
// 1 falling), never a boss's objects (an LF node, a trinity orb, a pillar...), whose removal is
// the boss's business (shot_other)
static void braces_erase (int cx, int cy) {
   for (int i = 0; i < NBUL; i++) {
      bullet *b = &bul [i];
      if (b->on && b->harm && (b->kind == 0 || b->kind == 1) && iabs ((b->x >> 4) + 8 - cx) < 10 && iabs ((b->y >> 4) + 8 - cy) < 10) {
         b->kind = 2; b->harm = 0; b->t = 8; b->tile = T_SPARK; b->bank = B_BUL2; b->vx = b->vy = 0; b->flags = 0;
      }
   }
}
static void shots_update (void) {
   int pcx = pl_x + 8, pcy = pl_y + 8;
   for (int i = 0; i < 3; i++) {
      shot_t *s = &shots [i];
      if (!s->on) continue;
      s->t++;
      int orbit = s->kind == W_BRACES && s->a == 0;
      switch (s->kind) {
      case W_PATH: {                                  // steer for the nearest minion, else the boss
         int tx = 0, ty = 0, best = 1 << 30;
         for (int m = 0; m < NMIN; m++)
            if (mins [m].on && mins [m].kind != MK_CRUSH) {
               int mx = (mins [m].x >> 4) + 8, my = (mins [m].y >> 4) + 9, d = iabs (mx - s->x - 8) + iabs (my - s->y - 8);
               if (d < best && mx > cam && mx < cam + 320) { best = d; tx = mx; ty = my; }
            }
         if (best == 1 << 30 && g_state == G_FIGHT && boss.on && !boss.hidden) { best = 0; tx = boss.x + 16; ty = boss.y + 16; }
         if (best < 1 << 30 && s->t > 4) {
            int vx, vy; aim (s->x + 8, s->y + 8, tx, ty, 64, &vx, &vy);
            s->vx += 6 * isgn (vx - s->vx); s->vy += 6 * isgn (vy - s->vy);
         }
         if (s->t > 150) s->on = 0;
         break;
      }
      case W_BRACES:                                  // orbiting you, 22 pixels out (hit: the phase)
         if (orbit) {
            int a = s->hit + s->t;
            s->fx = (pcx - 8 + (c32 (a) * 22 >> 6)) * SUB; s->fy = (pcy - 8 + (s32 (a) * 22 >> 6)) * SUB;
            if (s->t > 420) s->on = 0;
         }
         break;
      case W_CPS:                                     // out, slowing; then the continuation: back to you
         if (s->a == 0) { if (s->t % 4 == 0) s->vx -= 8 * isgn (s->vx); if (s->vx == 0 || s->t > 60) s->a = 1; }
         else {
            aim (s->x + 8, s->y + 8, pcx, pcy, 88, &s->vx, &s->vy);
            if (iabs (s->x + 8 - pcx) < 10 && iabs (s->y + 8 - pcy) < 10) { s->on = 0; continue; }
         }
         if (s->t > 220) s->on = 0;
         break;
      }
      if (!s->on) continue;
      if (!orbit) { s->fx += s->vx; s->fy += s->vy; }
      s->x = s->fx >> 4; s->y = s->fy >> 4;
      int cx = s->x + 8, cy = s->y + 8;
      if (s->kind == W_LEMMA) { cx = s->x + 6; cy = s->y + 7; }
      if (s->kind == W_CRUSH) cy = s->y + 11;
      int through = orbit || s->kind == W_CPS;        // these pass walls
      if (s->x < cam - 24 || s->x > cam + 328 || (!through && solid_px (cx, cy))) { s->on = 0; continue; }
      if (s->kind == W_CRUSH && (!solid_px (cx, s->y + 17) || s->t > 90)) { s->on = 0; continue; }   // the floor ends
      if (orbit) braces_erase (cx, cy);
      int hw = s->kind == W_LEMMA ? 3 : 5, hh = s->kind == W_LEMMA ? 2 : 5;
      for (int m = 0; m < NMIN && s->on; m++)
         if (mins [m].on && overlap (cx - hw, cy - hh, 2 * hw, 2 * hh, (mins [m].x >> 4) + 2, (mins [m].y >> 4) + 2, 12, 14)) {
            if (s->kind == W_CPS) { if (s->hit & (1 << m)) continue; s->hit |= 1 << m; }   // pierces: each once
            else s->on = 0;
            minion_hit (m, 1);
         }
      if (!s->on) continue;
      // every projectile meets the boss through the boss's own rules: shot_other, then shot_hits
      shot_proved = s->proved;
      if (g_state == G_FIGHT && bosses [cur_boss].shot_other (cx, cy)) { s->on = 0; continue; }
      if (g_state == G_FIGHT && boss.on && !boss.hidden && cx >= boss.x + 2 && cx < boss.x + 30 && cy >= boss.y + 2 && cy < boss.y + 32) {
         s->on = 0;
         if (bosses [cur_boss].shot_hits (cx, cy)) {
            if (s->kind == weakness [cur_boss] && !boss.flash) {     // the weakness: 4, and a stun
               boss_damage (4);
               if (boss.stun < 40) boss.stun = 40;
               int k = bullet_new (2, (cx - 8) * SUB, (cy - 16) * SUB, 0, 0, T_SPARK, B_SHOT); if (k >= 0) bul [k].harm = 0;
            } else boss_damage (boss.stun ? 2 : 1);
         }
         else { psnd_tink (); int k = bullet_new (2, (cx - 8) << 4, (cy - 8) << 4, 0, 0, T_SPARK, B_BUL2); if (k >= 0) bul [k].harm = 0; }
      }
   }
}

static void pickup_update (bullet *b) {                // weapon energy or a heart, on the ground
   if (!clock_stop) {
      b->t++;
      b->vy += 4; if (b->vy > 64) b->vy = 64;
      int ny = (b->y + b->vy) >> 4;
      if (b->vy > 0 && solid_px ((b->x >> 4) + 8, ny + 16)) { b->vy = 0; b->y = (((ny + 16) & ~7) - 16) << 4; }
      else b->y += b->vy;
   }
   int x = b->x >> 4, y = b->y >> 4;
   if (b->t > 600 || x < cam - 48 || y > 8 * ROWS) { b->on = 0; return; }
   if (pl_dead || !overlap (pl_x + 3, pl_y + 2, 10, 14, x + 4, y + 4, 8, 8)) return;
   b->on = 0; score += 50; psnd_pick ();
   if (b->kind == BK_HEART) { got_hearts++; if (pl_lives < 5) pl_lives++; return; }
   got_energy++;
   int w = pl_weapon;
   if (w == W_LEMMA)                                  // the lemma needs none: the emptiest tactic
      for (int k = 1; k < NWEAPON; k++) if ((pl_owned & (1 << k)) && (w == W_LEMMA || pl_energy [k] < pl_energy [w])) w = k;
   if (w != W_LEMMA) { pl_energy [w] += 10; if (pl_energy [w] > W_ENERGY) pl_energy [w] = W_ENERGY; }
}
// the player's motion this frame (G_FIGHT sets them around player_update): moved, and the parry
// window (frames left after UP was newly pressed in the air)
static int pl_moved, pl_parry;
void player_bounce (int vy) { pl_vy = vy; pl_ground = 0; }
static void bullets_update (void) {
   for (int i = 0; i < NBUL; i++) {
      bullet *b = &bul [i];
      if (!b->on) continue;
      if (b->kind == BK_ENERGY || b->kind == BK_HEART) { pickup_update (b); continue; }
      if (!clock_stop) {                              // stopped clock: nothing moves, all still hurts
         b->t++;
         if (b->kind == 0) { b->x += b->vx; b->y += b->vy; if (bullet_solid (b) && b->t > 4) b->on = 0; }
         else if (b->kind == 1) { b->vy += 4; b->x += b->vx; b->y += b->vy; if (bullet_solid (b)) b->on = 0; }
         else if (b->kind == 2) { if (b->t > 16) b->on = 0; }
         else if (b->kind == 3) { b->harm = 0; b->tile = (b->t & 4) ? T_RING : T_BLANK; if (b->t > b->a) b->on = 0; }
         else if (b->kind == 4) { b->x += b->vx; b->y += b->vy; }
      }
      int x = b->x >> 4, y = b->y >> 4;
      if (x < cam - 48 || x > cam + 360 || y > 8 * ROWS + 16 || y < -96) { b->on = 0; continue; }
      if (!b->harm || pl_dead || !overlap (pl_x + 3, pl_y + 2, 10, 14, x + 8 - b->harm, y + 8 - b->harm, 2 * b->harm, 2 * b->harm)) continue;
      if (b->mode == M_BLUE && !pl_moved) continue;          // still: nothing bad happens
      if (b->mode == M_ORANGE && pl_moved) continue;         // moving: progress is made
      if (b->mode == M_PINK && pl_parry) {                   // parried: a proof certificate
         b->kind = 2; b->t = 0; b->harm = 0; b->mode = M_NORMAL; b->tile = T_SPARK; b->bank = B_MODE;
         pl_parry = 0; pl_certs++; score += 50; player_bounce (-70); psnd_cue ();
#ifdef PROOF_TEST
         printf ("parry: frame %u certs %d\n", t, pl_certs);
#endif
         continue;
      }
      player_hurt ();
   }
}
static int on_ground_at (int x, int y) { return solid_px (x + 8, y + 17); }   // a minion's feet
static void minion_fall (minion *m) {                 // gravity, landing on the ground
   m->vy += 4; if (m->vy > 96) m->vy = 96;
   int ny = (m->y + m->vy) >> 4;
   if (m->vy > 0 && solid_px ((m->x >> 4) + 8, ny + 16)) { m->vy = 0; m->y = (((ny + 16) & ~7) - 16) << 4; }
   else m->y += m->vy;
}
static void minions_update (void) {
   for (int i = 0; i < NMIN; i++) {
      minion *m = &mins [i];
      if (!m->on) continue;
      int x = m->x >> 4, y = m->y >> 4;
      if (g_state == G_PLAY && x < cam - 64) { m->on = 0; continue; }   // left behind
      if (!clock_stop) {
         m->t++;
         switch (m->kind) {
         case MK_FLY:                                  // a patrol about home (a, b), a sine bob
            if (iabs (m->x + m->vx - m->a) > 56 << 4) m->vx = -m->vx;
            m->x += m->vx;
            m->y = m->b + (s32 ((int) (m->t >> 1)) * 14 >> 6) * SUB;
            break;
         case MK_HOP:                                  // crouches, then jumps toward you
            if (on_ground_at (x, y) && m->vy >= 0) {
               m->vx = 0;
               if (++m->c >= 56) { m->c = 0; m->vy = -72; m->vx = pl_x > x ? 12 : -12; }
            } else if (!solid_px (m->vx > 0 ? x + 14 : x + 1, y + 8)) m->x += m->vx;
            minion_fall (m);
            break;
         case MK_TURRET:                               // stationary; fires at you every 120 frames
            minion_fall (m);
            if (m->t % 120 == 60 && x > cam && x < cam + 304 && iabs (pl_x - x) < 180) {
               int vx, vy; aim (x + 8, y + 6, pl_x + 8, pl_y + 8, 26, &vx, &vy);
               int k = bullet_new (0, x * SUB, (y - 2) * SUB, vx, vy, T_ORB, B_BUL);
               if (k >= 0) bul [k].harm = 3;
            }
            break;
         case MK_CRUSH:                                // a: 0 up, 1 falling, 2 down, 3 rising; c: timer
            if (m->a == 0) { if (--m->c <= 0) { m->a = 1; m->vy = 0; } }
            else if (m->a == 1) {
               m->vy += 10; if (m->vy > 112) m->vy = 112;
               int ny = (m->y + m->vy) >> 4;
               if (solid_px (x + 8, ny + 13)) { m->y = (((ny + 13) & ~7) - 13) << 4; m->a = 2; m->c = 36; if (x > cam && x < cam + 304) psnd_boom (); }
               else m->y += m->vy;
            } else if (m->a == 2) { if (--m->c <= 0) m->a = 3; }
            else { m->y -= 16; if (m->y <= m->b) { m->y = m->b; m->a = 0; m->c = 90; } }
            break;
         default: {                                    // walkers (0) and chasers (1)
            if (m->kind == MK_CHASE && (m->t & 31) == 0) m->vx = pl_x > x ? iabs (m->vx) : -iabs (m->vx);
            int nx = (m->x + m->vx) >> 4;
            int ahead = m->vx > 0 ? nx + 13 : nx + 2;
            if (solid_px (ahead, y + 8) || (m->kind == MK_WALK && !solid_px (ahead, y + 17) && solid_px (x + 8, y + 17))) m->vx = -m->vx;
            else m->x += m->vx;
            minion_fall (m);
         } }
      }
      if ((m->y >> 4) > 8 * ROWS) { m->on = 0; continue; }
      int crush = m->kind == MK_CRUSH;
      if (!pl_dead && overlap (pl_x + 3, pl_y + 2, 10, 14, (m->x >> 4) + (crush ? 1 : 3), (m->y >> 4) + (crush ? 2 : 4), crush ? 14 : 10, crush ? 11 : 12)) player_hurt ();
   }
}

// ================================================================ the boss's framework
void boss_damage (int n) {
   // only a fight's live boss takes damage, and not while flashing.  Every caller already
   // calls it only then (the shots check G_FIGHT and boss.on; the boss moves run only in the
   // fight); the guard makes it the writer's own precondition, which the modular proof of the
   // spec's S3 (formal/sw/cbmc/proof_rules.c) relies on instead of each caller's context
   if (g_state != G_FIGHT || !boss.on || boss.flash) return;
#ifdef PROOF_TEST
   if (test_hp > 0 && boss.hp - n < test_hp) n = boss.hp - test_hp;    // PROOF_HP pins the phase
#endif
   boss.hp -= n; boss.flash = 14; score += 10 * n;
   psnd_boss_hit ();
}
void boss_cue (const char *s) { arena_text (3, s); psnd_cue (); }
static int fight_rest, fight_pinch, fight_banner;
void boss_banner (const char *s) { arena_text (4, s); fight_banner = 150; psnd_cue (); }
// a boss move ended: if it did not hit the player, that was a clean proof (+500, a short rest)
void boss_move_end (void) {
#ifdef PROOF_TEST
   printf ("move end: frame %u boss %d move %d hp %d clean %d certs %d\n", t, cur_boss, boss.attack, boss.hp, !move_hit, pl_certs);
#endif
   if (!move_hit && boss.hp > 0) { score += 500; arena_text (7, "CLEAN PROOF +500"); fight_rest = 50; }
   move_hit = 0;
}
static void boss_bar (void) {
   int a = arena_x >> 3;
   text_c0 = a;
   text_rows [1] = 1;
   int cells = (boss.hp * 20 + BOSS_HP - 1) / BOSS_HP;
   if (g_state == G_FIGHT && g_timer <= 60 && cells > g_timer / 3) cells = g_timer / 3;   // the intro fills it
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

// each stage's identity: its gimmick (build_stage) and its enemies, the first twice as common
static const int stage_foes [7][3] = {
   { MK_HOP, MK_HOP, MK_WALK }, { MK_FLY, MK_FLY, MK_WALK }, { MK_TURRET, MK_WALK, MK_TURRET },
   { MK_FLY, MK_FLY, MK_WALK }, { MK_HOP, MK_HOP, MK_WALK }, { MK_TURRET, MK_FLY, MK_WALK },
   { MK_WALK, MK_CHASE, MK_CHASE } };
static void add_gm (int type, int c0, int c1, int r, int a) {
   if (ngm >= NGM) return;
   gm [ngm].type = type; gm [ngm].c0 = c0; gm [ngm].c1 = c1; gm [ngm].r = r; gm [ngm].a = a; gm [ngm].b = 0;
   ngm++;
}
static void add_spawn (int k, int x, int y) {
   if (nspawn >= NSPAWN) return;
   spawns [nspawn].kind = k; spawns [nspawn].x = x; spawns [nspawn].y = y; spawns [nspawn].done = 0;
   nspawn++;
}
static void stage_reset (void) {
   ngm = 0; nspawn = 0; gclk = 0;
   for (int c = 0; c < WMAX; c++) belt_dir [c] = 0;
}
static void build_stage (int b) {
   uint32_t save = rs;
   rs = 0x1234567u * (uint32_t) (b + 1) | 1;
   wcols = 112 + ACOLS + 8 * (b > 3);
   arena_x = 8 * (wcols - ACOLS);
   for (int r = 0; r < ROWS; r++) for (int c = 0; c < WMAX; c++) kind [r][c] = K_AIR;
   for (int r = 0; r < ROWS; r++) text_rows [r] = 0;
   stage_reset ();
   int c = 0, g = 24, A = wcols - ACOLS;
   for (int seg = 0; c < A; seg++) {
      int len = 5 + (int) (rnd () % 6);
      if (c + len > A - 6 || c < 12) { len = c < 12 ? 12 - c : A - c; }
      int last = c + len >= A;
      if (last) g = FLOOR;
      for (int i = c; i < c + len && i < A; i++)
         for (int r = g; r < ROWS; r++) kind [r][i] = K_GROUND;
      int crusher = b == 6 && !last && c > 12 && len >= 7 && (seg & 1);
      if (!last && !crusher && len >= 6 && rnd () % 3 == 0) {        // a floating ledge above
         int lr = g - 4 - (int) (rnd () % 2), lc = c + 1 + (int) (rnd () % 2);
         int lw = 3 + (int) (rnd () % 2);                            // clear of the segment's end:
         for (int i = lc; i < lc + lw && i < c + len - 2; i++) if (lr > 4) kind [lr][i] = K_BRICK;   // a step up
      }
      if (!last && c > 12) {                                         // gimmicks inside a segment
         if ((b == 1 || (b == 6 && !(seg & 1))) && len >= 6) {       // a conveyor, this way or that
            int dir = (seg & 2) ? 1 : -1;
            for (int i = c + 1; i < c + len - 1; i++) { kind [g][i] = K_BELT; belt_dir [i] = (int8_t) dir; }
         }
         if (b == 5 && len >= 7) { int h = c + len / 2 - 1; add_gm (GM_HOT, h, h + 2, g, (seg * 67) % HOT_T); }
         if (crusher) add_spawn (MK_CRUSH, 8 * (c + len / 2) - 8, 8 * g - 56);
      }
      if (!last && c > 14 && rnd () % 2 == 0) {                      // an enemy on this segment
         int k = stage_foes [b][rnd () % 3];
         add_spawn (k, 8 * (c + len / 2) + (crusher ? 24 : 0), 8 * g - (k == MK_FLY ? 34 : 16));
      }
      c += len;
      int w = 0;                                                     // a feature after the segment
      if (!last && (seg & 1) && c > 14 && c + 22 < A)
         switch (b) {
         case 0: w = 6; add_gm (GM_ALLOC, c, c + 5, g, (c * 37) % ALLOC_T); for (int i = c; i < c + 6; i++) kind [g][i] = K_GONE; break;
         case 2: w = 3; for (int i = c; i < c + 3; i++) for (int r = g; r < ROWS; r++) kind [r][i] = K_NULL; break;
         case 3: w = 5; add_gm (GM_CLOCK, c, c + 4, g, 0); for (int i = c; i < c + 5; i++) kind [g][i] = K_BRICK; break;
         case 4: w = 4; add_gm (GM_CRUMBLE, c, c + 3, g, 0); for (int i = c; i < c + 4; i++) kind [g][i] = K_MARKED; break;
         }
      c += w;
      if (w) continue;                                               // the floor goes on at g
      if (c < A - 10 && c > 14 && rnd () % 4 == 0) c += 2 + (int) (rnd () % 2);   // a gap
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
   clock_stop = 0;
}
static void owned_update (void) {      // the attract demo owns every tactic; a player, what they won
   pl_owned = demo ? (1 << NWEAPON) - 1 : 1 | (defeated << 1);
#ifdef PROOF_TEST
   if (test_weapon >= 0) pl_owned |= 1 << test_weapon;
#endif
   if (!(pl_owned & (1 << pl_weapon))) pl_weapon = W_LEMMA;
}
static void freeze_start (int n) { clock_stop = n; pal_set (1, 0x6A7080); }   // TICK: a stopped, grey sky
static void freeze_end (void) { clock_stop = 0; pal_set (1, bosses [cur_boss].sky); }
static void start_stage (int b) {
   cur_boss = b;
   clear_objects ();
   build_stage (b);
   pl_x = spawn_x = 24; pl_y = spawn_y = 8 * 24 - 16;
   pl_fx = pl_x << 4; pl_fy = pl_y << 4; pl_vy = 0; pl_lives = 5; pl_dead = 0; pl_hurt = 0; pl_face = 0; pl_certs = 0;
   pl_prev = -1;                         // a button held from the title is not a press
   for (int w = 0; w < NWEAPON; w++) pl_energy [w] = W_ENERGY;
   owned_update ();
   player_bump_up ();
   cam = 0;
   g_state = G_PLAY; g_timer = 0;
   psnd_tune (7);
}
static void title_screen (void) {
   clear_objects ();
   wcols = 40; arena_x = 0;
   stage_reset ();
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
   mode_palettes ();
   psnd_init ();
   hw_vdp_write (VDP_BACKDROP, 1);
   for (int i = 0; i < 128; i++) { spr_sh [i] = 0; spr_hw [i] = 0xFFFFFFFFu; }
   ctrl_sh = 3;
   hw_video_on ();
   demo = 1; demo_boss = 0; idle = 0; sel = 0;
#ifdef PROOF_TEST
   if (getenv ("PROOF_TEST")) {
      if (sscanf (getenv ("PROOF_TEST"), "%d,%d,%d", &test_boss, &test_move, &test_weapon) < 3) test_weapon = -1;
      if (test_boss < 0 || test_boss > 6) test_boss = 0;   // (unparsed: boss 0)
      if (test_weapon >= NWEAPON) test_weapon = -1;
      if (getenv ("PROOF_HP")) test_hp = atoi (getenv ("PROOF_HP"));       // start (and stay) at this HP
      test_clean = getenv ("PROOF_CLEAN") != NULL;          // test hits do not spoil a clean proof
      test_parry = getenv ("PROOF_PARRY") != NULL;          // parry every pink shot that comes near
      test_poke = getenv ("PROOF_POKE") != NULL;            // lemmas land on the boss's targets
      demo_boss = test_boss;
      start_stage (test_boss);
      if (test_weapon >= 0) pl_weapon = test_weapon;
      pl_x = spawn_x = arena_x - 16; pl_fx = pl_x << 4; pl_fy = pl_y << 4; player_bump_up ();
      return;
   }
   if (getenv ("PROOF_STAGE")) {         // the demo from the start of this stage, damage on
      demo_boss = atoi (getenv ("PROOF_STAGE")) % 7;
      start_stage (demo_boss);
      return;
   }
#endif
   start_stage (0);
}

// ---- the attract pilot: runs right, jumps gaps, walls and dangers, throws; in a stage it reads the
// gimmicks' timing (waits at a bridge until crossing it is safe, under a crusher until it is up),
// in a fight it cycles through the owned tactics
static int cell_safe (int c, int r, int dt0, int dt1) {   // solid and harmless from now + dt0 to + dt1
   if (c < 0 || c >= wcols || r < 0 || r >= ROWS) return 0;
   int i = gm_at (c, r);
   if (i < 0) { int k = kind [r][c]; return k_solid (k) && k != K_HOT; }
   const gimmick *q = &gm [i];
   if (q->type == GM_CRUMBLE) return q->a == 0 || (q->a < 3 && q->b + dt1 < 42);
   for (int d = dt0; ; d += 3) {
      if (d > dt1) d = dt1;
      if (!gm_cell_on (q, c, gclk + d) || gm_cell_hot (q, gclk + d)) return 0;
      if (d == dt1) break;
   }
   return 1;
}
static int reach (int px) { return px <= 0 ? 0 : px * 2 / 3; }   // frames to run px (1.5 a frame)
static int foe_ahead (int kind_mask, int range) {
   for (int i = 0; i < NMIN; i++) {
      int dx = (mins [i].x >> 4) - pl_x;
      if (mins [i].on && (kind_mask & (1 << mins [i].kind)) && dx > 0 && dx < range) return 1;
   }
   return 0;
}
static uint32_t pilot (void) {
   uint32_t b = 0;
   if (g_state == G_TITLE) return 0;
   int fx = pl_x + 8, feet = pl_y + 16;
   int want_w = W_LEMMA, fire_ok = 1;
   int danger = 0;
   for (int i = 0; i < NBUL; i++)
      if (bul [i].on && bul [i].harm) {
         int dx = (bul [i].x >> 4) - pl_x, dy = (bul [i].y >> 4) - pl_y;
         if (iabs (dx) < 36 && dy > -40 && dy < 16) danger = 1;
      }
   if (g_state == G_PLAY || g_state == G_ARENA) {
      b |= BTN_RIGHT;
      int r = (feet + 2) >> 3, ac = (fx + 12) >> 3;
      int wall = solid_px (fx + 10, pl_y + 8) || solid_px (fx + 10, pl_y + 14);
      int d0 = reach (8 * ac - pl_x - 12), d1 = reach (8 * ac + 8 - pl_x - 3) + 4;
      int hazard = 0;
      { int i = gm_at (ac, r); if (i >= 0 && gm [i].type == GM_HOT && !cell_safe (ac, r, d0, d1)) hazard = 1; }
      int gap = hazard, below = -1;                   // a step down is walked; a pit, null floor, hot
      for (int rr = r; rr < ROWS && rr <= r + 7 && below < 0; rr++)   // strip or vanishing cell is jumped
         if (k_solid (kind [rr][ac]) || kind [rr][ac] == K_NULL) below = rr;
      if (below < 0 || !cell_safe (ac, below, d0, d1)) gap = 1;
      if (!pl_ground && pl_vy > 0) {                  // falling: do not drift past safe ground into a pit
         int land = -1, here = -1;
         for (int rr = r; rr < ROWS && land < 0; rr++) if (k_solid (kind [rr][ac]) || kind [rr][ac] == K_NULL) land = rr;
         for (int rr = r; rr < ROWS && here < 0; rr++) if (k_solid (kind [rr][fx >> 3]) || kind [rr][fx >> 3] == K_NULL) here = rr;
         if ((land < 0 || !cell_safe (ac, land, 0, 8)) && here >= 0 && cell_safe (fx >> 3, here, 0, 8)) b &= ~BTN_RIGHT;
      }
      int bridge = 0, wait = 0;
      for (int i = 0; i < ngm; i++) {                 // a timed bridge ahead: cross it only if it holds
         const gimmick *q = &gm [i];
         if (q->type == GM_HOT || q->r != r) continue;
         int edge = 8 * q->c0 - (pl_x + 12);
         if (edge < -2 || edge > 20) continue;
         bridge = 1;
         for (int c = q->c0; c <= q->c1 && !wait; c++)
            if (!cell_safe (c, r, reach (8 * c - pl_x - 12), reach (8 * c + 8 - pl_x - 3) + 6)) wait = pl_ground && edge >= 0;
      }
      for (int i = 0; i < NMIN; i++) {                // a crusher: pass under it only while it stays up
         const minion *m = &mins [i];
         if (!m->on || m->kind != MK_CRUSH) continue;
         int mx = m->x >> 4, d = mx - (pl_x + 13);
         if (d < 0 || d > 24) continue;
         int need = reach (d + 16 + 10) + 6;
         int up = (m->a == 0 && m->c >= need) || (m->a == 3 && (m->y >> 4) + 13 < pl_y - 2);
         if (!up) wait = 1;
      }
      if (wait) b &= ~BTN_RIGHT;
      if (bridge) gap = 0;                           // never jump at a bridge: wait for it
      int foe = foe_ahead ((1 << MK_WALK) | (1 << MK_CHASE) | (1 << MK_HOP) | (1 << MK_TURRET), 40);
      if (((wall && !wait) || gap || (foe && (t & 15) < 3) || (danger && !bridge)) && (t & 1)) b |= BTN_UP;
      if (pl_vy < 0) b |= BTN_UP;
      if ((t & 7) == 0) b |= BTN_FIRE2;
      if (foe_ahead (1 << MK_FLY, 150) && pl_energy [W_PATH] >= w_cost [W_PATH]) want_w = W_PATH;   // homes on flyers
   } else if (g_state == G_FIGHT) {
      int want = arena_x + 64 + (int) ((t >> 6) % 3) * 40;
      if (boss.shield && pl_certs == 0)                   // a checker wants proofs: fetch a floor certificate
         for (int i = 0; i < NPROP; i++)
            if (props [i].on && props [i].tile == sfont ('#') && props [i].y > pl_y - 8) want = props [i].x;
      if (pl_x < want - 4) b |= BTN_RIGHT;
      if (pl_x > want + 4) b |= BTN_LEFT;
      if (danger && (t & 1)) b |= BTN_UP;
      if (pl_vy < 0 && danger) b |= BTN_UP;
      if (boss.x < pl_x && (t & 1)) b = (b & ~BTN_RIGHT) | BTN_LEFT;
      if ((t & 3) == 0) b |= BTN_FIRE2;
      want_w = (g_timer / 160 + cur_boss) % NWEAPON;  // each tactic in turn, 160 frames each
      if (pl_energy [want_w] < w_cost [want_w]) want_w = W_LEMMA;
   }
#ifdef PROOF_TEST
   if (test_weapon >= 0) want_w = test_weapon;
#endif
   if (!(pl_owned & (1 << want_w))) want_w = W_LEMMA;
   if (b & BTN_FIRE2)                                 // each tactic's own rhythm
      switch (pl_weapon) {
      case W_BRACES: {
         int old = 0;
         for (int i = 0; i < 3; i++) if (shots [i].on && shots [i].kind == W_BRACES && shots [i].a == 0 && shots [i].t > 100) old = 1;
         fire_ok = !braces_out () || old;
         break;
      }
      case W_TICK: fire_ok = !clock_stop && g_timer % 200 < 4; break;
      case W_CPS: fire_ok = !cps_out (); break;
      case W_CRUSH: fire_ok = pl_ground; break;
      }
   if (!fire_ok) b &= ~BTN_FIRE2;
   if (want_w != pl_weapon) { b &= ~BTN_FIRE2; if (t & 1) b |= BTN_DOWN; }   // DOWN, an edge a press
   return b;
}

// ---- drawing (into the shadow)
enum { S_HEART = 0, S_SCORE = 5, S_PLAYER = 11, S_SHOT = 12, S_BOSS = 15, S_BUL = 19, S_MIN = 43, S_PROP = 51, S_CURSOR = 61,
       S_ICON = 62, S_GAUGE = 63 };
static void draw_shot (int i) {
   const shot_t *s = &shots [i];
   if (!s->on || s->y > 210) { spr_off (S_SHOT + i); return; }     // low: the HUD line's slots
   int tile = T_ICON + 4 * (s->kind - 1), fl = s->vx < 0 ? VDP_SPR_HFLIP : 0;
   switch (s->kind) {
   case W_LEMMA: tile = T_SHOT; break;
   case W_BRACES: tile = T_BRACE; fl = s->hit ? VDP_SPR_HFLIP : 0; break;           // { and }
   case W_CPS: fl = ((s->t >> 2) & 1 ? VDP_SPR_HFLIP : 0) | ((s->t >> 3) & 1 ? VDP_SPR_VFLIP : 0); break;   // it spins
   case W_TRINITY: tile = T_PELLET; break;
   case W_PATH: fl = 0; break;
   }
   spr (S_SHOT + i, s->x - cam, s->y, tile, s->proved ? B_BUL2 : B_SHOT, VDP_SPR_ON | fl);
}
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
   for (int i = 0; i < 3; i++) draw_shot (i);
   if (g_state != G_TITLE) {                          // the tactic and its energy (HUD: 13 sprites)
      spr (S_ICON, 72, 226, pl_weapon ? T_ICON + 4 * (pl_weapon - 1) : T_SHOT, B_SHOT, VDP_SPR_ON);
      if (pl_weapon) spr (S_GAUGE, 88, 226, T_GAUGE + 4 * ((pl_energy [pl_weapon] + 3) / 4), B_PROP, VDP_SPR_ON);
      else spr_off (S_GAUGE);
   } else { spr_off (S_ICON); spr_off (S_GAUGE); }
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
   for (int i = 0; i < NMIN; i++) {
      const minion *m = &mins [i];
      int x = m->x >> 4, y = m->y >> 4;
      if (!m->on || y > 210) { spr_off (S_MIN + i); continue; }       // low: in a pit, the HUD line
      int tile = m->tile, fl = m->vx > 0 ? VDP_SPR_HFLIP : 0;
      if (tile == T_ENEMY || tile == T_FLYER) tile += ((m->t >> 3) & 1) * 4;
      if (m->kind == MK_HOP && m->vy == 0 && m->c > 40) tile += 4;      // crouched, about to jump
      if (m->kind == MK_TURRET || m->kind == MK_CRUSH) fl = m->kind == MK_TURRET && pl_x > x ? VDP_SPR_HFLIP : 0;
      spr (S_MIN + i, x - cam, y, tile, m->bank, VDP_SPR_ON | fl);
   }
   for (int i = 0; i < NPROP; i++)
      if (props [i].on) spr (S_PROP + i, props [i].x - cam, props [i].y, props [i].tile, props [i].bank, VDP_SPR_ON | props [i].flags);
      else spr_off (S_PROP + i);
   if (g_state == G_TITLE) spr (S_CURSOR, 32, 8 * (8 + 2 * sel) - 4, T_CURSOR, B_TEXT, VDP_SPR_ON);
   else spr_off (S_CURSOR);
   scroll_sh = (uint32_t) (cam & 511);
}

// a stage's own frame: its gimmicks and enemies, belts and hot floor (in a fight the boss does
// these), and a checkpoint on plain ground away from them
static int feet_kind (void) {
   int r = (pl_y + 17) >> 3, c = (pl_x + 8) >> 3;
   return r >= 0 && r < ROWS && c >= 0 && c < wcols ? kind [r][c] : K_AIR;
}
static void stage_frame (void) {
   if (!clock_stop) gclk++;
   gimmicks_update ();
   if (g_state != G_PLAY) return;
   spawns_update (cam);
   int fk = feet_kind (), c = (pl_x + 8) >> 3;
   if (pl_ground && fk == K_BELT && c >= 0 && c < WMAX && belt_dir [c]) player_push (12 * belt_dir [c]);
   if (fk == K_HOT) player_hurt ();
   if (pl_ground && !pl_hurt) {                       // a checkpoint: a pit puts you back here
      int r = (pl_y + 16) >> 3, ok = r < ROWS;
      for (int cc = ((pl_x + 3) >> 3) - 2; ok && cc <= ((pl_x + 12) >> 3) + 2; cc++)
         ok = cc >= 0 && cc < wcols && kind [r][cc] == K_GROUND && gm_at (cc, r) < 0;
      for (int i = 0; ok && i < NMIN; i++) if (mins [i].on && iabs ((mins [i].x >> 4) - pl_x) < 48) ok = 0;
      if (ok) set_spawn (pl_x, pl_y);
   }
}

static void next_demo (void) { demo_boss = (demo_boss + 1) % 7; sel = demo_boss; title_screen (); }

int proof_frame (uint32_t buttons) {
   flush ();
   t++;
   if (buttons) { idle = 0; if (demo) { demo = 0; title_screen (); } }
   else if (idle < 1200) idle++;
   owned_update ();
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
      stage_frame ();
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
            boss.resume = 0; move_hit = 0; fight_rest = 0; fight_pinch = 0; fight_banner = 0; pl_parry = 0;
            boss.x = arena_x + 8 * 30; boss.y = 8 * FLOOR - 32;
            arena_text (0, bosses [cur_boss].name);
#ifdef PROOF_TEST
            if (test_boss >= 0 && cur_boss == test_boss) boss.attack = test_move;   // only the tested fight
            if (test_hp > 0) boss.hp = test_hp;
#endif
            g_state = G_FIGHT; g_timer = 0;
            psnd_tune (cur_boss);
         }
      }
      break;
   case G_FIGHT: {
      int x0 = pl_x, y0 = pl_y, air = !pl_ground, up = (buttons & BTN_UP) && !(pl_prev & BTN_UP);
      player_update (buttons);
      pl_moved = pl_x != x0 || pl_y != y0;                  // for the blue and orange bullets
      if (pl_parry) pl_parry--;
      if (up && air) pl_parry = 8;                           // UP newly pressed in the air
#ifdef PROOF_TEST
      if (test_parry)                                        // host only: parry every pink shot
         for (int i = 0; i < NBUL; i++)
            if (bul [i].on && bul [i].mode == M_PINK && iabs ((bul [i].x >> 4) - pl_x) < 14 && iabs ((bul [i].y >> 4) - pl_y) < 14) pl_parry = 1;
      if (test_poke && g_timer > 60 && g_timer % 50 == 25) boss_poke (g_timer / 50);
#endif
      if (g_timer > 60) {
         if (fight_rest) { if (--fight_rest == 0) arena_clear_text (7); }   // after a clean proof
         else if (!clock_stop) {                             // TICK stops the boss
            bosses [cur_boss].update ();
            if (boss.hp > 0 && boss.hp <= BOSS_HP / 2 && (g_timer & 3) == 0 && !fight_rest) bosses [cur_boss].update ();   // the pinch: 5 a 4 frames
         }
         if (!fight_pinch && boss.hp > 0 && boss.hp <= BOSS_HP / 2) { fight_pinch = 1; boss_banner (boss_pinch [cur_boss]); }
         if (fight_banner && --fight_banner == 0) arena_clear_text (4);
      }
      else if (g_timer == 2) arena_text (3, bosses [cur_boss].field);
      else if (g_timer == 60) arena_clear_text (3);
      else if (g_timer % 6 == 0) psnd_tink ();               // the bar fills
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
         if (clock_stop) freeze_end ();
         {                                            // the weapon get
            static char line [41];
            const char *a = "NEW TACTIC: ", *n = w_name [cur_boss + 1];
            int k = 0;
            while (*a && k < 40) line [k++] = *a++;
            while (*n && k < 40) line [k++] = *n++;
            line [k] = 0;
            arena_text (8, line); arena_text (10, w_says [cur_boss + 1]);
            if (!demo && !(defeated & (1 << cur_boss))) arena_text (12, "DOWN: CHANGE TACTIC");
            psnd_get ();
         }
         if (!demo) defeated |= 1 << cur_boss;
      }
      break;
   }
   case G_WIN:
      player_update (buttons & ~BTN_FIRE2);
      if (g_timer > 240) {
         if (demo) next_demo ();
         else if (defeated == 127) {
            g_state = G_END; g_timer = 0;
            arena_clear_text (10); arena_clear_text (12);
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
   if (clock_stop && --clock_stop == 0) freeze_end ();
#ifdef PROOF_TEST
   if (getenv ("PROOF_TRACE")) {                      // host only: where the pilot gets to
      static int last = -1;
      if (g_state != last) fprintf (stderr, "trace: frame %u boss %d state %d lives %d x %d\n", t, cur_boss, g_state, pl_lives, pl_x);
      last = g_state;
   }
   if (getenv ("PROOF_DBG")) {                        // PROOF_DBG=<from>,<to>: the player, frame by frame
      int f0 = 0, f1 = 0; sscanf (getenv ("PROOF_DBG"), "%d,%d", &f0, &f1);
      if ((int) t >= f0 && (int) t <= f1)
         fprintf (stderr, "dbg %u: x %d y %d vy %d ground %d btn %x w %d feet %d\n", t, pl_x, pl_y, pl_vy, pl_ground, (unsigned) buttons, pl_weapon, feet_kind ());
   }
#endif
   owned_update ();                                   // a win's tactic is owned from its frame on
   if (g_state != G_TITLE) stream ();
   draw ();
   return score;
}

// ================================================================ the specification's view
// (proof_spec.h): what notes/proof-obligation-spec.md's clauses are about.  Host builds check
// them every frame (host.c, HOST_SPEC=1); the board build does not call this.
#include "proof_spec.h"
void proof_observe (spec_state *s) {
   static const int moves [7] = { 4, 5, 4, 5, 4, 5, 5 };   // next_move (n): n regular moves and the last lemma, n
   extern int px_learned; int px_chosen (int v);
   s->state = g_state; s->demo = demo; s->cur_boss = cur_boss; s->defeated = defeated;
   s->lives = pl_lives; s->dead = pl_dead; s->hurt = pl_hurt; s->certs = pl_certs;
   s->x = pl_x; s->y = pl_y; s->cam = cam; s->arena_x = arena_x; s->wcols = wcols;
   s->score = score; s->t = t;
   s->boss_on = boss.on; s->hp = boss.hp; s->flash = boss.flash; s->stun = boss.stun;
   s->shield = boss.shield; s->attack = boss.attack; s->nmoves = moves [cur_boss];
   s->nshots = s->nbul = s->nprops = 0;
   for (int i = 0; i < 3; i++) s->nshots += shots [i].on != 0;
   for (int i = 0; i < NBUL; i++) s->nbul += bul [i].on != 0;
   for (int i = 0; i < NPROP; i++) s->nprops += props [i].on != 0;
   s->w_pal = flush_pal; s->w_map = flush_map; s->w_spr = flush_spr; s->w_reg = flush_reg;
   s->vdp_writes = -1;                                 // the observer (host.c) may know it
   s->px_agree = !(px_chosen (1) && px_chosen (2)) && (px_learned == 0 || px_chosen (px_learned));
   s->hooked = 0;
   s->weapon = pl_weapon; s->owned = pl_owned; s->granted = 0;
#ifdef PROOF_TEST
   if (test_weapon >= 0) s->granted = 1 << test_weapon;  // the host test hook's extra tactic
   s->hooked = test_boss >= 0 || test_hp > 0;          // the hook forces moves and pins HP
#endif
   for (int w = 0; w < SP_NWEAPON; w++) s->energy [w] = pl_energy [w];
   s->got_hearts = got_hearts; s->got_energy = got_energy;
}
