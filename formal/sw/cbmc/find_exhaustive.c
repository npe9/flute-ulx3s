// formal/sw/cbmc/find_exhaustive.c: the FIND theorem by exhaustive enumeration, on the game's own
// fd_step (sw/game2d/proof_boss.c, #included as for proof_algos.c).  FIND only compares
// elements, so its run on any 8-element array is its run on the array of the elements' ranks
// (0..7, ties equal); this program runs every rank array (8^8) for every f (8): 134,217,728 runs.
// For each it checks: termination within 75 steps, every index in 0..7 when the array is read
// (phases 0-3 read fd_a [fd_f], fd_a [fd_i], fd_a [fd_j]), a permutation, and the postcondition
// A[0..f-1] <= A[f] <= A[f+1..7].  Exit 0 = the theorem holds; it prints the worst step count.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#ifndef BOSS_SRC
#define BOSS_SRC "../../../sw/game2d/proof_boss.c"
#endif
#include BOSS_SRC
uint8_t kind [ROWS][WMAX];
int wcols, arena_x, pl_x, pl_y, pl_dead, pl_certs, shot_proved, cur_boss;
bullet bul [NBUL];
prop props [NPROP];
boss_t boss;
unsigned t;
int iabs (int v) { return v < 0 ? -v : v; }
int isgn (int v) { return (v > 0) - (v < 0); }

int main (void) {
   long runs = 0, bad = 0; int worst = 0;
   for (uint32_t code = 0; code < (1u << 24); code++) {
      int b [8], cnt [8] = { 0 };
      for (int k = 0; k < 8; k++) { b [k] = (int) (code >> (3 * k)) & 7; cnt [b [k]]++; }
      for (int f = 0; f < 8; f++) {
         memcpy (fd_a, b, sizeof b);
         fd_start (f);
         int s = 0, ok = 1;
         for (;;) {
            if (fd_ph >= 1 && fd_ph <= 3 && (fd_i < 0 || fd_i > 7 || fd_j < 0 || fd_j > 7)) { ok = 0; break; }
            if (!fd_step ()) break;
            if (++s > 75) { ok = 0; break; }
         }
         if (s > worst) worst = s;
         int c2 [8] = { 0 };
         for (int k = 0; k < 8; k++) {
            if (fd_a [k] < 0 || fd_a [k] > 7) { ok = 0; break; }
            c2 [fd_a [k]]++;
            if (k < f && fd_a [k] > fd_a [f]) ok = 0;
            if (k > f && fd_a [k] < fd_a [f]) ok = 0;
         }
         if (ok && memcmp (cnt, c2, sizeof cnt)) ok = 0;
         if (!ok && bad++ < 5) { printf ("FAIL: f=%d A=", f); for (int k = 0; k < 8; k++) printf ("%d", b [k]); printf ("\n"); }
         runs++;
      }
   }
   printf ("FIND exhaustive: %ld runs, worst %d steps, %ld failures\n", runs, worst, bad);
   return bad != 0;
}
