// sw/game2d/proof_boss.c: Proof Obligation's seven bosses.  Each attack is one of the boss's
// formal-methods ideas working as a game mechanic, and where it is an algorithm it is the real
// one (notes/proof-obligation.md has the table and the sources):
//   McCarthy  compiler correctness (an expression compiled to stack code, run, and equal to its
//             value: McCarthy-Painter); recursion induction (two functions with one recursion are
//             one function); AMB, the angelic choice of where to be
//   Dijkstra  the weakest precondition (wp of a conveyor program, computed back from Q); guarded
//             commands (any true guard may fire; none aborts); a loop variant (the loop ends when
//             it reaches 0); self-stabilization (his K-state token ring, run by a central daemon)
//   Hoare     {P} C {Q} (lemmas thrown from inside P are proved to reach Q); FIND (his 1961
//             algorithm, one comparison a step, its invariant shown); CSP (a rendezvous on a
//             channel; stop the sender and the receiver deadlocks)
//   Lamport   TLA+ model checking (a breadth-first search of every reachable state; reach the
//             player and the invariant fails); safety and liveness; logical clocks; Paxos
//   Appel     foundational proof-carrying code (only certified lemmas get through); step-indexed
//             models (each step spends the index; at 0 nothing is left); VST (no use after free)
//   Harper    progress and preservation (a well-typed term steps, keeping its type, to a value);
//             LF (a derivation is a term: take it apart); the Definition of Standard ML (well-typed
//             programs do not go wrong: the checker runs first); computational trinitarianism
//   Chlipala  crush (a slam that clears the floor); Bedrock (separation logic: an attack writes
//             only its footprint); Fiat Cryptography (limbs with carries, modulo 99999); Kami (a
//             pipeline whose shots are the spec's, three stages later)
// The algorithmic state (mc_*, ss_*, fd_*, ft_*, km_*) is not static: formal/sw/cbmc proves
// properties of these functions directly.
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
static int pcol (void) { return (pcx () - arena_x) >> 3; }  // the player's arena column

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
static void prop_set (int i, int x, int y, int tile, int bank) {
   props [i].on = 1; props [i].x = x; props [i].y = y; props [i].tile = tile; props [i].bank = bank; props [i].flags = 0;
}
static int digit (int v) { return sfont ((char) ('0' + (v < 0 ? 0 : v % 10))); }
static char *num (char *p, int v) {                    // decimal, no terminator; returns the end
   char tmp [8]; int n = 0;
   if (v < 0) v = 0;
   do { tmp [n++] = (char) ('0' + v % 10); v /= 10; } while (v && n < 7);
   while (n) *p++ = tmp [--n];
   return p;
}
static void floor_restore (void) { for (int r = FLOOR; r < ROWS; r++) abrick (1, 38, r, K_GROUND); player_bump_up (); }

// ---- the move scheduler: boss.attack is the move, boss.timer frames into it
static void cue (const char *s) { boss_cue (s); boss.frame = 1; }
static void say (const char *s) { arena_text (5, s); }
static void note (const char *s) { arena_text (7, s); }
static void next_move (int n) {
   boss.attack = (boss.attack + 1) % n; boss.timer = -1; boss.phase = 0; boss.frame = 0; boss.shield = 0;
   arena_clear_text (3); arena_clear_text (5); arena_clear_text (7);
   for (int i = 0; i < NPROP; i++) props [i].on = 0;
}
static void tick (void) {
   boss.timer++;
   if (boss.timer == 50) boss.frame = 0;
   if (boss.stun) boss.stun--;
   if (feet_kind () == K_HOT) player_hurt ();              // hot floor hurts in every fight
}
static int all_hit (int x, int y) { (void) x; (void) y; return 1; }
static int no_other (int x, int y) { (void) x; (void) y; return 0; }
static int open_hits (int x, int y) { (void) x; (void) y; return !boss.shield || boss.stun; }

// a floor roller: rolls along the ground, falls off edges (kind 31)
static void rollers (void) {
   for (int i = 0; i < NBUL; i++) {
      bullet *b = &bul [i];
      if (!b->on || b->kind != 31) continue;
      b->x += b->vx; b->y += b->vy;
      if (solid_px ((b->x >> 4) + 8, (b->y >> 4) + 17)) b->vy = 0; else b->vy += 4;
      if (solid_px ((b->x >> 4) + 8 + isgn (b->vx) * 9, (b->y >> 4) + 8)) b->on = 0;
   }
}
static void roller (int c, int dir) {
   int k = bullet_new (31, AX (c) << 4, (AY (FLOOR) - 16) << 4, 24 * dir, 0, T_ORB_M, B_BUL);
   if (k >= 0) bul [k].harm = 5;
}

