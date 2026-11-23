// sw/game2d/lantern.c: Lantern Drift, the game2d demo title (an original game).
// A lantern boat travels up a river at night.  Steer with the D-pad, collect fireflies (10 points
// each), avoid the drifting logs (three lanterns); FIRE2 starts a new game after the last one
// goes out.  With no input for 10 s the boat steers itself (attract mode; the game starts in it).
// Everything on screen is generated here: tiles, sprites, palette.  The machine is reached only
// through hw.h, so host.c can run the same frames against the VDP reference model.
#include "sound.h"
#include "lantern.h"
#include "hw.h"
#include "../vdp/vdp.h"

// ---------------- deterministic random numbers (xorshift32)
static uint32_t rs = 0x2545F491u;
static uint32_t rnd (void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }

// ---------------- palette banks (index 16 * bank + n; n = 0 is transparent)
enum { B_WATER = 1, B_GRASS = 2, B_SHORE = 3, B_BOAT = 4, B_LOG = 5, B_FLY = 6, B_TEXT = 7, B_HEART = 8 };
static void bank (int b, const uint32_t *c, int n) { for (int i = 0; i < n; i++) hw_palette (16 * b + 1 + i, c [i]); }

// ---------------- tiles
enum { T_WATER = 1, T_GRASS = 5, T_SHORE_L = 9, T_SHORE_R = 10,
       T_BOAT = 16, T_LOG = 20, T_FLY = 24, T_HEART = 28, T_DIGIT = 32 };
static uint32_t tile [8];
static void tile_put (int t) {
   for (int r = 0; r < 8; r++) hw_vdp_write (VDP_PATTERNS + 4 * (8 * t + r), tile [r]);
}
static void px (int r, int c, int n) { tile [r] = (tile [r] & ~(15u << (4 * c))) | ((uint32_t) n << (4 * c)); }
static void tile_fill (int n) { for (int r = 0; r < 8; r++) tile [r] = 0x11111111u * (uint32_t) n; }

// a 16x16 sprite (tiles t .. t + 3: top left, top right, bottom left, bottom right)
static uint8_t grid [16][16];
static void grid_put (int t) {
   for (int q = 0; q < 4; q++) {
      for (int r = 0; r < 8; r++) {
         tile [r] = 0;
         for (int c = 0; c < 8; c++) px (r, c, grid [r + 8 * (q >> 1)][c + 8 * (q & 1)]);
      }
      tile_put (t + q);
   }
}
// from 16 strings of 16 hex digits, '.' = 0
static void sprite_put (int t, const char *const rows [16]) {
   for (int r = 0; r < 16; r++)
      for (int c = 0; c < 16; c++) {
         char ch = rows [r][c];
         grid [r][c] = (uint8_t) (ch >= '1' && ch <= '9' ? ch - '0' : 0);
      }
   grid_put (t);
}

static const char *const boat_img [16] = {
   ".......33.......", "......3443......", "......3443......", ".......33.......",
   ".......66.......", "......6556......", ".....655556.....", ".....655556.....",
   "....111111111...", "...12222222221..", "...12222222221..", "....122222221...",
   ".....1111111....", "......7..7......", ".....7....7.....", "................" };
static const char *const log_img [16] = {
   "................", "................", "...1111111111...", "..122223322221..",
   ".12233222233221.", ".12222222222221.", "1244222222224421", "1243422222243421",
   "1244222222224421", ".12222223322221.", ".12233222222221.", "..122222222221..",
   "...1111111111...", "................", "................", "................" };
static const char *const fly_img [16] = {
   "................", "................", "................", "......1111......",
   ".....122221.....", "....12333321....", "....13444431....", "...1234554321...",
   "...1234554321...", "....13444431....", "....12333321....", ".....122221.....",
   "......1111......", "................", "................", "................" };
static const char *const heart_img [16] = {
   "................", "..111....111....", ".12221..12221...", "12222211222221..",
   "12222222222221..", "12222222222221..", ".122222222221...", "..1222222221....",
   "...12222221.....", "....122221......", ".....1221.......", "......11........",
   "................", "................", "................", "................" };

