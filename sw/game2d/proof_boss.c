// sw/game2d/proof_boss.c: Proof Obligation's seven bosses.  Each attack is one of the boss's
// ideas working as a game mechanic (notes/proof-obligation.md has the table and the sources):
//   McCarthy  (CONS CAR CDR) lists that split as they land; mark and sweep (unmarked ground is
//             collected); nested parentheses that close in; AMB, the angelic choice of where to be
//   Dijkstra  shortest-path seekers (a real breadth-first search over the arena, a slice each
//             frame); the semaphore (P takes the gate, the player's V releases it); GOTO arrows
//             that jump to a label
//   Hoare     quicksort (Hoare partition) run on the arena's pillars, step by step, leaving stairs; the triple
//             {P} C {Q} (lemmas thrown from inside P are proved to reach Q); null references (the
//             floor that is not there)
//   Lamport   logical clocks (the smallest timestamp fires, then takes max + 1; a hit sends it a
//             message); the bakery (minions served in ticket order, one in the critical section);
//             Paxos (acceptors light toward a quorum; deny two and the ballot fails)
//   Appel     compiling with continuations (every throw returns along its own path to its caller);
//             foundational proof-carrying code (only lemmas carrying a certificate get through);
//             simple generational GC (most die young, survivors are promoted)
//   Harper    unityped values (all look alike until the run-time tag check); computational
//             trinitarianism (three orbs that are one: hit one, all go); parallelism is not
//             concurrency (the boss forks, each copy does the same share at once, they join)
//   Chlipala  crush (a slam that clears the floor); Bedrock (separation logic: an attack writes
//             only its footprint, the frame rule keeps the rest); Ur/Web (links that cannot break)
#include "proof_int.h"

static const int cos64 [64] = {
   64, 64, 63, 61, 59, 56, 53, 49, 45, 41, 36, 30, 24, 19, 12, 6, 0, -6, -12, -19, -24, -30, -36,
   -41, -45, -49, -53, -56, -59, -61, -63, -64, -64, -64, -63, -61, -59, -56, -53, -49, -45, -41,
   -36, -30, -24, -19, -12, -6, 0, 6, 12, 19, 24, 30, 36, 41, 45, 49, 53, 56, 59, 61, 63, 64 };
static int cosv (int a) { return cos64 [a & 63]; }
static int sinv (int a) { return cos64 [(a - 16) & 63]; }

static int AC (void) { return arena_x >> 3; }               // the arena's first world column
static int AX (int c) { return arena_x + 8 * c; }
static int AY (int r) { return 8 * r; }
static void abrick (int c0, int c1, int r, int k) { for (int c = c0; c <= c1; c++) tile_set (AC () + c, r, k); }
static int pcx (void) { return pl_x + 8; }
static int pcy (void) { return pl_y + 8; }
static int bcx (void) { return boss.x + 16; }
static int bcy (void) { return boss.y + 16; }

// a velocity of about |speed| (SUB units a frame) from (x0, y0) toward (x1, y1), in pixels
static void toward (int x0, int y0, int x1, int y1, int speed, int *vx, int *vy) {
   int dx = x1 - x0, dy = y1 - y0, ax = iabs (dx), ay = iabs (dy);
   int d = (ax > ay ? ax + ay / 2 : ay + ax / 2);
   if (d == 0) { *vx = 0; *vy = speed; return; }
   *vx = dx * speed / d; *vy = dy * speed / d;
}
static int fire_at_player (int x, int y, int speed, int tile, int bnk) {     // from centre (x, y)
   int vx, vy;
   toward (x, y, pcx (), pcy (), speed, &vx, &vy);
   return bullet_new (0, (x - 8) << 4, (y - 8) << 4, vx, vy, tile, bnk);
}
static void fx (int x, int y, int tile) {                                    // a harmless flash
   int k = bullet_new (2, (x - 8) << 4, (y - 8) << 4, 0, 0, tile, B_BUL2);
   if (k >= 0) bul [k].harm = 0;
}
static int shot_near (int x, int y, int bx, int by, int r) { return iabs (x - bx) < r && iabs (y - by) < r; }
static int feet_kind (void) {
   int r = (pl_y + 17) >> 3, c = (pl_x + 8) >> 3;
   return r >= 0 && r < ROWS && c >= 0 && c < wcols ? kind [r][c] : K_AIR;
}

// ---- the move scheduler: boss.attack is the move, boss.timer frames into it
static void cue (const char *s) { boss_cue (s); boss.frame = 1; }
static void next_move (int n) {
   boss.attack = (boss.attack + 1) % n; boss.timer = -1; boss.phase = 0; boss.frame = 0;
   arena_clear_text (3); arena_clear_text (5); arena_clear_text (7);
   for (int i = 0; i < NPROP; i++) props [i].on = 0;
}
static void tick (void) {
   boss.timer++;
   if (boss.timer == 50) boss.frame = 0;
   if (boss.stun) boss.stun--;
}

// ================================================================ John McCarthy
// spots: 0 the left platform, 1 the middle platform, 2 the right floor
static const int mc_spot [3][2] = { { 7, 21 }, { 18, 16 }, { 33, FLOOR } };
static const int mc_obj [7][3] = {     // the heap: floor segments and platforms (col0, col1, row)
   { 1, 9, FLOOR }, { 10, 19, FLOOR }, { 20, 29, FLOOR }, { 30, 38, FLOOR },
   { 6, 11, 21 }, { 16, 23, 16 }, { 28, 33, 21 } };