// ================================================================ John McCarthy
// spots: 0 the left platform, 1 the middle platform, 2 the right floor
static const int mc_spot [3][2] = { { 7, 21 }, { 18, 16 }, { 33, FLOOR } };
static void mc_arena (void) { abrick (6, 11, 21, K_BRICK); abrick (16, 23, 16, K_BRICK); abrick (28, 33, 21, K_BRICK); }
// compiler correctness: an expression (a o1 (b o2 c)) or ((a o2 b) o1 c), o in {+, *}, compiled
// to stack code (PUSH n, ADD, MUL) and run on a stack machine.  mc_eval is the meaning; the
// machine's answer is shown next to it.  (McCarthy and Painter, 1967: the first proof that a
// compiler is correct -- for exactly this language of arithmetic expressions.)
enum { OP_ADD = -1, OP_MUL = -2 };
int mc_form, mc_a, mc_b, mc_c, mc_o1, mc_o2;          // the expression
int mc_code [5], mc_pc, mc_st [3], mc_sp;             // the compiled code and the machine
static int mc_apply (int o, int x, int y) { return o == OP_ADD ? x + y : x * y; }
int mc_eval (void) {
   return mc_form == 0 ? mc_apply (mc_o1, mc_a, mc_apply (mc_o2, mc_b, mc_c))
                       : mc_apply (mc_o1, mc_apply (mc_o2, mc_a, mc_b), mc_c);
}
void mc_compile (void) {
   if (mc_form == 0) { mc_code [0] = mc_a; mc_code [1] = mc_b; mc_code [2] = mc_c; mc_code [3] = mc_o2; mc_code [4] = mc_o1; }
   else { mc_code [0] = mc_a; mc_code [1] = mc_b; mc_code [2] = mc_o2; mc_code [3] = mc_c; mc_code [4] = mc_o1; }
   mc_pc = 0; mc_sp = 0;
}
int mc_step (void) {                                  // one instruction; 0 when the code is done
   if (mc_pc >= 5) return 0;
   int op = mc_code [mc_pc++];
   if (op > 0) { if (mc_sp < 3) mc_st [mc_sp++] = op; }
   else if (mc_sp >= 2) { mc_st [mc_sp - 2] = mc_apply (op, mc_st [mc_sp - 2], mc_st [mc_sp - 1]); mc_sp--; }
   return 1;
}
static void mc_text (char *s) {                       // "(+ 2 (* 3 1))"
   char o1 = mc_o1 == OP_ADD ? '+' : '*', o2 = mc_o2 == OP_ADD ? '+' : '*';
   char *p = s;
   *p++ = '('; *p++ = o1; *p++ = ' ';
   if (mc_form == 0) { *p++ = (char) ('0' + mc_a); *p++ = ' '; *p++ = '('; *p++ = o2; *p++ = ' '; *p++ = (char) ('0' + mc_b); *p++ = ' '; *p++ = (char) ('0' + mc_c); *p++ = ')'; }
   else { *p++ = '('; *p++ = o2; *p++ = ' '; *p++ = (char) ('0' + mc_a); *p++ = ' '; *p++ = (char) ('0' + mc_b); *p++ = ')'; *p++ = ' '; *p++ = (char) ('0' + mc_c); }
   *p++ = ')'; *p = 0;
}
static void mc_show_stack (void) {
   for (int i = 0; i < 3; i++) {
      props [2 + i].on = 0;
      if (i < mc_sp) prop_set (2 + i, AX (19), AY (13) - 16 * i, digit (mc_st [i]), B_TEXT);
   }
}
static void mc_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.a [6] = 2; boss.x = AX (mc_spot [2][0]); boss.y = AY (mc_spot [2][1]) - 32; }
   switch (boss.attack) {
   case 0: {                                                  // compiler correctness
      if (tt == 0) {
         cue ("COMPILER CORRECTNESS");
         do {
            mc_form = (int) (rnd () & 1); mc_a = 1 + (int) (rnd () % 3); mc_b = 1 + (int) (rnd () % 3); mc_c = 1 + (int) (rnd () % 3);
            mc_o1 = (rnd () & 1) ? OP_ADD : OP_MUL; mc_o2 = (rnd () & 1) ? OP_ADD : OP_MUL;
         } while (mc_eval () > 9);
         static char line [40];
         mc_text (line); say (line);
         mc_compile (); mc_show_stack ();
      }
      if (tt >= 40 && tt % 40 == 0 && mc_pc < 5) {
         int op = mc_code [mc_pc];
         static char ins [12] = "PUSH 0";
         if (op > 0) { ins [5] = (char) ('0' + op); note (ins); fire_at_player (bcx (), bcy (), 34, T_ORB, B_BUL); }
         else {
            note (op == OP_ADD ? "ADD" : "MUL");
            for (int d = -1; d <= 1; d += 2) {
               int k = bullet_new (1, (bcx () - 8) << 4, boss.y << 4, 20 * d, -60, T_ORB, B_BUL);
               if (k >= 0) bul [k].harm = 5;
            }
         }
         mc_step (); mc_show_stack ();
      }
      if (tt == 260) {                                         // the machine's answer is the meaning
         static char line [40] = "RUN = EVAL = ";
         char *p = num (line + 13, mc_st [0]); *p = 0;
         note (line);
         int v = mc_st [0];
         for (int k = 0; k < v; k++) {                         // as many as the value: a fan
            int a = 24 + (k * 16) / (v > 1 ? v - 1 : 1);
            int j = bullet_new (0, (bcx () - 8) << 4, (bcy () - 8 - 2 * k) << 4, cosv (a) * 40 >> 6, -(sinv (a) * 40 >> 6), T_ORB, B_BUL);
            if (j >= 0) bul [j].harm = 5;
         }
      }
      if (tt > 330) next_move (3);
      break;
   }
   case 1: {                                                  // recursion induction
      if (tt == 0) { cue ("RECURSION INDUCTION"); say ("F AND G SHARE ONE RECURSION: F = G"); boss.a [0] = boss.a [1] = 0; }
      if (tt == 30 || tt == 31) {                              // F from the boss, G mirrored
         int g = tt == 31;
         int x = g ? 2 * arena_x + 8 * ACOLS - bcx () : bcx ();
         int vx = (pcx () - bcx ()) * 16 / 60;
         int k = bullet_new (13, (x - 8) << 4, boss.y << 4, g ? -vx : vx, -72, digit (2), g ? B_BUL2 : B_BUL);
         if (k >= 0) { bul [k].a = 2; bul [k].b = g; bul [k].harm = 5; }
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 13) continue;
         b->vy += 4; b->x += b->vx; b->y += b->vy;
         if (b->vy > 0 && solid_px ((b->x >> 4) + 8, (b->y >> 4) + 14)) {
            if (b->a == 0) { b->on = 0; boss.a [b->b]++; fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_SPARK); continue; }
            b->a--; b->tile = digit (b->a); b->vy = -56; b->vx = 20; b->y -= 4 << 4;      // f(n) = f(n-1), f(n-1)
            int k = bullet_new (13, b->x, b->y, -20, -56, b->tile, b->bank);
            if (k >= 0) { bul [k].a = b->a; bul [k].b = b->b; bul [k].harm = 5; }
         }
         if ((b->x >> 4) < AX (1) || (b->x >> 4) > AX (37)) b->vx = -b->vx;
      }
      if (tt == 300) {
         static char line [40] = "LEAVES: F ";
         char *p = num (line + 10, boss.a [0]); *p++ = ','; *p++ = ' '; *p++ = 'G'; *p++ = ' '; p = num (p, boss.a [1]); *p = 0;
         note (line);
      }
      if (tt > 380) next_move (3);
      break;
   }
   default: {                                                 // amb: two candidates, the angel chooses
      if (tt == 0) {
         int s = boss.a [6], c1 = (s + 1) % 3, c2 = (s + 2) % 3;
         boss.a [1] = c1; boss.a [2] = c2;
         for (int k = 0; k < 2; k++) {
            int sp = k ? c2 : c1;
            prop_set (k, AX (mc_spot [sp][0]) + 8, AY (mc_spot [sp][1]) - 24, T_GHOST, B_BOSS);
         }
         cue ("(AMB A B)"); say ("THE ANGEL PICKS THE CHOICE THAT WORKS");
      }
      if (tt > 0 && tt < 40) props [0].on = props [1].on = (tt & 4) != 0;
      if (tt == 40) {
         int c1 = boss.a [1], c2 = boss.a [2];
         int d1 = iabs (AX (mc_spot [c1][0]) - pl_x), d2 = iabs (AX (mc_spot [c2][0]) - pl_x);
         int s = d1 >= d2 ? c1 : c2;                          // angelic: the choice that succeeds
         boss.a [6] = s; boss.x = AX (mc_spot [s][0]); boss.y = AY (mc_spot [s][1]) - 32;
         fx (bcx (), bcy (), T_PUFF);
      }
      if (tt > 70) next_move (3);
      break;
   } }
   tick ();
}