// 3x5 digits (bit 14 = top left), drawn 2x as 6x10 at (1, 3) of a sprite
static const uint16_t font [10] = { 0x7B6F, 0x2C97, 0x73E7, 0x73CF, 0x5BC9, 0x79CF, 0x79EF, 0x7249, 0x7BEF, 0x7BCF };

static void make_graphics (void) {
   static const uint32_t water [] = { 0x081830, 0x0C2448, 0x14385C, 0x2C5C88 };
   static const uint32_t grass [] = { 0x082008, 0x103818, 0x1C5020, 0x40A040, 0xC8C040 };
   static const uint32_t shore [] = { 0x103818, 0x8C7848, 0x081830 };
   static const uint32_t boat  [] = { 0x3C2010, 0x8C5A2C, 0xFFE080, 0xFFFFC0, 0xF0A020, 0xFF8000, 0x202020 };
   static const uint32_t logc  [] = { 0x281408, 0x6C4020, 0x8C6038, 0xB08850 };
   static const uint32_t fly   [] = { 0x204010, 0x50A020, 0x90E040, 0xD0FF80, 0xFFFFE0 };
   static const uint32_t text  [] = { 0xFFFFFF };
   static const uint32_t heart [] = { 0x400010, 0xE02040 };
   hw_palette (0, 0x000000);
   bank (B_WATER, water, 4); bank (B_GRASS, grass, 5); bank (B_SHORE, shore, 3);
   bank (B_BOAT, boat, 7); bank (B_LOG, logc, 4); bank (B_FLY, fly, 5);
   bank (B_TEXT, text, 1); bank (B_HEART, heart, 2);
   for (int v = 0; v < 4; v++) {                   // water: deep blue with ripples
      tile_fill (1);
      for (int k = 0; k < 2 + v; k++) {
         uint32_t r = rnd ();
         int row = r & 7, col = (r >> 3) & 7, len = 2 + ((r >> 6) & 1);
         for (int i = 0; i < len; i++) px (row, (col + i) & 7, 2 + ((r >> 8) & 1));
         if (v == 3) px ((row + 1) & 7, col, 4);
      }
      tile_put (T_WATER + v);
   }
   for (int v = 0; v < 4; v++) {                   // grass, one with flowers
      tile_fill (2);
      for (int k = 0; k < 10; k++) { uint32_t r = rnd (); px (r & 7, (r >> 3) & 7, 1 + (int) ((r >> 6) % 3)); }
      if (v == 3) { px (2, 3, 5); px (5, 6, 5); }
      tile_put (T_GRASS + v);
   }
   for (int side = 0; side < 2; side++) {          // shores: grass, sand, water
      for (int r = 0; r < 8; r++)
         for (int c = 0; c < 8; c++) {
            int d = side ? 7 - c : c;              // distance from the grass side
            px (r, c, d < 3 ? 1 : (d < 5 ? 2 : 3));
         }
      tile_put (side ? T_SHORE_R : T_SHORE_L);
   }
   sprite_put (T_BOAT, boat_img);
   sprite_put (T_LOG, log_img);
   sprite_put (T_FLY, fly_img);
   sprite_put (T_HEART, heart_img);
   for (int d = 0; d < 10; d++) {
      for (int r = 0; r < 16; r++) for (int c = 0; c < 16; c++) grid [r][c] = 0;
      for (int y = 0; y < 5; y++)
         for (int x = 0; x < 3; x++)
            if (font [d] & (1u << (14 - (3 * y + x))))
               for (int k = 0; k < 4; k++) grid [3 + 2 * y + (k >> 1)][1 + 2 * x + (k & 1)] = 1;
      grid_put (T_DIGIT + 4 * d);
   }
}