static void mc_arena (void) { abrick (6, 11, 21, K_BRICK); abrick (16, 23, 16, K_BRICK); abrick (28, 33, 21, K_BRICK); }
static void mc_obj_set (int o, int k) {
   int rows = mc_obj [o][2] == FLOOR ? ROWS - FLOOR : 1;
   for (int r = 0; r < rows; r++) abrick (mc_obj [o][0], mc_obj [o][1], mc_obj [o][2] + r, k);
}
static int mc_obj_kind (int o) { return mc_obj [o][2] == FLOOR ? K_GROUND : K_BRICK; }
static void mc_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.a [6] = 2; boss.x = AX (mc_spot [2][0]); boss.y = AY (mc_spot [2][1]) - 32; }
   switch (boss.attack) {
   case 0:                                                    // (cons car cdr)
      if (tt == 0) cue ("(CONS CAR CDR)");
      if (tt == 30 || tt == 80 || tt == 130) {
         int vx = (pcx () - bcx ()) * 16 / 50;
         int k = bullet_new (10, (bcx () - 8) << 4, (boss.y) << 4, vx, -72, T_CONS, B_BUL);
         if (k >= 0) bul [k].a = 3;
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 10) continue;
         b->vy += 4; b->x += b->vx; b->y += b->vy;
         if (b->vy > 0 && solid_px ((b->x >> 4) + 6, (b->y >> 4) + 10)) {
            int k = bullet_new (11, b->x, b->y - (6 << 4), 0, 0, T_ORB, B_BUL2);   // car: an atom stays
            if (k >= 0) bul [k].a = 50;
            if (b->a-- <= 0) b->on = 0;                                         // nil: the list ends
            else { b->vy = -60; b->y -= 4 << 4; }                               // cdr: the rest goes on
         }
      }
      for (int i = 0; i < NBUL; i++) if (bul [i].on && bul [i].kind == 11 && --bul [i].a <= 0) bul [i].on = 0;
      if (tt > 260) next_move (6);
      break;
   case 2: {                                                  // mark and sweep
      if (tt == 0) {
         cue ("MARK AND SWEEP");
         int root = boss.a [6] == 0 ? 4 : boss.a [6] == 1 ? 5 : 3;    // what the boss stands on
         int m = 1 << root, fl = 0;
         for (int o = 0; o < 4; o++) if (m & (1 << o)) fl++;
         while (fl < 2) { int o = (int) (rnd () % 4); if (!(m & (1 << o))) { m |= 1 << o; fl++; } }
         for (int o = 4; o < 7; o++) if (rnd () & 1) m |= 1 << o;
         boss.a [0] = m;
         arena_text (5, "MARKING WHAT THE ROOTS REACH");
      }
      int m = boss.a [0];
      if (tt < 100 && (tt & 7) == 0)
         for (int o = 0; o < 7; o++) mc_obj_set (o, (m & (1 << o)) ? K_MARKED : ((tt & 8) ? K_DOOMED : mc_obj_kind (o)));
      if (tt == 100) {
         arena_text (5, "SWEEP: UNREACHABLE GROUND IS FREED");
         for (int o = 0; o < 7; o++) mc_obj_set (o, (m & (1 << o)) ? mc_obj_kind (o) : K_GONE);
         for (int o = 0; o < 4; o++) if (m & (1 << o)) { set_spawn (AX ((mc_obj [o][0] + mc_obj [o][1]) / 2), AY (FLOOR) - 16); break; }
      }
      if (tt > 100 && tt < 260 && tt % 40 == 0) fire_at_player (bcx (), bcy (), 40, T_ORB, B_BUL);
      if (tt == 280) {
         for (int o = 0; o < 7; o++) mc_obj_set (o, mc_obj_kind (o));
         set_spawn (AX (3), AY (FLOOR) - 16);
         player_bump_up ();
      }
      if (tt > 300) next_move (6);
      break;
   }
   case 4:                                                    // nested parentheses close in
      if (tt == 0) cue ("((NESTED (PARENTHESES)))");
      if (tt == 20 || tt == 50 || tt == 110 || tt == 140) {
         int y = pl_y + ((tt == 50 || tt == 140) ? -14 : 0);
         int l = bullet_new (12, AX (1) << 4, y << 4, 32, 0, T_PAREN_L, B_BUL);
         int r = bullet_new (12, AX (37) << 4, y << 4, -32, 0, T_PAREN_R, B_BUL);
         if (l >= 0) bul [l].a = pcx () - 12;
         if (r >= 0) bul [r].a = pcx () - 4;
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 12) continue;
         b->x += b->vx;
         if ((b->vx > 0 && (b->x >> 4) >= b->a) || (b->vx < 0 && (b->x >> 4) <= b->a)) { b->on = 0; fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_SPARK); }
      }
      if (tt > 220) next_move (6);
      break;
   default: {                                                 // amb: two candidates, the angel chooses
      if (tt == 0) {
         int s = boss.a [6], c1 = (s + 1) % 3, c2 = (s + 2) % 3;
         boss.a [1] = c1; boss.a [2] = c2;
         for (int k = 0; k < 2; k++) {
            int sp = k ? c2 : c1;
            props [k].on = 1; props [k].x = AX (mc_spot [sp][0]) + 8; props [k].y = AY (mc_spot [sp][1]) - 24;
            props [k].tile = T_GHOST; props [k].bank = B_BOSS; props [k].flags = 0;
         }
         arena_text (5, "(AMB A B)");
      }
      if (tt > 0 && tt < 40) props [0].on = props [1].on = (tt & 4) != 0;
      if (tt == 40) {
         int c1 = boss.a [1], c2 = boss.a [2];
         int d1 = iabs (AX (mc_spot [c1][0]) - pl_x), d2 = iabs (AX (mc_spot [c2][0]) - pl_x);
         int s = d1 >= d2 ? c1 : c2;                          // angelic: the choice that succeeds
         boss.a [6] = s; boss.x = AX (mc_spot [s][0]); boss.y = AY (mc_spot [s][1]) - 32;
         fx (bcx (), bcy (), T_PUFF);
      }
      if (tt > 60) next_move (6);
      break;
   } }
   tick ();
}
static int all_hit (int x, int y) { (void) x; (void) y; return 1; }
static int no_other (int x, int y) { (void) x; (void) y; return 0; }