// ================================================================ Edsger Dijkstra
static void dj_arena (void) {
   abrick (4, 11, 22, K_BRICK); abrick (28, 35, 22, K_BRICK); abrick (14, 25, 17, K_BRICK);
   abrick (6, 12, 12, K_BRICK); abrick (27, 33, 12, K_BRICK);
}
// the K-state token ring (Dijkstra, "Self-stabilizing systems in spite of distributed control",
// 1974): machine 0 is privileged when x0 = x[N-1] and moves x0 := x0 + 1 mod K; machine i > 0 is
// privileged when xi != x[i-1] and moves xi := x[i-1].  From any state some machine is
// privileged, and after finitely many moves exactly one is, for ever.
#define SS_N 5
#define SS_K 6
int ss_x [SS_N];
int ss_priv (int i) { return i == 0 ? ss_x [0] == ss_x [SS_N - 1] : ss_x [i] != ss_x [i - 1]; }
int ss_count (void) { int n = 0; for (int i = 0; i < SS_N; i++) n += ss_priv (i); return n; }
void ss_move (int i) { if (i == 0) ss_x [0] = (ss_x [0] + 1) % SS_K; else ss_x [i] = ss_x [i - 1]; }
static const int ss_pos [SS_N][2] = { { 3, 16 }, { 9, 9 }, { 30, 9 }, { 36, 16 }, { 19, 22 } };
static void ss_show (void) {
   for (int i = 0; i < SS_N; i++) prop_set (i, AX (ss_pos [i][0]), AY (ss_pos [i][1]), digit (ss_x [i]), ss_priv (i) ? B_SHOT : B_TEXT);
}
static void dj_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (18); boss.y = AY (8); }
   boss.y = AY (8) + (cosv ((int) t) >> 5);
   switch (boss.attack) {
   case 0: {                                                  // the weakest precondition
      // S: the belt carries whoever stands on the floor d columns.  Q: the marked strip.
      // wp (S, Q) = Q moved back by d: where to stand before S runs, computed from Q.
      if (tt == 0) {
         cue ("THE WEAKEST PRECONDITION");
         int d = 5 + (int) (rnd () % 4);
         boss.a [0] = (rnd () & 1) ? d : -d;                  // the shift, columns
         boss.a [1] = 12 + (int) (rnd () % 10);               // Q: columns [q, q + 4]
         boss.a [3] = 0;
         abrick (boss.a [1], boss.a [1] + 4, FLOOR + 1, K_MARKED);
         say ("Q: WHERE YOU MUST BE WHEN S ENDS");
      }
      int d = boss.a [0], q = boss.a [1];
      if (tt == 60) { abrick (q - d, q - d + 4, FLOOR + 1, K_ZONE); abrick (q, q + 4, FLOOR + 1, K_MARKED); say ("WP(S, Q): STAND HERE BEFORE S RUNS"); }
      if (tt == 150) { abrick (1, 38, FLOOR, K_BELT); say ("S: THE BELT MOVES YOU"); }
      if (tt >= 150 && tt < 270 && feet_kind () == K_BELT) {  // d columns in 120 frames
         boss.a [3] += d * 8 * SUB;
         int push = boss.a [3] / 120; boss.a [3] -= push * 120;
         player_push (push);
      }
      if (tt == 270) {                                         // the postcondition is checked
         abrick (1, 38, FLOOR, K_HOT); abrick (q, q + 4, FLOOR, K_GROUND);
         say ("NOT IN Q: THE FLOOR BURNS");
      }
      if (tt == 330) { floor_restore (); arena_clear_text (5); }
      if (tt % 60 == 30) fire_at_player (bcx (), bcy (), 30, T_ORB, B_BUL);
      if (tt > 360) next_move (4);
      break;
   }
   case 1: {                                                  // guarded commands
      if (tt == 0) {
         cue ("GUARDED COMMANDS: IF ... FI");
         say ("ANY TRUE GUARD MAY FIRE, NONE: ABORT");
         note ("X<14: RAIN  X>25: ROLL  HIGH: AIM");
         boss.shield = 1;
      }
      if (tt >= 40 && tt <= 560 && tt % 70 == 40) {
         int g [3], n = 0;
         if (pcol () < 14) g [n++] = 0;
         if (pcol () > 25) g [n++] = 1;
         if (pl_y < AY (19)) g [n++] = 2;
         if (n == 0) { say ("ABORT: NO GUARD HOLDS"); boss.stun = 90; }
         else {
            say ("ANY TRUE GUARD MAY FIRE, NONE: ABORT");
            int c = g [rnd () % (uint32_t) n];                // the choice is not determined
            if (c == 0) for (int k = 0; k < 4; k++) bullet_new (1, (AX (1 + 3 * k + (int) (rnd () % 3)) - 4) << 4, (AY (1) - 12 * k) * SUB, 0, 8, T_DROP, B_BUL);
            if (c == 1) { roller (37, -1); roller (34, -1); }
            if (c == 2) for (int k = -1; k <= 1; k++) { int j = fire_at_player (bcx (), bcy (), 36, T_ORB, B_BUL); if (j >= 0) bul [j].vx += 10 * k; }
         }
      }
      rollers ();
      if (tt > 620) next_move (4);
      break;
   }
   case 2:                                                    // a loop variant
      if (tt == 0) {
         cue ("DO ... OD: THE VARIANT MUST FALL");
         say ("EACH TURN LOWERS V, AT 0 THE LOOP ENDS");
         boss.a [0] = 9; boss.shield = 1;
      }
      if (boss.a [0] > 0) {
         prop_set (0, bcx () + 18, boss.y + 8, digit (boss.a [0]), B_SHOT);
         if (tt % 45 == 44) {
            boss.a [0]--;
            for (int k = 0; k < 3; k++) {
               int j = bullet_new (0, (bcx () - 8) << 4, bcy () << 4, (k - 1) * 18, 40, T_ORB, B_BUL);
               if (j >= 0) bul [j].harm = 5;
            }
         }
         if (boss.a [0] == 0) { props [0].on = 0; boss.shield = 0; boss.stun = 200; note ("V = 0: THE LOOP TERMINATES"); boss.phase = tt; }
      }
      if (boss.phase && tt > boss.phase + 230) next_move (4);
      break;
   case 3: {                                                  // self-stabilization
      if (tt == 0) {
         cue ("SELF-STABILIZATION");
         say ("FROM ANY STATE, ONE TOKEN, FOR EVER");
         for (int i = 0; i < SS_N; i++) ss_x [i] = (int) (rnd () % SS_K);
         boss.shield = 1;
      }
      if (tt % 30 == 15) {                                     // a central daemon moves one machine
         int c [SS_N], n = 0;
         for (int i = 0; i < SS_N; i++) if (ss_priv (i)) c [n++] = i;
         if (n > 0) ss_move (c [rnd () % (uint32_t) n]);
      }
      ss_show ();
      for (int i = 0; i < SS_N; i++)
         if (ss_priv (i) && (tt + 12 * i) % 72 == 0)
            fire_at_player (AX (ss_pos [i][0]) + 8, AY (ss_pos [i][1]) + 8, 30, T_ORB, B_BUL);
      boss.shield = ss_count () > 1;
      if (tt % 30 == 16) note (boss.shield ? "PRIVILEGES: MORE THAN ONE" : "STABLE: ONE PRIVILEGE CIRCULATES");
      if (tt > 720) next_move (4);
      break;
   } }
   tick ();
}
static int dj_other (int x, int y) {
   if (boss.attack == 2 && props [0].on && shot_near (x, y, props [0].x + 8, props [0].y + 7, 9)) {
      if (boss.a [0] > 1) boss.a [0]--;                       // progress: the variant falls
      fx (x, y, T_SPARK); return 1;
   }
   if (boss.attack == 3)
      for (int i = 0; i < SS_N; i++)
         if (shot_near (x, y, props [i].x + 8, props [i].y + 7, 9)) {
            ss_x [i] = (int) (rnd () % SS_K);                  // a fault: it recovers anyway
            note ("A FAULT: IT STABILIZES AGAIN"); fx (x, y, T_SPARK); return 1;
         }
   return 0;
}