// ---------------- the river map: grass, shore, water (the whole 64 x 32 plane)
#define RIVER_L 6     // first water column on screen (x = 48)
#define RIVER_R 33    // last water column (x = 264..271)
static void make_map (void) {
   for (int row = 0; row < 32; row++)
      for (int col = 0; col < 64; col += 2) {
         uint32_t w = 0;
         for (int h = 0; h < 2; h++) {
            int c = col + h;
            uint32_t r = rnd ();
            uint16_t e;
            if (c == RIVER_L - 1)      e = vdp_map_entry (T_SHORE_L, B_SHORE, 0, 0);
            else if (c == RIVER_R + 1) e = vdp_map_entry (T_SHORE_R, B_SHORE, 0, 0);
            else if (c >= RIVER_L && c <= RIVER_R)
               e = vdp_map_entry (T_WATER + ((r & 15) == 0 ? 3 : (int) (r % 3)), B_WATER, (r >> 8) & 1, 0);
            else
               e = vdp_map_entry (T_GRASS + ((r & 7) == 0 ? 3 : (int) (r % 3)), B_GRASS, (r >> 8) & 1, (r >> 9) & 1);
            w |= (uint32_t) e << (16 * h);
         }
         hw_vdp_write (VDP_MAP + 2 * (64 * row + col), w);
      }
}

// ---------------- game state
#define N_LOG 12
#define N_FLY 6
enum { S_SCORE = 0, S_HEART = 6, S_BOAT = 9, S_LOG = 10, S_FLY = 22 };
typedef struct { int x, y, vy, on; } obj;
static obj logs [N_LOG], flies [N_FLY];
static int bx, by;                 // boat position (screen pixels)
static int score, lives, hurt, over, scroll_y, idle;
static unsigned t;                 // frames since start: unsigned, so it wraps (after 2^32) defined
#define SCORE_MAX 999990           // the six digits shown; the score stops there (no overflow)

static void spr (int i, int x, int y, int tile_, int bank_, int flags) {
   hw_vdp_write (VDP_SPRITES + 8 * i, (uint32_t) (x & 511) | ((uint32_t) (y & 511) << 16));
   hw_vdp_write (VDP_SPRITES + 8 * i + 4, (uint32_t) (tile_ & 1023) | ((uint32_t) (bank_ & 15) << 10)
                                          | ((uint32_t) flags << 14));
}

static void new_game (void) {
   bx = 152; by = 200; score = 0; lives = 3; hurt = 0; over = 0;
   for (int i = 0; i < N_LOG; i++) logs [i].on = 0;
   for (int i = 0; i < N_FLY; i++) flies [i].on = 0;
}

void lantern_init (void) {
   make_graphics ();
   make_map ();
   sound_init ();
   hw_vdp_write (VDP_BACKDROP, 0);
   hw_vdp_write (VDP_BG_SCROLL, 0);
   for (int i = 0; i < 64; i++) spr (i, 0, 0, 0, 0, 0);
   hw_vdp_write (VDP_CTRL, 3);
   hw_video_on ();
   new_game ();
   idle = 600;
}

static int hit (int ax, int ay, int cx, int cy, int m) {
   return ax + m < cx + 16 - m && cx + m < ax + 16 - m && ay + m < cy + 16 - m && cy + m < ay + 16 - m;
}

// the attract-mode pilot: toward the nearest firefly ahead, away from logs close ahead
static uint32_t pilot (void) {
   int tx = bx, best = 1 << 30;
   for (int i = 0; i < N_FLY; i++)
      if (flies [i].on && flies [i].y < by) {
         int d = (by - flies [i].y) + (flies [i].x > bx ? flies [i].x - bx : bx - flies [i].x);
         if (d < best) { best = d; tx = flies [i].x; }
      }
   for (int i = 0; i < N_LOG; i++)
      if (logs [i].on && logs [i].y > by - 64 && logs [i].y < by + 8) {
         int dx = logs [i].x - bx;
         if (dx > -20 && dx < 20) tx = dx > 0 ? bx - 24 : bx + 24;
      }
   uint32_t b = 0;
   if (tx < bx - 1) b |= BTN_LEFT;
   if (tx > bx + 1) b |= BTN_RIGHT;
   if (over && (t & 63) == 0) b |= BTN_FIRE2;
   return b;
}