// ================================================================ Edsger Dijkstra
static uint8_t dist_w [ROWS][ACOLS], dist_p [ROWS][ACOLS];
static uint16_t bq [ROWS * ACOLS];
static int bq_h, bq_t, bfs_on;
static int dj_free (int c, int r) { return c >= 0 && c < ACOLS && r >= 0 && r < ROWS && !k_solid (kind [r][AC () + c]); }
static void bfs_start (void) {
   for (int r = 0; r < ROWS; r++) for (int c = 0; c < ACOLS; c++) dist_w [r][c] = 255;
   int c = (pcx () - arena_x) >> 3, r = pcy () >> 3;
   if (c < 0) c = 0;
   if (c >= ACOLS) c = ACOLS - 1;
   if (r < 0) r = 0;
   if (r >= ROWS) r = ROWS - 1;
   bq_h = bq_t = 0; dist_w [r][c] = 0; bq [bq_t++] = (uint16_t) (r * ACOLS + c); bfs_on = 1;
}
static void bfs_slice (void) {                    // at most 150 cells a frame (bounded work)
   if (!bfs_on) bfs_start ();
   for (int n = 0; n < 150 && bq_h < bq_t; n++) {
      int v = bq [bq_h++], r = v / ACOLS, c = v % ACOLS, d = dist_w [r][c];
      static const int dr [4] = { -1, 1, 0, 0 }, dc [4] = { 0, 0, -1, 1 };
      for (int k = 0; k < 4; k++) {
         int nr = r + dr [k], nc = c + dc [k];
         if (dj_free (nc, nr) && dist_w [nr][nc] == 255 && d < 254) { dist_w [nr][nc] = (uint8_t) (d + 1); bq [bq_t++] = (uint16_t) (nr * ACOLS + nc); }
      }
   }
   if (bq_h >= bq_t) {
      for (int r = 0; r < ROWS; r++) for (int c = 0; c < ACOLS; c++) dist_p [r][c] = dist_w [r][c];
      bfs_on = 0;
   }
}
static void dj_arena (void) {
   abrick (4, 11, 22, K_BRICK); abrick (28, 35, 22, K_BRICK); abrick (14, 25, 17, K_BRICK);
   abrick (6, 12, 12, K_BRICK); abrick (27, 33, 12, K_BRICK);
   for (int r = 0; r < ROWS; r++) for (int c = 0; c < ACOLS; c++) dist_p [r][c] = 255;
   bfs_on = 0;
}
static void dj_gate (int k) {
   for (int r = 5; r < FLOOR; r++) tile_set (AC () + 20, r, k == K_AIR && r == 17 ? K_BRICK : k);
}
static void dj_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (18); boss.y = AY (8); }
   boss.y = AY (8) + (cosv ((int) t) >> 5);
   switch (boss.attack) {
   case 0:                                                    // shortest-path seekers
      if (tt == 0) cue ("SHORTEST PATH FIRST");
      bfs_slice ();
      if (tt == 30 || tt == 70 || tt == 110) {
         int k = bullet_new (20, (AX (20) - 4) << 4, (AY (8) - 4) << 4, 0, 0, T_NODE, B_BUL2);
         if (k >= 0) { bul [k].a = 20; bul [k].b = 8; bul [k].harm = 5; }
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 20) continue;
         int tx = (AX (b->a) - 4) << 4, ty = (AY (b->b) - 4) << 4;
         if (b->x == tx && b->y == ty) {                      // at a node: step down the gradient
            int best = dist_p [b->b][b->a], bc = b->a, br = b->b;
            static const int dr [4] = { -1, 1, 0, 0 }, dc [4] = { 0, 0, -1, 1 };
            for (int k = 0; k < 4; k++) {
               int nr = b->b + dr [k], nc = b->a + dc [k];
               if (nr >= 0 && nr < ROWS && nc >= 0 && nc < ACOLS && dist_p [nr][nc] < best) { best = dist_p [nr][nc]; bc = nc; br = nr; }
            }
            b->a = bc; b->b = br;
         } else {
            int s = 24;
            if (b->x < tx) b->x = b->x + s > tx ? tx : b->x + s; else if (b->x > tx) b->x = b->x - s < tx ? tx : b->x - s;
            if (b->y < ty) b->y = b->y + s > ty ? ty : b->y + s; else if (b->y > ty) b->y = b->y - s < ty ? ty : b->y - s;
         }
         if (b->t > 460) { b->on = 0; fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_PUFF); }
      }
      if (tt > 520) next_move (3);
      break;
   case 1:                                                    // the semaphore
      if (tt == 0) {
         cue ("P(S): THE GATE IS TAKEN");
         dj_gate (K_GATE); boss.shield = 1;
         if (pcx () >= AX (19) && pcx () < AX (22)) { pl_x = AX (18) - 8; }
         int left = pcx () < AX (20);
         props [0].on = 1; props [0].x = left ? AX (3) : AX (35); props [0].y = AY (FLOOR) - 16;
         props [0].tile = T_SWITCH; props [0].bank = B_PROP; props [0].flags = 0;
         boss.a [0] = left; boss.phase = 0;
         arena_text (5, "SHOOT THE SWITCH TO SIGNAL V(S)");
      }
      if (!boss.phase && tt % 30 == 15) {
         int x = boss.a [0] ? AX (2 + (int) (rnd () % 16)) : AX (22 + (int) (rnd () % 16));
         bullet_new (1, (x - 8) << 4, (AY (1)) << 4, 0, 16, T_DROP, B_BUL);
      }
      if (!boss.phase && tt > 480) boss.phase = tt;           // a timeout releases it too
      if (boss.phase && boss.shield) { dj_gate (K_AIR); boss.shield = 0; props [0].on = 0; arena_text (5, "V(S): SIGNALLED"); }
      if (boss.phase && tt > boss.phase + 90) next_move (3);
      break;
   case 2:                                                    // goto
      if (tt == 0) {
         cue ("GOTO CONSIDERED HARMFUL");
         int c = 4 + (int) (rnd () % 32), r = 6 + (int) (rnd () % 14);
         while (!dj_free (c, r) || !dj_free (c + 1, r + 1)) { c = 4 + (int) (rnd () % 32); r = 6 + (int) (rnd () % 14); }
         props [1].on = 1; props [1].x = AX (c); props [1].y = AY (r); props [1].tile = sfont ('L'); props [1].bank = B_BUL2; props [1].flags = 0;
      }
      if (tt >= 30 && tt <= 120 && tt % 30 == 0) {
         int k = fire_at_player (bcx (), bcy () + 8, 40, T_ARROW, B_BUL);
         if (k >= 0) { bul [k].kind = 21; bul [k].flags = bul [k].vx < 0 ? VDP_SPR_HFLIP : 0; }
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 21) continue;
         b->x += b->vx; b->y += b->vy;
         if (b->t == 36 && !b->a) {                           // goto L
            fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_SPARK);
            b->x = (props [1].x - 4) << 4; b->y = (props [1].y - 4) << 4; b->a = 1;
            int vx, vy; toward (props [1].x + 4, props [1].y + 4, pcx (), pcy (), 44, &vx, &vy);
            b->vx = vx; b->vy = vy; b->flags = vx < 0 ? VDP_SPR_HFLIP : 0;
            fx (props [1].x + 4, props [1].y + 4, T_SPARK);
         }
         if (b->t > 4 && bullet_solid (b)) b->on = 0;
      }
      if (tt > 300) next_move (3);
      break;
   }
   tick ();
}
static int dj_hits (int x, int y) { (void) x; (void) y; return !boss.shield; }
static int dj_other (int x, int y) {
   if (boss.attack == 1 && props [0].on && shot_near (x, y, props [0].x + 8, props [0].y + 6, 9)) { boss.phase = boss.timer; return 1; }
   for (int i = 0; i < NBUL; i++)
      if (bul [i].on && bul [i].kind == 20 && shot_near (x, y, (bul [i].x >> 4) + 8, (bul [i].y >> 4) + 8, 8)) {
         bul [i].on = 0; fx ((bul [i].x >> 4) + 8, (bul [i].y >> 4) + 8, T_PUFF); return 1;
      }
   return 0;
}

