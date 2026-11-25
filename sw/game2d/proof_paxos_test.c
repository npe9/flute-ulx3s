// sw/game2d/proof_paxos_test.c: random-schedule test of the px_* Paxos steps of proof_boss.c (any order,
// loss and duplication of messages); checks agreement after every step.  Tested, not proved.
#include <stdio.h>
#include <stdlib.h>
#include "px_ext.c"                    // the px_* block of proof_boss.c, extracted by proof_paxos_test.sh
typedef struct { int type, to, b, v, pb, pv, src; } msg;
static msg net [4096]; static int nn;
static uint32_t s = 1;
static uint32_t r (void) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
static void put (msg m) { if (nn < 4096) net [nn++] = m; }
int main (int argc, char **argv) {
   long runs = argc > 1 ? atol (argv [1]) : 1000000, chosen [3] = { 0 }, learned = 0;
   for (long run = 0; run < runs; run++) {
      px_init (1, 2); nn = 0; int round [2] = { 0, 0 };
      for (int step = 0; step < 120; step++) {
         int k = (int) (r () % 10);
         if (k == 0 || nn == 0) {                       // a proposer starts its next ballot
            int p = (int) (r () & 1), b = 2 * round [p] + 1 + p;
            if (px_start (p, b)) { round [p]++; for (int a = 0; a < PX_A; a++) put ((msg) { 1, a, b, 0, 0, 0, p }); }
            continue;
         }
         int i = (int) (r () % (uint32_t) nn); msg m = net [i];
         if (r () % 4) net [i] = net [--nn];           // else duplicated: it stays
         if (r () % 8 == 0) continue;                  // lost
         int pb, pv;
         if (m.type == 1 && px_prepare (m.to, m.b, &pb, &pv)) put ((msg) { 2, m.src, m.b, 0, pb, pv, m.to });
         if (m.type == 2 && px_promise (m.to, m.src, m.b, m.pb, m.pv))
            for (int a = 0; a < PX_A; a++) put ((msg) { 3, a, m.b, px_pval [m.to], 0, 0, m.to });
         if (m.type == 3 && px_accept (m.to, m.b, m.v)) put ((msg) { 4, 0, m.b, m.v, 0, 0, m.to });
         if (m.type == 4) px_accepted (m.src, m.b, m.v);
         if (px_chosen (1) && px_chosen (2)) { printf ("AGREEMENT VIOLATED: run %ld step %d\n", run, step); return 1; }
         if (px_learned && !px_chosen (px_learned)) { printf ("LEARNED UNCHOSEN: run %ld step %d\n", run, step); return 1; }
      }
      chosen [1] += px_chosen (1); chosen [2] += px_chosen (2); learned += px_learned != 0;
   }
   printf ("%ld schedules: agreement held; value 1 chosen in %ld, value 2 in %ld, learned in %ld\n", runs, chosen [1], chosen [2], learned);
   return 0;
}