static void draw_number (int sprite, int value, int digits, int x, int y) {
   for (int i = digits - 1; i >= 0; i--) {
      spr (sprite + i, x + 8 * i, y, T_DIGIT + 4 * (value % 10), B_TEXT, VDP_SPR_ON);
      value /= 10;
   }
}

static int spawn_x (void) { return 8 * RIVER_L + (int) (rnd () % (8 * (RIVER_R - RIVER_L) - 8)); }

int lantern_frame (uint32_t buttons) {
   t++;
   if (buttons) idle = 0; else if (idle < 600) idle++;
   if (idle >= 600) buttons = pilot ();
   sound_frame ();

   if (over) {
      if (buttons & BTN_FIRE2) new_game ();
   } else {
      if (buttons & BTN_LEFT)  bx -= 2;
      if (buttons & BTN_RIGHT) bx += 2;
      if (buttons & BTN_UP)    by -= 2;
      if (buttons & BTN_DOWN)  by += 2;
      if (bx < 8 * RIVER_L) bx = 8 * RIVER_L;
      if (bx > 8 * RIVER_R - 8) bx = 8 * RIVER_R - 8;
      if (by < 120) by = 120;
      if (by > 220) by = 220;
      int rate = 40 - score / 50; if (rate < 12) rate = 12;     // more logs as the score grows
      if (t % rate == 0)
         for (int i = 0; i < N_LOG; i++) if (!logs [i].on) {
            logs [i].on = 1; logs [i].x = spawn_x (); logs [i].y = -16;
            logs [i].vy = 1 + (int) (rnd () % 2) + (score > 300); break;
         }
      if (t % 30 == 15)
         for (int i = 0; i < N_FLY; i++) if (!flies [i].on) {
            flies [i].on = 1; flies [i].x = spawn_x (); flies [i].y = -16; flies [i].vy = 1; break;
         }
      for (int i = 0; i < N_LOG; i++) if (logs [i].on) {
         logs [i].y += logs [i].vy;
         if (logs [i].y > 240) logs [i].on = 0;
         else if (!hurt && hit (bx, by, logs [i].x, logs [i].y, 3)) {
            lives--; hurt = 90; sound_crash ();
            if (lives == 0) over = 1;
         }
      }
      for (int i = 0; i < N_FLY; i++) if (flies [i].on) {
         flies [i].y += flies [i].vy;
         flies [i].x += ((t + 8 * i) & 32) ? 1 : -1;
         if (flies [i].y > 240) flies [i].on = 0;
         else if (hit (bx, by, flies [i].x, flies [i].y, 2)) { flies [i].on = 0; if (score < SCORE_MAX) score += 10; sound_fly (); }
      }
      if (hurt) hurt--;
      scroll_y = (scroll_y - 1) & 255;
   }

   // ---- show it (all writes land in the vertical blank)
   hw_vdp_write (VDP_BG_SCROLL, (uint32_t) scroll_y << 16);
   draw_number (S_SCORE, score, 6, 8, 4);
   for (int i = 0; i < 3; i++)
      spr (S_HEART + i, 320 - 20 * (i + 1), 4, T_HEART, B_HEART, i < lives ? VDP_SPR_ON : 0);
   int blink = (hurt && (t & 4)) || (over && (t & 16));
   spr (S_BOAT, bx, by, T_BOAT, B_BOAT, blink ? 0 : VDP_SPR_ON);
   for (int i = 0; i < N_LOG; i++)
      spr (S_LOG + i, logs [i].x, logs [i].y, T_LOG, B_LOG, logs [i].on ? VDP_SPR_ON : 0);
   for (int i = 0; i < N_FLY; i++)
      spr (S_FLY + i, flies [i].x, flies [i].y, T_FLY, B_FLY, flies [i].on ? VDP_SPR_ON : 0);
   return score;
}