// ================================================================ Tony Hoare
#define HP0 22                                       // the first pillar column (8 pillars)
static int ho_h [8], ho_cur [8], ho_stack [32], ho_sp, ho_lo, ho_hi, ho_i, ho_j, ho_part, ho_p, ho_ph;
static void ho_arena (void) { abrick (32, 38, 14, K_BRICK); abrick (5, 10, 21, K_BRICK); }
static void ho_draw (int i, int pivot) {
   for (int r = FLOOR - 9; r < FLOOR; r++)
      tile_set (AC () + HP0 + i, r, r >= FLOOR - ho_cur [i] ? (pivot ? K_PIVOT : K_PILLAR) : K_AIR);
}
static void ho_show_all (void) { for (int i = 0; i < 8; i++) ho_draw (i, ho_part && ho_cur [i] == ho_p); player_bump_up (); }
// one comparison of quicksort with Hoare's partition (1961): the pivot is the middle value; i
// climbs past smaller, j descends past larger, out-of-place pairs swap; at i >= j recurse on
// [lo, j] and [j + 1, hi].  0: sorted.
static int ho_step (void) {
   if (!ho_part) {
      while (ho_sp > 0) {
         ho_hi = ho_stack [--ho_sp]; ho_lo = ho_stack [--ho_sp];
         if (ho_lo < ho_hi) { ho_p = ho_cur [(ho_lo + ho_hi) / 2]; ho_i = ho_lo; ho_j = ho_hi; ho_ph = 0; ho_part = 1; return 1; }
      }
      return 0;
   }
   if (ho_ph == 0) {
      if (ho_cur [ho_i] < ho_p) ho_i++; else ho_ph = 1;
   } else if (ho_cur [ho_j] > ho_p) ho_j--;
   else if (ho_i >= ho_j) {
      if (ho_sp <= 28) { ho_stack [ho_sp++] = ho_lo; ho_stack [ho_sp++] = ho_j; ho_stack [ho_sp++] = ho_j + 1; ho_stack [ho_sp++] = ho_hi; }
      ho_part = 0;
   } else {
      int v = ho_cur [ho_i]; ho_cur [ho_i] = ho_cur [ho_j]; ho_cur [ho_j] = v;
      ho_i++; ho_j--; ho_ph = 0;
   }
   return 1;
}
static void ho_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (34); boss.y = AY (14) - 32; }
   switch (boss.attack) {
   case 0:                                                    // quicksort
      if (tt == 0) {
         cue ("QUICKSORT: PARTITION AROUND A PIVOT");
         for (int i = 0; i < 8; i++) ho_h [i] = i + 1;
         for (int i = 7; i > 0; i--) { int j = (int) (rnd () % (uint32_t) (i + 1)), v = ho_h [i]; ho_h [i] = ho_h [j]; ho_h [j] = v; }
         for (int i = 0; i < 8; i++) ho_cur [i] = 0;
         ho_sp = 0; ho_part = 0; ho_stack [ho_sp++] = 0; ho_stack [ho_sp++] = 7; boss.phase = 0;
      }
      if (boss.phase == 0 && tt % 6 == 0) {                   // the pillars rise
         int done = 1;
         for (int i = 0; i < 8; i++) if (ho_cur [i] < ho_h [i]) { ho_cur [i]++; done = 0; }
         ho_show_all ();
         if (done) boss.phase = 1;
      } else if (boss.phase == 1 && tt % 10 == 0) {
         if (!ho_step ()) { boss.phase = tt; arena_text (5, "SORTED: CLIMB THE STAIRS"); }
         ho_show_all ();
      } else if (boss.phase > 1 && tt > boss.phase + 360 && tt % 6 == 0) {
         int done = 1;
         for (int i = 0; i < 8; i++) if (ho_cur [i] > 0) { ho_cur [i]--; done = 0; }
         ho_show_all ();
         if (done) next_move (3);
      }
      if (tt % 70 == 35) fire_at_player (bcx () - 8, bcy (), 36, T_ORB, B_BUL);
      break;
   case 1: {                                                  // {P} C {Q}
      if (tt == 0) {
         cue ("{P} C {Q}");
         boss.a [0] = 2 + (int) (rnd () % 14);
         abrick (boss.a [0], boss.a [0] + 4, FLOOR, K_ZONE);
         arena_text (5, "THROW FROM P: THE LEMMA REACHES Q");
      }
      for (int i = 0; i < NBUL; i++) {                         // proved lemmas home on the boss
         bullet *b = &bul [i];
         if (!b->on || b->kind != 30) continue;
         int vx, vy; toward ((b->x >> 4) + 8, (b->y >> 4) + 8, bcx (), bcy (), 64, &vx, &vy);
         b->x += vx; b->y += vy;
         if (shot_near ((b->x >> 4) + 8, (b->y >> 4) + 8, bcx (), bcy (), 12)) { b->on = 0; boss_damage (1); }
      }
      if (tt % 45 == 20) fire_at_player (bcx () - 8, bcy (), 28, T_ORB, B_BUL);
      if (tt == 480) abrick (boss.a [0], boss.a [0] + 4, FLOOR, K_GROUND);
      if (tt > 500) next_move (3);
      break;
   }
   case 2:                                                    // null references
      if (tt == 0) {
         cue ("NULL: A BILLION DOLLAR MISTAKE");
         for (int k = 0; k < 3; k++) boss.a [k] = 8 + 7 * k + (int) (rnd () % 4);
      }
      if (tt < 48 && (tt & 7) == 0)
         for (int k = 0; k < 3; k++) for (int r = FLOOR; r < ROWS; r++) abrick (boss.a [k], boss.a [k] + 1, r, r == FLOOR && (tt & 8) ? K_NULL : K_GROUND);
      if (tt == 48)
         for (int k = 0; k < 3; k++) { abrick (boss.a [k], boss.a [k] + 1, FLOOR, K_NULL); for (int r = FLOOR + 1; r < ROWS; r++) abrick (boss.a [k], boss.a [k] + 1, r, K_AIR); }
      if (tt > 48 && tt < 400 && tt % 50 == 0) {               // rollers along the floor
         int k = bullet_new (31, (AX (31)) << 4, (AY (FLOOR) - 16) << 4, -24, 0, T_ORB_M, B_BUL);
         if (k >= 0) bul [k].harm = 5;
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 31) continue;
         b->x += b->vx; b->y += b->vy;
         if (solid_px ((b->x >> 4) + 8, (b->y >> 4) + 17)) b->vy = 0; else b->vy += 4;
         if ((b->x >> 4) < AX (1)) b->on = 0;
      }
      if (tt == 420) for (int k = 0; k < 3; k++) for (int r = FLOOR; r < ROWS; r++) abrick (boss.a [k], boss.a [k] + 1, r, K_GROUND);
      if (tt == 421) player_bump_up ();
      if (tt > 440) next_move (3);
      break;
   }
   tick ();
}
static int ho_other (int x, int y) {
   if (boss.attack == 1 && boss.timer < 480 && feet_kind () == K_ZONE && iabs (y - pcy ()) < 12) {
      int k = bullet_new (30, (x - 8) << 4, (y - 8) << 4, 0, 0, T_SHOT, B_SHOT);   // proved: it reaches Q
      if (k >= 0) { bul [k].harm = 0; bul [k].bank = B_BUL2; }
      return 1;
   }
   return 0;
}