// ================================================================ Tony Hoare
#define HP0 22                                       // the first pillar column (8 pillars)
// FIND (Hoare, Algorithm 65, 1961; proved in "Proof of a program: FIND", 1971): place the f-th
// smallest at A[f] with everything left of it <= and right of it >=.  One comparison a step.
int fd_a [8], fd_cur [8], fd_f, fd_m, fd_n, fd_i, fd_j, fd_r, fd_ph;
void fd_start (int f) { fd_f = f; fd_m = 0; fd_n = 7; fd_ph = 0; }
int fd_step (void) {                                 // 0 when A[f] is in place
   switch (fd_ph) {
   case 0: if (fd_m >= fd_n) return 0;
           fd_r = fd_a [fd_f]; fd_i = fd_m; fd_j = fd_n; fd_ph = 1; return 1;
   case 1: if (fd_a [fd_i] < fd_r) fd_i++; else fd_ph = 2;
           return 1;
   case 2: if (fd_r < fd_a [fd_j]) fd_j--; else fd_ph = 3;
           return 1;
   case 3: if (fd_i <= fd_j) { int v = fd_a [fd_i]; fd_a [fd_i] = fd_a [fd_j]; fd_a [fd_j] = v; fd_i++; fd_j--; }
           fd_ph = fd_i <= fd_j ? 1 : 4; return 1;
   default:
      if (fd_f <= fd_j) fd_n = fd_j;
      else if (fd_i <= fd_f) fd_m = fd_i;
      else { fd_m = fd_n = fd_f; }
      fd_ph = 0; return 1;
   }
}
static void ho_arena (void) { abrick (32, 38, 14, K_BRICK); abrick (5, 10, 21, K_BRICK); }
static void ho_draw (int i) {
   for (int r = FLOOR - 9; r < FLOOR; r++)
      tile_set (AC () + HP0 + i, r, r >= FLOOR - fd_cur [i] ? (fd_ph && fd_cur [i] == fd_r ? K_PIVOT : K_PILLAR) : K_AIR);
}
static void ho_show_all (void) { for (int i = 0; i < 8; i++) ho_draw (i); player_bump_up (); }
static void ho_home (void) { boss.x = AX (34); boss.y = AY (14) - 32; }
static void ho_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; ho_home (); }
   switch (boss.attack) {
   case 0: {                                                  // {P} C {Q}
      if (tt == 0) {
         cue ("{P} C {Q}");
         boss.a [0] = 2 + (int) (rnd () % 14);
         abrick (boss.a [0], boss.a [0] + 4, FLOOR, K_ZONE);
         say ("THROW FROM P: THE LEMMA REACHES Q");
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
   case 1:                                                    // FIND: the top four, each in place
      if (tt == 0) {
         cue ("FIND: THE K-TH IN ITS PLACE");
         say ("INVARIANT: LEFT <= A(F) <= RIGHT");
         for (int i = 0; i < 8; i++) fd_a [i] = i + 1;
         for (int i = 7; i > 0; i--) { int j = (int) (rnd () % (uint32_t) (i + 1)), v = fd_a [i]; fd_a [i] = fd_a [j]; fd_a [j] = v; }
         for (int i = 0; i < 8; i++) fd_cur [i] = 0;
         fd_ph = 0; boss.phase = 0;
      }
      if (boss.phase == 0 && tt % 6 == 0) {                   // the pillars rise
         int done = 1;
         for (int i = 0; i < 8; i++) if (fd_cur [i] < fd_a [i]) { fd_cur [i]++; done = 0; }
         ho_show_all ();
         if (done) { boss.phase = 1; fd_start (7); }
      } else if (boss.phase == 1 && tt % 6 == 0) {
         for (int i = 0; i < 8; i++) fd_cur [i] = fd_a [i];
         if (!fd_step ()) {
            static char line [40] = "FOUND: A(0) = 0";
            line [9] = (char) ('1' + fd_f); line [14] = (char) ('0' + fd_a [fd_f]);
            note (line);
            if (fd_f > 4) fd_start (fd_f - 1);                 // f = 8, 7, 6, 5 (1-based): stairs
            else { boss.phase = tt; say ("THE TOP FOUR ARE STAIRS: CLIMB"); }
         }
         ho_show_all ();
      } else if (boss.phase > 1 && tt > boss.phase + 360 && tt % 6 == 0) {
         int done = 1;
         for (int i = 0; i < 8; i++) if (fd_cur [i] > 0) { fd_cur [i]--; done = 0; }
         fd_ph = 0; ho_show_all ();
         if (done) next_move (3);
      }
      if (tt % 70 == 35) fire_at_player (bcx () - 8, bcy (), 36, T_ORB, B_BUL);
      break;
   case 2: {                                                  // CSP: a rendezvous on channel c
      if (tt == 0) {
         cue ("CSP: C!V MEETS C?X");
         say ("BOTH WAIT, THEN PASS. STOP P: DEADLOCK");
         boss.a [0] = 1; boss.a [1] = 0; boss.a [2] = 0;       // P alive, P ready, Q ready
         prop_set (0, AX (3), AY (10), sfont ('P'), B_TEXT);
         prop_set (1, bcx () - 8, boss.y - 18, sfont ('Q'), B_TEXT);
      }
      if (boss.a [0] && tt % 50 == 25) boss.a [1] = 1;         // P: c!v when it gets there
      if (tt % 80 == 60 && !boss.phase) boss.a [2] = 1;         // Q: c?x
      props [0].bank = boss.a [1] ? B_SHOT : B_TEXT; props [1].bank = boss.a [2] ? B_SHOT : B_TEXT;
      props [0].on = boss.a [0] || (tt & 8);
      if (boss.a [1] && boss.a [2]) {                          // the rendezvous: the value passes
         boss.a [1] = boss.a [2] = 0;
         int vx, vy; toward (AX (3) + 8, AY (10) + 8, bcx (), bcy (), 40, &vx, &vy);
         int k = bullet_new (32, AX (3) << 4, AY (10) << 4, vx, vy, T_ORB_M, B_BUL2);
         if (k >= 0) bul [k].harm = 5;
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 32) continue;
         b->x += b->vx; b->y += b->vy;
         if (shot_near ((b->x >> 4) + 8, (b->y >> 4) + 8, bcx (), bcy (), 14)) {   // x := v, Q acts on it
            b->on = 0;
            for (int d = -1; d <= 1; d++) { int j = fire_at_player (bcx (), bcy (), 34, T_ORB, B_BUL); if (j >= 0) bul [j].vy += 10 * d; }
         }
      }
      if (!boss.a [0] && boss.a [2] && !boss.phase) {          // Q waits on a stopped P
         boss.phase = tt; boss.stun = 240; note ("DEADLOCK: Q WAITS FOR EVER");
         boss.y = AY (FLOOR) - 32; props [1].on = 0; fx (bcx (), bcy (), T_PUFF);
      }
      if (boss.phase && tt == boss.phase + 240) { ho_home (); fx (bcx (), bcy (), T_PUFF); }
      if ((boss.phase && tt > boss.phase + 260) || tt > 900) { ho_home (); next_move (3); }
      break;
   } }
   boss.frame = boss.stun ? (t >> 3) & 1 : boss.frame;
   tick ();
}
static int ho_other (int x, int y) {
   if (boss.attack == 0 && boss.timer < 480 && feet_kind () == K_ZONE && iabs (y - pcy ()) < 12) {
      int k = bullet_new (30, (x - 8) << 4, (y - 8) << 4, 0, 0, T_SHOT, B_SHOT);   // proved: it reaches Q
      if (k >= 0) { bul [k].harm = 0; bul [k].bank = B_BUL2; }
      return 1;
   }
   if (boss.attack == 2 && boss.a [0] && props [0].on && shot_near (x, y, props [0].x + 8, props [0].y + 7, 9)) {
      boss.a [0] = 0; boss.a [1] = 0; note ("P IS STOPPED"); fx (x, y, T_SPARK); return 1;
   }
   return 0;
}

