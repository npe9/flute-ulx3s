// sw/apu/replay.c: checks a simulated APU against the reference model.  Reads src/Apu.v's
// APU_TRACE log ("W <tick> <offset> <data> <strobes>": a write, applied at that tick; "S <tick>
// <left> <right>": that tick's sample), replays the writes into sw/apu/apu_ref.c tick by tick
// and compares every sample.  With a second file (sw/game2d/host.c's log: "addr data" lines),
// also checks the simulated program wrote exactly the host build's sequence.
//   cc -O2 -o build/apu_replay sw/apu/replay.c sw/apu/apu_ref.c
//   build/apu_replay apu_trace.txt [host.log]
#include "apu.h"
#include <stdio.h>
#include <stdlib.h>

static apu_state s;
#define MAXW 200000
static struct { long t; uint32_t a, d, st; } wq [MAXW];

int main (int argc, char **argv) {
   if (argc < 2) { fprintf (stderr, "usage: %s <trace> [host log]\n", argv [0]); return 2; }
   FILE *f = fopen (argv [1], "r");
   if (!f) { perror (argv [1]); return 1; }
   apu_ref_reset (&s);
   char line [160]; long nw = 0, head = 0, next = 0, ns = 0, loud = 0, bad = 0;
   while (fgets (line, sizeof line, f)) {
      long t; uint32_t a, d, st; int l, r;
      if (sscanf (line, "W %ld %x %x %x", &t, &a, &d, &st) == 4) {
         if (nw == MAXW) { fprintf (stderr, "replay: too many writes\n"); return 1; }
         wq [nw].t = t; wq [nw].a = a; wq [nw].d = d; wq [nw].st = st; nw++;
      } else if (sscanf (line, "S %ld %d %d", &t, &l, &r) == 3) {
         if (t != next) { printf ("replay: FAIL (sample for tick %ld, expected %ld)\n", t, next); return 1; }
         while (head < nw && wq [head].t <= t) {
            if (wq [head].t < t) { printf ("replay: FAIL (a write for tick %ld seen at %ld)\n", wq [head].t, t); return 1; }
            apu_ref_write (&s, APU_BASE + wq [head].a, wq [head].d, wq [head].st); head++;
         }
         int16_t el, er; apu_ref_tick (&s, &el, &er);
         if (el != l || er != r) {
            if (bad++ < 5) printf ("replay: tick %ld: sim %d/%d, model %d/%d\n", t, l, r, el, er);
         }
         if (l || r) loud++;
         ns++; next++;
      }
   }
   printf ("replay: %ld writes, %ld samples (%ld not silent), %ld differ\n", nw, ns, loud, bad);
   int fail = bad != 0 || ns == 0;
   if (argc > 2) {                           // the write sequence against the host build's
      FILE *h = fopen (argv [2], "r");
      if (!h) { perror (argv [2]); return 1; }
      long i = 0, diff = -1;
      while (fgets (line, sizeof line, h)) {
         uint32_t a, d;
         if (line [0] == '#' || sscanf (line, "%x %x", &a, &d) != 2) continue;
         if (diff < 0 && (i >= nw || (a & 0xFFFF) != wq [i].a || d != wq [i].d || wq [i].st != 15)) diff = i;
         i++;
      }
      if (diff < 0 && i != nw) diff = i;
      if (diff >= 0) { printf ("replay: FAIL (the sim wrote %ld, the host %ld; first difference at write %ld)\n", nw, i, diff); fail = 1; }
      else printf ("replay: the %ld writes match the host build's\n", i);
   }
   puts (fail ? "replay: FAIL" : "replay: PASS");
   return fail;
}