// ================================================================ Leslie Lamport
static int la_c [4];
static const int la_pos [4][2] = { { 2, 6 }, { 36, 6 }, { 2, 16 }, { 36, 16 } };
static void la_arena (void) { abrick (5, 12, 20, K_BRICK); abrick (27, 34, 20, K_BRICK); abrick (15, 24, 14, K_BRICK); }
static int la_max (void) { int m = 0; for (int i = 0; i < 4; i++) if (la_c [i] > m) m = la_c [i]; return m; }
static void la_label (int i) {
   props [4 + i].on = 1; props [4 + i].x = AX (la_pos [i][0]) + (la_pos [i][0] < 20 ? 16 : -10); props [4 + i].y = AY (la_pos [i][1]) + 4;
   props [4 + i].tile = sfont ((char) ('0' + la_c [i] % 10)); props [4 + i].bank = B_TEXT; props [4 + i].flags = 0;
}
static void la_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (32); boss.y = AY (FLOOR) - 32; }
   switch (boss.attack) {
   case 0:                                                    // logical clocks
      if (tt == 0) {
         cue ("LOGICAL CLOCKS: LEAST TIME FIRES");
         arena_text (5, "A HIT IS A MESSAGE: MAX + 1");
         for (int i = 0; i < 4; i++) {
            la_c [i] = (int) (rnd () % 4);
            props [i].on = 1; props [i].x = AX (la_pos [i][0]); props [i].y = AY (la_pos [i][1]);
            props [i].tile = T_CLOCK; props [i].bank = B_PROP; props [i].flags = 0;
            la_label (i);
         }
         boss.phase = 0;
      }
      if (tt > 20 && tt % 36 == 0 && boss.phase < 12) {
         int e = 0;
         for (int i = 1; i < 4; i++) if (la_c [i] < la_c [e]) e = i;     // (c, i) least: ties to the lower id
         fire_at_player (AX (la_pos [e][0]) + 8, AY (la_pos [e][1]) + 8, 40, T_ORB, B_BUL);
         la_c [e] = la_max () + 1; la_label (e);
         boss.phase++;
      }
      if (boss.phase >= 12 && tt % 36 == 30) next_move (3);
      break;
   case 1:                                                    // the bakery
      if (tt == 0) {
         cue ("BAKERY: TAKE A NUMBER");
         for (int k = 0; k < 4; k++) {
            int m = minion_new (AX (16 + 2 * k), AY (14) - 16, 0, 1, T_MINION, B_ENEMY);
            if (m >= 0) { mins [m].label = 1 + (int) ((k * 3 + boss.cycle) % 4); }
         }
         boss.a [0] = 1; boss.a [1] = 0;                       // now serving; its time
         arena_text (5, "ONE AT A TIME, IN TICKET ORDER");
      }
      {
         int any = 0, served = 0;
         for (int m = 0; m < NMIN; m++) {
            props [m].on = 0;
            if (!mins [m].on || mins [m].label < 0) continue;
            any = 1;
            props [m].on = 1; props [m].x = (mins [m].x >> 4) + 4; props [m].y = (mins [m].y >> 4) - 10;
            props [m].tile = sfont ((char) ('0' + mins [m].label)); props [m].bank = B_TEXT; props [m].flags = 0;
            if (mins [m].label == boss.a [0]) {
               served = 1;
               if (mins [m].kind != 1) { mins [m].kind = 1; mins [m].vx = 12; boss.a [1] = 0; }
               if (++boss.a [1] > 300) { mins [m].on = 0; props [m].on = 0; fx ((mins [m].x >> 4) + 8, (mins [m].y >> 4) + 8, T_PUFF); }
            }
         }
         if (!served && boss.a [0] <= 4) boss.a [0]++;          // the next customer
         if (!any && tt > 10) next_move (3);
      }
      if (tt % 60 == 40) fire_at_player (bcx (), bcy (), 32, T_ORB, B_BUL);
      break;
   case 2: {                                                  // Paxos
      if (tt == 0) {
         static char line [] = "PAXOS: BALLOT 0, QUORUM 2 OF 3";
         line [14] = (char) ('1' + boss.cycle % 9);
         cue (line);
         for (int i = 0; i < 3; i++) {
            props [i].on = 1; props [i].x = AX (8 + 10 * i); props [i].y = AY (FLOOR) - 16;
            props [i].tile = T_LIGHT; props [i].bank = B_PROP; props [i].flags = 0;
            boss.a [i] = 0;                                    // 0 idle, 1 accepted, 2 rejected
         }
         boss.phase = 0; boss.a [3] = 0;
         arena_text (5, "SHOOT ACCEPTORS TO DENY THE QUORUM");
      }
      int acc = 0, rej = 0;
      for (int i = 0; i < 3; i++) { acc += boss.a [i] == 1; rej += boss.a [i] == 2; props [i].bank = boss.a [i] == 1 ? B_SHOT : boss.a [i] == 2 ? B_ENEMY : B_PROP; }
      if (!boss.phase) {
         if (tt > 40 && tt % 70 == 0)
            for (int i = 0; i < 3; i++) if (boss.a [i] == 0) { boss.a [i] = 1; break; }
         if (acc >= 2) { boss.phase = tt; arena_text (5, "CHOSEN: THE VALUE IS DECIDED"); }
         else if (rej >= 2) { boss.phase = tt; boss.stun = 180; arena_text (5, "NO QUORUM: THE BALLOT FAILS"); }
         else if (acc + rej == 3) { boss.phase = tt; arena_text (5, "NO QUORUM: THE BALLOT FAILS"); boss.stun = 120; }
      } else if (acc >= 2 && tt < boss.phase + 80 && tt % 6 == 0) {
         int x = AX (2 + (int) (rnd () % 36));
         bullet_new (1, (x - 8) << 4, AY (0) << 4, 0, 0, T_ORB, B_BUL);
      }
      if (boss.phase && tt > boss.phase + 200) next_move (3);
      break;
   } }
   boss.frame = boss.stun ? (t >> 3) & 1 : boss.frame;
   tick ();
}
static int la_other (int x, int y) {
   if (boss.attack == 0 && props [0].on)
      for (int i = 0; i < 4; i++)
         if (shot_near (x, y, props [i].x + 8, props [i].y + 7, 9)) { la_c [i] = la_max () + 1; la_label (i); fx (x, y, T_SPARK); return 1; }
   if (boss.attack == 2 && !boss.phase)
      for (int i = 0; i < 3; i++)
         if (props [i].on && boss.a [i] == 0 && shot_near (x, y, props [i].x + 8, props [i].y + 6, 9)) { boss.a [i] = 2; fx (x, y, T_SPARK); return 1; }
   return 0;
}