// ================================================================ Leslie Lamport
static uint8_t tl_d [ROWS][ACOLS];                   // TLC's visited set: the depth, 255 = unseen
static uint16_t tl_q [ROWS * ACOLS];
static int tl_h, tl_t, tl_depth, tl_count;
static int tl_free (int c, int r) { return c >= 1 && c < ACOLS - 1 && r >= 8 && r < FLOOR && !k_solid (kind [r][AC () + c]); }
static void tl_start (int c, int r) {
   for (int y = 0; y < ROWS; y++) for (int x = 0; x < ACOLS; x++) tl_d [y][x] = 255;
   tl_h = tl_t = 0; tl_depth = 0; tl_count = 1; tl_d [r][c] = 0; tl_q [tl_t++] = (uint16_t) (r * ACOLS + c);
}
static int tl_layer (void) {                         // expand one depth layer; 1 if it reached the player
   int pc = pcol (), pr = pcy () >> 3, hit = 0;
   while (tl_h < tl_t) {
      int v = tl_q [tl_h], r = v / ACOLS, c = v % ACOLS, d = tl_d [r][c];
      if (d > tl_depth) break;
      tl_h++;
      if (c == pc && (r == pr || r == pr + 1)) hit = 1;
      static const int dr [4] = { -1, 1, 0, 0 }, dc [4] = { 0, 0, -1, 1 };
      for (int k = 0; k < 4; k++) {
         int nr = r + dr [k], nc = c + dc [k];
         if (tl_free (nc, nr) && tl_d [nr][nc] == 255) {
            tl_d [nr][nc] = (uint8_t) (d + 1); tl_q [tl_t++] = (uint16_t) (nr * ACOLS + nc); tl_count++;
            if (kind [nr][AC () + nc] == K_AIR) tile_set (AC () + nc, nr, K_STATE);
         }
      }
   }
   tl_depth++;
   return hit;
}
static int la_c [4];
static const int la_pos [4][2] = { { 2, 6 }, { 36, 6 }, { 2, 16 }, { 36, 16 } };
static const int la_spot [4][3] = { { 5, 12, 20 }, { 27, 34, 20 }, { 15, 24, 14 }, { 2, 37, FLOOR } };
static void la_arena (void) { abrick (5, 12, 20, K_BRICK); abrick (27, 34, 20, K_BRICK); abrick (15, 24, 14, K_BRICK); }
static int la_max (void) { int m = 0; for (int i = 0; i < 4; i++) if (la_c [i] > m) m = la_c [i]; return m; }
static void la_label (int i) {
   prop_set (4 + i, AX (la_pos [i][0]) + (la_pos [i][0] < 20 ? 16 : -10), AY (la_pos [i][1]) + 4, digit (la_c [i]), B_TEXT);
}
static void la_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (32); boss.y = AY (FLOOR) - 32; }
   switch (boss.attack) {
   case 0:                                                    // TLA+: TLC checks every state
      if (tt == 0) {
         cue ("TLA+: TLC CHECKS EVERY STATE");
         say ("IF IT REACHES YOU, THE INVARIANT FAILS");
         tl_start ((bcx () - arena_x) >> 3, (boss.y >> 3) + 1);
         boss.phase = 0;
      }
      if (!boss.phase && tt >= 20 && tt % 5 == 0) {
         int hit = tl_layer ();
         if (hit) { boss.phase = tt; note ("INVARIANT VIOLATED: A TRACE TO YOU"); player_hurt (); }
         else if (tl_depth >= 24 || tl_h >= tl_t) {
            boss.phase = tt;
            static char line [40] = "NO ERROR: ";
            char *p = num (line + 10, tl_count);
            const char *e = " DISTINCT STATES"; while (*e) *p++ = *e++;
            *p = 0; note (line);
         }
      }
      if (boss.phase && tt >= boss.phase + 60 && tt < boss.phase + 66) {   // forget the states
         int r0 = (tt - boss.phase - 60) * 5;
         for (int r = r0; r < r0 + 5 && r < ROWS; r++)
            for (int c = 0; c < ACOLS; c++) if (kind [r][AC () + c] == K_STATE) tile_set (AC () + c, r, K_AIR);
      }
      if (tt % 50 == 25) fire_at_player (bcx (), bcy (), 28, T_ORB, B_BUL);
      if (boss.phase && tt > boss.phase + 90) next_move (4);
      break;
   case 1: {                                                  // safety and liveness
      if (tt == 0) { cue ("SAFETY AND LIVENESS"); say ("SAFETY: THE RED NEVER HOLDS YOU"); }
      if (tt < 240) {                                          // safety: nothing bad happens
         int rt = tt % 80;
         if (rt == 0) {
            int m = 0, n = 0;
            while (n < 3) { int c = (int) (rnd () % 8); if (!(m & (1 << c))) { m |= 1 << c; n++; } }
            boss.a [2] = m;
         }
         for (int c = 0; c < 8; c++) {
            int c0 = 1 + 5 * c, c1 = c == 7 ? 38 : c0 + 4;
            if (!(boss.a [2] & (1 << c))) continue;
            if (rt < 30 && (rt & 7) == 0) abrick (c0, c1, FLOOR, (rt & 8) ? K_DOOMED : K_GROUND);
            if (rt == 30) abrick (c0, c1, FLOOR, K_HOT);
            if (rt == 70) abrick (c0, c1, FLOOR, K_GROUND);
         }
      } else if (tt == 240) {
         floor_restore (); say ("LIVENESS: REACH EACH ! IN TIME"); boss.a [3] = 0; boss.phase = 0;
      } else if (boss.a [3] < 3) {                            // liveness: something good happens
         if (!boss.phase) {
            const int *s = la_spot [rnd () % 4];
            int c = s [0] + (int) (rnd () % (uint32_t) (s [1] - s [0] + 1));
            prop_set (0, AX (c), AY (s [2]) - 16, sfont ('!'), B_SHOT);
            boss.phase = tt; boss.a [4] = 9;
         }
         prop_set (1, props [0].x, props [0].y - 16, digit (boss.a [4]), B_TEXT);
         if ((tt - boss.phase) % 24 == 23) boss.a [4]--;
         if (iabs (props [0].x - pl_x) < 12 && iabs (props [0].y - pl_y) < 14) {
            note ("GOOD STATE REACHED"); boss_damage (2); boss.a [3]++; boss.phase = 0; fx (props [0].x + 8, props [0].y + 8, T_SPARK);
         } else if (boss.a [4] < 0) {
            note ("LIVENESS VIOLATED"); player_hurt (); boss.a [3]++; boss.phase = 0;
         }
         if (boss.a [3] >= 3) { props [0].on = props [1].on = 0; boss.a [5] = tt; }
      } else if (tt > boss.a [5] + 60) next_move (4);
      if (tt % 60 == 30) fire_at_player (bcx (), bcy (), 26, T_ORB, B_BUL);
      break;
   }
   case 2:                                                    // logical clocks
      if (tt == 0) {
         cue ("LOGICAL CLOCKS: LEAST TIME FIRES");
         say ("A HIT IS A MESSAGE: MAX + 1");
         for (int i = 0; i < 4; i++) {
            la_c [i] = (int) (rnd () % 4);
            prop_set (i, AX (la_pos [i][0]), AY (la_pos [i][1]), T_CLOCK, B_PROP);
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
      if (boss.phase >= 12 && tt % 36 == 30) next_move (4);
      break;
   case 3: {                                                  // Paxos
      if (tt == 0) {
         static char line [] = "PAXOS: BALLOT 0, QUORUM 2 OF 3";
         line [14] = (char) ('1' + boss.cycle % 9);
         cue (line);
         for (int i = 0; i < 3; i++) { prop_set (i, AX (8 + 10 * i), AY (FLOOR) - 16, T_LIGHT, B_PROP); boss.a [i] = 0; }
         boss.phase = 0; boss.a [3] = 0;
         say ("SHOOT ACCEPTORS TO DENY THE QUORUM");
      }
      int acc = 0, rej = 0;
      for (int i = 0; i < 3; i++) { acc += boss.a [i] == 1; rej += boss.a [i] == 2; props [i].bank = boss.a [i] == 1 ? B_SHOT : boss.a [i] == 2 ? B_ENEMY : B_PROP; }
      if (!boss.phase) {
         if (tt > 40 && tt % 70 == 0)
            for (int i = 0; i < 3; i++) if (boss.a [i] == 0) { boss.a [i] = 1; break; }
         if (acc >= 2) { boss.phase = tt; say ("CHOSEN: THE VALUE IS DECIDED"); }
         else if (rej >= 2) { boss.phase = tt; boss.stun = 180; say ("NO QUORUM: THE BALLOT FAILS"); }
         else if (acc + rej == 3) { boss.phase = tt; say ("NO QUORUM: THE BALLOT FAILS"); boss.stun = 120; }
      } else if (acc >= 2 && tt < boss.phase + 80 && tt % 6 == 0) {
         int x = AX (2 + (int) (rnd () % 36));
         bullet_new (1, (x - 8) << 4, AY (0) << 4, 0, 0, T_ORB, B_BUL);
      }
      if (boss.phase && tt > boss.phase + 200) { boss.cycle++; next_move (4); }
      break;
   } }
   boss.frame = boss.stun ? (t >> 3) & 1 : boss.frame;
   tick ();
}
static int la_other (int x, int y) {
   if (boss.attack == 2 && props [0].on)
      for (int i = 0; i < 4; i++)
         if (shot_near (x, y, props [i].x + 8, props [i].y + 7, 9)) { la_c [i] = la_max () + 1; la_label (i); fx (x, y, T_SPARK); return 1; }
   if (boss.attack == 3 && !boss.phase)
      for (int i = 0; i < 3; i++)
         if (props [i].on && boss.a [i] == 0 && shot_near (x, y, props [i].x + 8, props [i].y + 6, 9)) { boss.a [i] = 2; fx (x, y, T_SPARK); return 1; }
   return 0;
}

// ================================================================ Andrew Appel
static void ap_arena (void) { abrick (8, 14, 20, K_BRICK); abrick (25, 31, 20, K_BRICK); }
static const int ap_cert [3][2] = { { 11, 20 }, { 28, 20 }, { 4, FLOOR } };   // where certificates appear
static const int ap_slot [3][3] = { { 2, 6, 14 }, { 17, 22, 11 }, { 33, 37, 14 } };   // malloc's blocks
static void ap_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (33); boss.y = AY (FLOOR) - 32; }
   switch (boss.attack) {
   case 0:                                                    // foundational proof-carrying code
      if (tt == 0) {
         cue ("PROOF-CARRYING CODE: SHOW ME A PROOF");
         say ("TAKE A #: YOUR NEXT LEMMAS CARRY PROOFS");
         boss.shield = 1;
      }
      for (int k = 0; k < 3; k++) {                            // certificates: a tombstone each
         prop *c = &props [k];
         if (!c->on && tt % 150 == 20 + 40 * k) prop_set (k, AX (ap_cert [k][0]), AY (ap_cert [k][1]) - 16, sfont ('#'), B_BUL2);
         if (c->on && iabs (c->x - pl_x) < 12 && iabs (c->y - pl_y) < 14) { c->on = 0; pl_certs += 3; psnd_cue (); }
      }
      if (tt % 40 == 10) fire_at_player (bcx (), bcy (), 34, T_ORB, B_BUL);
      if (tt > 70 && tt % 90 == 0) {
         int k = bullet_new (1, (bcx () - 8) << 4, boss.y << 4, -24 - (int) (rnd () % 24), -64, T_ORB_M, B_BUL);
         if (k >= 0) bul [k].harm = 5;
      }
      if (tt > 620) next_move (3);
      break;
   case 1:                                                    // step-indexed models
      if (tt == 0) { cue ("STEP-INDEXED MODELS"); say ("A STEP SPENDS THE INDEX. AT 0, NOTHING"); }
      if (tt == 20 || tt == 140 || tt == 260) {
         int vx = (pcx () - bcx ()) * 16 / 70;
         int k = bullet_new (41, (bcx () - 8) << 4, boss.y << 4, vx, -70, digit (4), B_BUL);
         if (k >= 0) { bul [k].a = 4; bul [k].harm = 5; }
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 41) continue;
         b->vy += 3; b->x += b->vx; b->y += b->vy;
         if ((b->x >> 4) < AX (1) || (b->x >> 4) > AX (37)) b->vx = -b->vx;
         if (b->vy > 0 && solid_px ((b->x >> 4) + 8, (b->y >> 4) + 14)) {     // a step
            b->a--; b->tile = digit (b->a); b->vy = -60; b->y -= 4 << 4;
            if (b->a <= 0) { b->on = 0; fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_PUFF); continue; }
            if (b->a >= 2) {                                   // unfold: the recursive type steps too
               int k = bullet_new (41, b->x, b->y, -b->vx - 8, -60, b->tile, B_BUL);
               if (k >= 0) { bul [k].a = b->a; bul [k].harm = 5; }
            }
         }
      }
      if (tt > 420) next_move (3);
      break;
   case 2: {                                                  // VST: no use after free
      if (tt == 0) {
         cue ("VST: NO USE AFTER FREE");
         say ("A FREED BLOCK HAS NO POINTERS LEFT");
         boss.a [0] = 0;                                        // the allocated blocks (a bit each)
      }
      int rt = tt % 140;
      if (tt < 500 && rt == 10) {                              // malloc
         int s = (int) (rnd () % 3);
         if (!(boss.a [0] & (1 << s))) { boss.a [0] |= 1 << s; abrick (ap_slot [s][0], ap_slot [s][1], ap_slot [s][2], K_MARKED); player_bump_up (); note ("MALLOC"); }
      }
      if (tt < 540 && (rt == 40 || rt == 70)) {                // pointers to an allocated block
         for (int s = 0; s < 3; s++)
            if (boss.a [0] & (1 << s)) {
               int k = bullet_new (42, (bcx () - 8) << 4, (boss.y) << 4, 0, 0, T_NODE, B_BUL2);
               if (k >= 0) { bul [k].a = s; bul [k].harm = 4; }
               break;
            }
      }
      if (rt == 100 && boss.a [0]) {                           // free one
         int s = (int) (rnd () % 3);
         while (!(boss.a [0] & (1 << s))) s = (s + 1) % 3;
         boss.a [0] &= ~(1 << s); abrick (ap_slot [s][0], ap_slot [s][1], ap_slot [s][2], K_AIR); note ("FREE");
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 42) continue;
         int s = b->a, tx = AX ((ap_slot [s][0] + ap_slot [s][1]) / 2), ty = AY (ap_slot [s][2]) - 12;
         if (!(boss.a [0] & (1 << s))) { b->on = 0; fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_PUFF); continue; }   // dangling: gone
         int vx, vy; toward ((b->x >> 4) + 8, (b->y >> 4) + 8, tx, ty, 40, &vx, &vy);
         b->x += vx; b->y += vy;
         if (shot_near ((b->x >> 4) + 8, (b->y >> 4) + 8, tx, ty, 6)) {   // the dereference
            b->on = 0;
            for (int d = 0; d < 4; d++) {
               int j = bullet_new (0, (tx - 8) << 4, (ty - 8) << 4, (d & 1 ? 1 : -1) * 28, (d & 2 ? 1 : -1) * 28, T_ORB, B_BUL);
               if (j >= 0) bul [j].harm = 5;
            }
         }
      }
      if (tt == 580) {                                         // free what is left
         for (int s = 0; s < 3; s++) abrick (ap_slot [s][0], ap_slot [s][1], ap_slot [s][2], K_AIR);
         boss.a [0] = 0;
      }
      if (tt > 600) next_move (3);
      break;
   } }
   tick ();
}
static int ap_hits (int x, int y) {
   (void) x; (void) y;
   if (!boss.shield) return 1;
   if (shot_proved) return 1;                                // the checker accepts a proof
   note ("REJECTED: NO PROOF ATTACHED");
   return 0;
}