// ================================================================ Andrew Appel
#define CPS_N 48
static int cps_x [3][CPS_N], cps_y [3][CPS_N];
static void ap_arena (void) { abrick (8, 14, 20, K_BRICK); abrick (25, 31, 20, K_BRICK); }
static const int ap_cert [3][2] = { { 11, 20 }, { 28, 20 }, { 4, FLOOR } };   // where certificates appear
static void ap_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (33); boss.y = AY (FLOOR) - 32; }
   switch (boss.attack) {
   case 0:                                                    // continuation-passing style
      if (tt == 0) { cue ("COMPILING WITH CONTINUATIONS"); arena_text (5, "EVERY CALL RETURNS THE WAY IT CAME"); }
      if (tt == 20 || tt == 50 || tt == 80) {
         int k = bullet_new (40, (bcx () - 8) << 4, (boss.y) << 4, -(40 + 16 * (tt / 30)), -60, T_ORB_M, B_BUL);
         if (k >= 0) { bul [k].a = tt / 30; bul [k].b = 0; bul [k].c = 0; bul [k].harm = 5; }
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 40) continue;
         int k = b->a < 0 ? 0 : b->a > 2 ? 2 : b->a;
         if (!b->c) {                                         // the call: record the path
            b->vy += 3; b->x += b->vx; b->y += b->vy;
            if ((b->t & 1) == 0 && b->b < CPS_N) { cps_x [k][b->b] = b->x; cps_y [k][b->b] = b->y; b->b++; }
            if (b->b >= CPS_N || bullet_solid (b)) { b->c = 1; b->bank = B_BUL2; fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_SPARK); }
         } else {                                             // the continuation: return the same way
            if (b->b > 0) { b->b--; b->x = cps_x [k][b->b]; b->y = cps_y [k][b->b]; }
            else b->on = 0;
         }
      }
      if (tt > 240) next_move (3);
      break;
   case 1:                                                    // foundational proof-carrying code
      if (tt == 0) {
         cue ("PROOF-CARRYING CODE: SHOW ME A PROOF");
         arena_text (5, "TAKE A # : YOUR NEXT LEMMAS CARRY PROOFS");
         boss.shield = 1;
      }
      for (int k = 0; k < 3; k++) {                            // certificates: a tombstone each
         prop *c = &props [k];
         if (!c->on && tt % 150 == 20 + 40 * k) {
            c->on = 1; c->x = AX (ap_cert [k][0]); c->y = AY (ap_cert [k][1]) - 16;
            c->tile = sfont ('#'); c->bank = B_BUL2; c->flags = 0;
         }
         if (c->on && iabs (c->x - pl_x) < 12 && iabs (c->y - pl_y) < 14) { c->on = 0; pl_certs += 3; psnd_cue (); }
      }
      if (tt % 40 == 10) fire_at_player (bcx (), bcy (), 34, T_ORB, B_BUL);
      if (tt > 70 && tt % 90 == 0) {
         int k = bullet_new (1, (bcx () - 8) << 4, boss.y << 4, -24 - (int) (rnd () % 24), -64, T_ORB_M, B_BUL);
         if (k >= 0) bul [k].harm = 5;
      }
      if (tt > 620) { boss.shield = 0; next_move (3); }
      break;
   case 2: {                                                  // generational GC
      if (tt == 0) { cue ("SIMPLE GENERATIONAL GC"); arena_text (5, "MOST OBJECTS DIE YOUNG"); }
      if (tt >= 10 && tt <= 70 && tt % 12 == 10) {
         int m = minion_new (bcx () - 8, bcy (), -10, 1, T_MINION, B_BUL2);
         if (m >= 0) mins [m].kind = 1;
      }
      if (tt == 220) {
         arena_text (5, "MINOR GC: SURVIVORS ARE PROMOTED");
         int kept = 0;
         for (int m = 0; m < NMIN; m++) {
            if (!mins [m].on) continue;
            if (kept < 2) { kept++; mins [m].tile = T_BIGMIN; mins [m].hp = 3; mins [m].vx = mins [m].vx < 0 ? -18 : 18; mins [m].bank = B_ENEMY; }
            else { mins [m].on = 0; fx ((mins [m].x >> 4) + 8, (mins [m].y >> 4) + 8, T_PUFF); }
         }
      }
      int any = 0;
      for (int m = 0; m < NMIN; m++) any |= mins [m].on;
      if (tt % 55 == 30) fire_at_player (bcx (), bcy (), 30, T_ORB, B_BUL);
      if ((tt > 230 && !any) || tt > 760) next_move (3);
      break;
   } }
   tick ();
}
static int ap_hits (int x, int y) {
   (void) x; (void) y;
   if (!boss.shield) return 1;
   if (shot_proved) return 1;                                // the checker accepts a proof
   arena_text (7, "REJECTED: NO PROOF ATTACHED");
   return 0;
}