// ================================================================ Robert Harper
static void ha_arena (void) { abrick (6, 13, 21, K_BRICK); abrick (26, 33, 21, K_BRICK); abrick (16, 23, 15, K_BRICK); }
static const int ha_size_tile [4] = { T_DOT, T_ORB_S, T_ORB_M, T_ORB_L };
static void lf_node (int depth, int idx) {            // a node of the derivation, at its place in the tree
   static const char gl [3] = { 'T', 'P', '#' };
   int k = bullet_new (53, 0, 0, 0, 0, sfont (gl [depth]), B_BUL2);
   if (k < 0) return;
   bul [k].a = depth; bul [k].b = idx; bul [k].harm = 4;
   int half = 64 >> depth;
   bul [k].x = (AX (20) - 8 - 64 + half + 2 * half * idx) << 4;
   bul [k].y = (AY (7) + 22 * depth) << 4;
}
static void ha_update (void) {
   int tt = boss.timer;
   if (boss.a [7] == 0) { boss.a [7] = 1; boss.x = AX (32); boss.y = AY (FLOOR) - 32; }
   switch (boss.attack) {
   case 0:                                                    // progress and preservation
      if (tt == 0) { cue ("PROGRESS AND PRESERVATION"); say ("WELL TYPED: IT STEPS, OR IS A VALUE"); }
      if (tt == 20 || tt == 180) {
         int k = fire_at_player (bcx (), bcy (), 22, T_ORB_L, tt == 20 ? B_BUL : B_BUL2);
         if (k >= 0) { bul [k].kind = 52; bul [k].a = 3; bul [k].harm = 6; }
      }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 52) continue;
         if (b->a > 0) {
            b->x += b->vx; b->y += b->vy;
            if (bullet_solid (b)) { b->x -= b->vx; b->y -= b->vy; b->vy = -b->vy; b->vx = -b->vx; }
            if (b->t % 40 == 39) {                             // a step: smaller, the same type
               b->a--; b->tile = ha_size_tile [b->a];
               if (b->a == 0) { b->harm = 0; b->vx = b->vy = 0; b->c = b->t; }   // a value: done
               else {
                  int k = bullet_new (52, b->x, b->y, -b->vy, b->vx, b->tile, b->bank);
                  if (k >= 0) { bul [k].a = b->a; bul [k].harm = 2 + 2 * b->a; }
                  b->harm = 2 + 2 * b->a;
               }
            }
         } else if (b->t > b->c + 60) b->on = 0;
      }
      if (tt > 420) next_move (4);
      break;
   case 1: {                                                  // LF: judgments as types
      if (tt == 0) {
         cue ("LF: JUDGMENTS AS TYPES");
         say ("A DERIVATION IS A TERM: TAKE IT APART");
         lf_node (0, 0); boss.shield = 1;
      }
      int n = 0;
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 53) continue;
         n++;
         if ((tt + 23 * b->a + 11 * b->b) % 90 == 0) fire_at_player ((b->x >> 4) + 8, (b->y >> 4) + 8, 30, T_ORB, B_BUL);
      }
      if (n == 0 && boss.shield && tt > 1) { boss.shield = 0; boss.stun = 200; note ("CHECKED: THE TERM HAS THE TYPE"); boss.phase = tt; }
      if (tt > 700 && boss.shield) { for (int i = 0; i < NBUL; i++) if (bul [i].kind == 53) bul [i].on = 0; boss.shield = 0; boss.phase = tt; }
      if (boss.phase && tt > boss.phase + 220) next_move (4);
      break;
   }
   case 2: {                                                  // the Definition: typed programs run
      if (tt == 0) { cue ("WELL-TYPED PROGRAMS DO NOT GO WRONG"); say ("THE CHECKER RUNS FIRST: ONLY TYPED RUN"); }
      int rt = tt % 260;
      if (tt < 520 && rt == 10) {
         for (int k = 0; k < 6; k++) {                          // six programs, two at least of each
            int ok = k < 2 ? 1 : k < 4 ? 0 : (int) (rnd () & 1);
            int pos = (k * 5 + boss.cycle) % 6;
            int j = bullet_new (54, (AX (4 + 6 * pos) - 4) << 4, AY (11) << 4, 0, 0, sfont ('?'), B_BUL2);
            if (j >= 0) { bul [j].a = ok; bul [j].b = 0; bul [j].harm = 3; }
         }
         boss.cycle++;
         prop_set (0, AX (1), AY (11), T_LIGHT, B_SHOT);       // the type checker
      }
      if (rt > 10 && rt < 150 && props [0].on) props [0].x = AX (1) + (rt - 10) * 2;
      if (rt == 150) props [0].on = 0;
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 54) continue;
         if (!b->b && props [0].on && props [0].x >= (b->x >> 4)) {       // checked
            if (!b->a) { b->on = 0; fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_PUFF); continue; }   // rejected
            b->b = 1; b->tile = sfont ('T'); b->bank = B_BUL;
         }
         if (b->b && rt >= 160) {                              // only the typed ones run
            if (b->b == 1) { int vx, vy; toward ((b->x >> 4) + 8, (b->y >> 4) + 8, pcx (), pcy (), 30, &vx, &vy); b->vx = vx; b->vy = vy; b->b = 2; b->harm = 5; }
            b->x += b->vx; b->y += b->vy;
            if (bullet_solid (b)) b->on = 0;
         }
      }
      if (tt > 560) next_move (4);
      break;
   }
   case 3: {                                                  // computational trinitarianism
      if (tt == 0) {
         cue ("COMPUTATIONAL TRINITARIANISM");
         say ("LOGIC, TYPES, CATEGORIES: ONE");
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
         int a = tt + 21 * b->a;
         b->x = (bcx () - 8 + (cosv (a) * 44 >> 6)) << 4;
         b->y = (bcy () - 20 + (sinv (a) * 44 >> 6)) << 4;
         if (tt % 80 == 40 + 5 * b->a) fire_at_player ((b->x >> 4) + 8, (b->y >> 4) + 8, 36, T_ORB, B_BUL);
      }
      if (n == 0 && boss.shield) { boss.shield = 0; boss.stun = 200; note ("THEY WERE THE SAME ALL ALONG"); boss.phase = tt; }
      if (tt > 640 && boss.shield) {
         for (int i = 0; i < NBUL; i++) if (bul [i].on && bul [i].kind == 51) bul [i].on = 0;
         boss.shield = 0; boss.phase = tt;
      }
      if (boss.phase && tt > boss.phase + 220) next_move (4);
      break;
   } }
   boss.frame = boss.stun ? (t >> 3) & 1 : boss.frame;
   tick ();
}
static int ha_other (int x, int y) {
   for (int i = 0; i < NBUL; i++) {
      bullet *b = &bul [i];
      if (!b->on) continue;
      if (b->kind == 51 && shot_near (x, y, (b->x >> 4) + 8, (b->y >> 4) + 8, 9)) {
         for (int j = 0; j < NBUL; j++) if (bul [j].on && bul [j].kind == 51) { bul [j].on = 0; fx ((bul [j].x >> 4) + 8, (bul [j].y >> 4) + 8, T_PUFF); }
         return 1;
      }
      if (b->kind == 53 && shot_near (x, y, (b->x >> 4) + 8, (b->y >> 4) + 8, 9)) {   // inversion: its premises
         int d = b->a, idx = b->b;
         b->on = 0; fx ((b->x >> 4) + 8, (b->y >> 4) + 8, T_SPARK);
         if (d < 2) { lf_node (d + 1, 2 * idx); lf_node (d + 1, 2 * idx + 1); }
         return 1;
      }
   }
   return 0;
}

// ================================================================ Adam Chlipala
static void ch_arena (void) { abrick (5, 10, 20, K_BRICK); abrick (29, 34, 20, K_BRICK); abrick (15, 24, 16, K_BRICK); }
// Fiat Cryptography's subject, made small: a number modulo p = 99999 = 10^5 - 1 kept in five
// decimal limbs; additions carry limb to limb, and a carry out of the top limb wraps to the
// bottom one (10^5 = 1 mod p).  ft_spec is the plain number; the limbs always equal it mod p.
#define FT_P 99999
int ft_l [5], ft_spec;
void ft_add (int d) {
   ft_spec = (ft_spec + d) % FT_P;
   ft_l [0] += d;
}
int ft_carry (void) {                                 // one carry; the limb that overflowed, or -1
   for (int i = 0; i < 5; i++)
      if (ft_l [i] > 9) { ft_l [i] -= 10; ft_l [(i + 1) % 5] += 1; return i; }
   return -1;
}
int ft_value (void) { int v = 0; for (int i = 4; i >= 0; i--) v = v * 10 + ft_l [i]; return v; }
// Kami's subject, made small: a 3-stage pipeline whose outputs are the spec's, three steps later
int km_q [3][2], km_v [3];
// one pipeline clock: stage 3 retires (the result: was it valid; *ox, *oy its velocity), the
// stages shift, and (v, vx, vy) enters stage 1
int km_step (int v, int vx, int vy, int *ox, int *oy) {
   int out = km_v [2];
   *ox = km_q [2][0]; *oy = km_q [2][1];
   for (int s = 2; s > 0; s--) { km_q [s][0] = km_q [s - 1][0]; km_q [s][1] = km_q [s - 1][1]; km_v [s] = km_v [s - 1]; }
   km_q [0][0] = vx; km_q [0][1] = vy; km_v [0] = v;
   return out;
}
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
      } else if (tt > 340) { boss.x = AX (32); next_move (4); }
      for (int i = 0; i < NBUL; i++) {
         bullet *b = &bul [i];
         if (!b->on || b->kind != 60) continue;
         b->x += b->vx;
         if (solid_px ((b->x >> 4) + 8 + isgn (b->vx) * 8, (b->y >> 4) + 8)) b->on = 0;
      }
      break;
   }
   case 1: {                                                  // Bedrock: footprints and the frame rule
      if (tt == 0) { cue ("BEDROCK: SEPARATION LOGIC, AUTOMATED"); say ("OUTSIDE THE FOOTPRINT, THE FRAME HOLDS"); }
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
      if (tt > 380) next_move (4);
      break;
   }
   case 2: {                                                  // Fiat Cryptography: carries, proved
      if (tt == 0) {
         cue ("FIAT CRYPTOGRAPHY: MOD 99999");
         say ("CARRIES RIPPLE, THE TOP ONE WRAPS");
         for (int i = 0; i < 5; i++) ft_l [i] = (int) (rnd () % 10);
         ft_spec = ft_value () % FT_P;
      }
      if (tt >= 30 && tt <= 540 && tt % 30 == 0) ft_add (1 + (int) (rnd () % 9));
      if (tt % 6 == 3) {                                       // one carry at a time, each a drop
         int i = ft_carry ();
         if (i >= 0) {
            int k = bullet_new (1, (AX (34 - 7 * i)) << 4, (AY (10) + 8) << 4, 0, 8, T_DROP, B_BUL);
            if (k >= 0) bul [k].harm = 5;
         }
      }
      for (int i = 0; i < 5; i++) prop_set (i, AX (34 - 7 * i), AY (10), digit (ft_l [i] > 9 ? 9 : ft_l [i]), ft_l [i] > 9 ? B_SHOT : B_TEXT);
      if (tt == 580) note (ft_value () % FT_P == ft_spec ? "LIMBS = SPEC, MOD 99999" : "LIMBS DIFFER FROM THE SPEC");
      if (tt % 70 == 40) fire_at_player (bcx (), bcy (), 30, T_ORB, B_BUL);
      if (tt > 640) next_move (4);
      break;
   }
   case 3: {                                                  // Kami: the pipeline refines its spec
      if (tt == 0) {
         cue ("KAMI: A PIPELINE REFINES ITS SPEC");
         say ("THE SPEC'S SHOTS, THREE STAGES LATER");
         for (int s = 0; s < 3; s++) km_v [s] = 0;
      }
      if (tt >= 30 && tt <= 520 && tt % 30 == 0) {
         int vx, vy, ox, oy, spec = tt <= 430;                  // the spec fires; then it stops
         toward (bcx (), bcy (), pcx (), pcy (), 34, &vx, &vy);
         if (spec) bullet_new (0, (bcx () - 8) << 4, (bcy () - 8) << 4, vx, vy, T_ORB, B_BUL);
         if (km_step (spec, vx, vy, &ox, &oy)) {                // the pipeline retires its oldest
            int k = bullet_new (0, (AX (11) - 8) << 4, (AY (12) - 4) << 4, ox, oy, T_ORB, B_BUL2);
            if (k >= 0) bul [k].harm = 5;
         }
      }
      for (int s = 0; s < 3; s++) prop_set (s, AX (3 + 3 * s), AY (12) - 8, digit (s + 1), km_v [s] ? B_SHOT : B_TEXT);
      if (tt > 560) next_move (4);
      break;
   } }
   tick ();
}