// ================================================================ Robert Harper
static void ha_arena (void) { abrick (6, 13, 21, K_BRICK); abrick (26, 33, 21, K_BRICK); abrick (16, 23, 15, K_BRICK); }
static void ha_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (32); boss.y = AY (FLOOR) - 32; }
   switch (boss.attack) {
   case 0:                                                    // unityped
      if (tt == 0) cue ("UNITYPED: ALL VALUES LOOK ALIKE");
      if (tt >= 20 && tt <= 140 && tt % 24 == 20) {
         int k = fire_at_player (bcx (), bcy (), 20, T_ORB_M, B_BUL);
         if (k >= 0) { bul [k].kind = 50; bul [k].a = (int) (rnd () % 3); bul [k].harm = 5; }
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 50) continue;
         if (b->t >= 40 && b->t < 48) b->bank = (b->t & 2) ? B_BUL2 : B_SHOT;   // the tag check
         if (b->t == 48) { b->bank = b->a == 0 ? B_BUL : b->a == 1 ? B_BUL2 : B_ENEMY; b->vx *= 2; b->vy *= 2; }
         if (b->t > 48) {
            if (b->a == 1) { b->vy += 4; if (b->vy > 0 && bullet_solid (b)) b->vy = -72; }
            if (b->a == 2) {
               int vx, vy; toward ((b->x >> 4) + 8, (b->y >> 4) + 8, pcx (), pcy (), 36, &vx, &vy);
               b->vx += isgn (vx - b->vx) * 2; b->vy += isgn (vy - b->vy) * 2;
            }
         }
         b->x += b->vx; b->y += b->vy;
         if ((b->a != 1 || b->t < 48) && b->t > 8 && bullet_solid (b)) b->on = 0;
         if (b->t > 360) b->on = 0;
      }
      if (tt > 420) next_move (3);
      break;
   case 1: {                                                  // computational trinitarianism
      if (tt == 0) {
         cue ("COMPUTATIONAL TRINITARIANISM");
         arena_text (5, "LOGIC, TYPES, CATEGORIES: ONE");
         static const char tag [3] = { 'L', 'T', 'C' };
         for (int k = 0; k < 3; k++) {
            int b = bullet_new (51, 0, 0, 0, 0, sfont (tag [k]), B_BUL2);
            if (b >= 0) { bul [b].a = k; bul [b].harm = 4; }
         }
         boss.shield = 1;
      }
      int n = 0;
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 51) continue;
         n++;
         int a = (int) (tt * 1) + 21 * b->a;
         b->x = (bcx () - 8 + (cosv (a) * 44 >> 6)) << 4;
         b->y = (bcy () - 20 + (sinv (a) * 44 >> 6)) << 4;
         if (tt % 80 == 40 + 5 * b->a) fire_at_player ((b->x >> 4) + 8, (b->y >> 4) + 8, 36, T_ORB, B_BUL);
      }
      if (n == 0 && boss.shield) { boss.shield = 0; boss.stun = 200; arena_text (5, "THEY WERE THE SAME ALL ALONG"); boss.phase = tt; }
      if (tt > 640 && boss.shield) {
         for (int i = 0; i < NBUL; i++) if (bul [i].on && bul [i].kind == 51) bul [i].on = 0;
         boss.shield = 0; boss.phase = tt;
      }
      if (boss.phase && tt > boss.phase + 220) next_move (3);
      break;
   }
   case 2: {                                                  // parallelism is not concurrency
      static const int fork_c [2] = { 6, 18 };
      if (tt == 0) { cue ("PARALLELISM IS NOT CONCURRENCY"); arena_text (5, "FORK, MAP, JOIN: ONE ANSWER"); }
      int forked = tt >= 30 && tt < 300;
      for (int k = 0; k < 2; k++)                              // the copies: the boss's own sprites
         for (int q = 0; q < 4; q++) {
            prop *c = &props [4 * k + q];
            c->on = forked && (tt >= 50 || (tt & 4));
            c->x = AX (fork_c [k]) + 16 * (q & 1); c->y = boss.y + 16 * (q >> 1);
            c->tile = T_BOSS + 32 * 5 + 16 * boss.frame + 4 * q; c->bank = B_BOSS; c->flags = 0;
         }
      if (forked && tt >= 70 && tt % 60 == 10) {               // the same work on each third, at once
         int off [3] = { AX (fork_c [0]) + 16, AX (fork_c [1]) + 16, bcx () };
         for (int k = 0; k < 3; k++)
            for (int d = -1; d <= 1; d++) {
               int j = bullet_new (1, (off [k] + 20 * d - 8) << 4, (boss.y - 20) << 4, 12 * d, -40, T_ORB, B_BUL);
               if (j >= 0) bul [j].harm = 4;
            }
         boss.frame = 1;
      }
      if (tt == 300) { arena_text (5, "JOINED: THE SAME RESULT AS SEQUENTIAL"); for (int i = 0; i < 8; i++) props [i].on = 0; }
      if (tt > 380) next_move (3);
      break;
   } }
   boss.frame = boss.stun ? (t >> 3) & 1 : boss.frame;
   tick ();
}
static int ha_hits (int x, int y) { (void) x; (void) y; return !boss.shield; }
static int ha_other (int x, int y) {
   for (int i = 0; i < NBUL; i++)
      if (bul [i].on && bul [i].kind == 51 && shot_near (x, y, (bul [i].x >> 4) + 4, (bul [i].y >> 4) + 4, 8)) {
         for (int j = 0; j < NBUL; j++) if (bul [j].on && bul [j].kind == 51) { bul [j].on = 0; fx ((bul [j].x >> 4) + 4, (bul [j].y >> 4) + 4, T_PUFF); }
         return 1;
      }
   return 0;
}

// ================================================================ Adam Chlipala
static void ch_arena (void) { abrick (5, 10, 20, K_BRICK); abrick (29, 34, 20, K_BRICK); abrick (15, 24, 16, K_BRICK); }
static void ch_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (32); boss.y = AY (FLOOR) - 32; }
   switch (boss.attack) {
   case 0: {                                                  // crush
      if (tt == 0) { cue ("CRUSH: ALL GOALS SOLVED"); boss.phase = 0; }
      int jt = tt % 100, n = tt / 100;
      int ground = AY (FLOOR) - 32;
      if (n < 3) {
         if (jt == 0) { boss.a [0] = -96; boss.a [1] = isgn (pl_x - boss.x) * 2; boss.frame = 1; }
         boss.a [0] += 4;
         int ny = boss.y + (boss.a [0] >> 4);
         int nx = boss.x + boss.a [1];
         if (nx > AX (2) && nx < AX (35)) boss.x = nx;
         if (boss.a [0] > 0 && jt > 40) boss.a [0] += 12;     // the slam
         if (ny >= ground) {
            if (boss.y < ground) {
               boss.frame = 0;
               for (int s = -1; s <= 1; s += 2) {
                  int k = bullet_new (60, (bcx () - 8) << 4, (AY (FLOOR) - 16) << 4, 48 * s, 0, T_WAVE, B_BUL);
                  if (k >= 0) { bul [k].harm = 5; bul [k].flags = s < 0 ? VDP_SPR_HFLIP : 0; }
               }
            }
            ny = ground; boss.a [0] = 0; boss.a [1] = 0;
         }
         boss.y = ny;
      } else if (tt > 340) next_move (3);
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 60) continue;
         b->x += b->vx;
         if (solid_px ((b->x >> 4) + 8 + isgn (b->vx) * 8, (b->y >> 4) + 8)) b->on = 0;
      }
      break;
   }
   case 1: {                                                  // Bedrock: footprints and the frame rule
      if (tt == 0) { cue ("BEDROCK: SEPARATION LOGIC, AUTOMATED"); arena_text (5, "OUTSIDE THE FOOTPRINT, THE FRAME HOLDS"); }
      int round = tt / 120, rt = tt % 120;
      if (round < 3) {
         if (rt == 0) {                                        // a footprint: 3 of the 8 heap cells
            int m = 0, n = 0;
            while (n < 3) { int c = (int) (rnd () % 8); if (!(m & (1 << c))) { m |= 1 << c; n++; } }
            boss.a [2] = m;
         }
         int m = boss.a [2];
         for (int c = 0; c < 8; c++) {
            int c0 = 1 + 5 * c, c1 = c == 7 ? 38 : c0 + 4;
            if (rt < 60 && (rt & 7) == 0) abrick (c0, c1, FLOOR, (m & (1 << c)) && (rt & 8) ? K_DOOMED : K_GROUND);
            if (rt == 60) abrick (c0, c1, FLOOR, K_GROUND);
            if ((m & (1 << c)) && (rt == 60 || rt == 75))       // only the footprint is written
               for (int k = 0; k < 3; k++) {
                  int j = bullet_new (0, (AX (c0 + 1 + 2 * k) - 8 + 4) << 4, (AY (FLOOR) - 12) << 4, 0, -56, T_SPARK, B_BUL);
                  if (j >= 0) bul [j].harm = 5;
               }
         }
      }
      if (tt > 380) next_move (3);
      break;
   }
   case 2: {                                                  // Ur/Web: no broken links
      if (tt == 0) {
         cue ("UR/WEB: NO BROKEN LINKS");
         arena_text (5, "A LINK HERE CANNOT BE BROKEN");
         for (int k = 0; k < 3; k++)
            for (int d = 1; d <= 5; d++) {
               int b = bullet_new (62, 0, 0, 0, 0, T_DOT, B_BUL2);
               if (b >= 0) { bul [b].a = k; bul [b].b = d; bul [b].harm = 3; }
            }
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 62) continue;
         int a = 32 + (b->a - 1) * 6 + (cosv ((int) (tt / 3)) * 10 >> 6);
         int r = 26 * b->b;
         b->x = (bcx () - 8 + (cosv (a) * r >> 6)) << 4;
         b->y = (bcy () - 8 + (sinv (a) * r >> 6)) << 4;
         if (tt > 420) b->on = 0;
      }
      if (tt % 70 == 50) fire_at_player (bcx (), bcy (), 36, T_ORB, B_BUL);
      if (tt > 440) next_move (3);
      break;
   } }
   tick ();
}

const boss_def bosses [7] = {
   { "JOHN MCCARTHY",   "LISP",             "\\", 0x40A040, 0xC0FF60, 0x102018, mc_arena, mc_update, all_hit, no_other },
   { "EDSGER DIJKSTRA", "SHORTEST PATHS",   "*",  0x3060C0, 0xA0D0FF, 0x0C1430, dj_arena, dj_update, dj_hits, dj_other },
   { "TONY HOARE",      "QUICKSORT, LOGIC", "{",  0xC07020, 0xFFD080, 0x201008, ho_arena, ho_update, all_hit, ho_other },
   { "LESLIE LAMPORT",  "CLOCKS, PAXOS",    "%",  0x7040B0, 0xE0B0FF, 0x140C24, la_arena, la_update, all_hit, la_other },
   { "ANDREW APPEL",    "CONTINUATIONS",    "K",  0x208080, 0x80FFF0, 0x081818, ap_arena, ap_update, ap_hits, no_other },
   { "ROBERT HARPER",   "TYPE THEORY",      "&",  0xB03030, 0xFFB0A0, 0x200C0C, ha_arena, ha_update, ha_hits, ha_other },
   { "ADAM CHLIPALA",   "CERTIFIED CODE",   "@",  0xB09020, 0xFFF0A0, 0x181408, ch_arena, ch_update, all_hit, no_other } };