const boss_def bosses [7] = {
   { "JOHN MCCARTHY",   "COMPILER PROOFS",    "\\", 0x40A040, 0xC0FF60, 0x102018, mc_arena, mc_update, all_hit, no_other },
   { "EDSGER DIJKSTRA", "WEAKEST PRECONDS",   "*",  0x3060C0, 0xA0D0FF, 0x0C1430, dj_arena, dj_update, open_hits, dj_other },
   { "TONY HOARE",      "HOARE LOGIC, CSP",   "{",  0xC07020, 0xFFD080, 0x201008, ho_arena, ho_update, all_hit, ho_other },
   { "LESLIE LAMPORT",  "TLA+, PAXOS",        "%",  0x7040B0, 0xE0B0FF, 0x140C24, la_arena, la_update, all_hit, la_other },
   { "ANDREW APPEL",    "VERIFIED TOOLCHAIN", "K",  0x208080, 0x80FFF0, 0x081818, ap_arena, ap_update, ap_hits, no_other },
   { "ROBERT HARPER",   "TYPE THEORY",        "&",  0xB03030, 0xFFB0A0, 0x200C0C, ha_arena, ha_update, open_hits, ha_other },
   { "ADAM CHLIPALA",   "CERTIFIED PROGRAMS", "@",  0xB09020, 0xFFF0A0, 0x181408, ch_arena, ch_update, all_hit, no_other } };
