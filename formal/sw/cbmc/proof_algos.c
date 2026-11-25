// formal/sw/cbmc/proof_algos.c: tier 2 for Proof Obligation's boss algorithms.  CBMC proves,
// over every input in the stated domain, a theorem about each algorithm the game actually runs:
// the functions are compiled from sw/game2d/proof_boss.c itself (#included below), not a copy.
// One theorem per -D (formal/sw/cbmc/run_proof.sh runs them all):
//   COMPILER        McCarthy-Painter: for every expression of the game's two shapes with
//                   digit operands 1..9 (the game uses 1..3) and operators +, *, the compiled
//                   stack code run to the end leaves exactly one value, never overflows the
//                   3-deep stack, and that value equals the expression's meaning (mc_eval)
//   KSTATE_LIVE     Dijkstra's K-state ring (N=5, K=6): in every state some machine is privileged
//   KSTATE_CLOSED   ... one privilege stays one privilege after its move, and values stay < K
//   KSTATE_CONVERGE ... from every state, under every central-daemon schedule, at most 24 moves
//                   reach a state with exactly one privilege (24 is the exact worst case,
//                   build/swfv/bounds; with CLOSED, it is then one privilege for ever)
//   (FIND is proved by exhaustive enumeration instead: find_exhaustive.c; CBMC on 8 symbolic
//   elements and 75 unrolled steps did not finish in 5 hours)
//   FIAT            the limbs equal the spec modulo 99999 is inductive over ft_add and ft_carry
//                   (limbs 0..99, any spec in [0, p))
//   KAMI            the pipeline's state is the last three inputs (inductive), so every output
//                   is the spec's input of three steps before, for runs of any length
//   PAXOS_INIT, PAXOS_STEP, PAXOS_AGREE   Lamport's single-decree Paxos: an inductive invariant
//                   (px_inv) holds initially, is kept by every step, and implies agreement, so
//                   no two values are ever chosen and the learner learns only a chosen value,
//                   for every schedule of any length with messages reordered, duplicated or lost
#include <stdint.h>
#include <string.h>
#ifndef BOSS_SRC                        // run_proof_mutants.sh compiles a mutated copy instead
#define BOSS_SRC "../../../sw/game2d/proof_boss.c"
#endif
#include BOSS_SRC

// the engine's state proof_boss.c refers to (none of it is read by the functions proved here)
uint8_t kind [ROWS][WMAX];
int wcols, arena_x, pl_x, pl_y, pl_dead, pl_certs, shot_proved, cur_boss;
bullet bul [NBUL];
prop props [NPROP];
boss_t boss;
unsigned t;
int iabs (int v) { return v < 0 ? -v : v; }
int isgn (int v) { return (v > 0) - (v < 0); }

int nondet_int (void);
#ifdef VACUITY                          // run_proof.sh: the end of main must be reachable
#define DONE() __CPROVER_assert (0, "vacuity: the assumptions are satisfiable")
#else
#define DONE()
#endif

#ifdef COMPILER
int main (void) {
   mc_form = nondet_int (); __CPROVER_assume (mc_form == 0 || mc_form == 1);
   mc_a = nondet_int (); mc_b = nondet_int (); mc_c = nondet_int ();
   __CPROVER_assume (mc_a >= 1 && mc_a <= 9 && mc_b >= 1 && mc_b <= 9 && mc_c >= 1 && mc_c <= 9);
   mc_o1 = nondet_int (); mc_o2 = nondet_int ();
   __CPROVER_assume ((mc_o1 == OP_ADD || mc_o1 == OP_MUL) && (mc_o2 == OP_ADD || mc_o2 == OP_MUL));
   int v = mc_eval ();
   mc_compile ();
   for (int k = 0; k < 5; k++) {
      int op = mc_code [mc_pc];
      if (op > 0) __CPROVER_assert (mc_sp < 3, "a PUSH never overflows the stack");
      else __CPROVER_assert (mc_sp >= 2, "an operator always has two operands");
      __CPROVER_assert (mc_step () == 1, "the code runs five instructions");
   }
   __CPROVER_assert (mc_step () == 0, "then it is done");
   __CPROVER_assert (mc_sp == 1, "exactly one value is left");
   __CPROVER_assert (mc_st [0] == v, "compiled = evaluated");
   DONE ();
   return 0;
}
#endif

#if defined KSTATE_LIVE || defined KSTATE_CLOSED || defined KSTATE_CONVERGE
static void any_state (void) {
   for (int i = 0; i < SS_N; i++) { ss_x [i] = nondet_int (); __CPROVER_assume (ss_x [i] >= 0 && ss_x [i] < SS_K); }
}
static int any_privileged (void) {      // the daemon's choice
   int i = nondet_int (); __CPROVER_assume (i >= 0 && i < SS_N && ss_priv (i)); return i;
}
#endif
#ifdef KSTATE_LIVE
int main (void) { any_state (); __CPROVER_assert (ss_count () >= 1, "no deadlock: some machine is privileged"); DONE (); return 0; }
#endif
#ifdef KSTATE_CLOSED
int main (void) {
   any_state ();
   __CPROVER_assume (ss_count () == 1);
   ss_move (any_privileged ());
   for (int i = 0; i < SS_N; i++) __CPROVER_assert (ss_x [i] >= 0 && ss_x [i] < SS_K, "values stay in 0..K-1");
   __CPROVER_assert (ss_count () == 1, "closure: one privilege stays one");
   DONE ();
   return 0;
}
#endif
#ifdef KSTATE_CONVERGE
int main (void) {
   any_state ();
   for (int k = 0; k < 24 && ss_count () > 1; k++) ss_move (any_privileged ());
   __CPROVER_assert (ss_count () == 1, "convergence within 24 moves");
   DONE ();
   return 0;
}
#endif


#ifdef FIAT
static int modp (int v) { return ((v % FT_P) + FT_P) % FT_P; }
int main (void) {
   for (int i = 0; i < 5; i++) { ft_l [i] = nondet_int (); __CPROVER_assume (ft_l [i] >= 0 && ft_l [i] <= 99); }
   ft_spec = nondet_int (); __CPROVER_assume (ft_spec >= 0 && ft_spec < FT_P);
   __CPROVER_assume (modp (ft_value ()) == ft_spec);          // the invariant, assumed
   if (nondet_int ()) { int d = nondet_int (); __CPROVER_assume (d >= 1 && d <= 9 && ft_l [0] + d <= 99); ft_add (d); }
   else ft_carry ();
   __CPROVER_assert (ft_spec >= 0 && ft_spec < FT_P, "the spec stays reduced");
   __CPROVER_assert (modp (ft_value ()) == ft_spec, "limbs = spec mod 99999, after either step");
   DONE ();
   return 0;
}
#endif

#ifdef KAMI
int main (void) {
   int h [3][3];                          // the spec's last three inputs (valid, vx, vy), newest first
   for (int s = 0; s < 3; s++) {
      for (int k = 0; k < 3; k++) h [s][k] = nondet_int ();
      km_v [s] = h [s][0]; km_q [s][0] = h [s][1]; km_q [s][1] = h [s][2];   // the invariant, assumed
   }
   int v = nondet_int (), vx = nondet_int (), vy = nondet_int (), ox, oy;
   int out = km_step (v, vx, vy, &ox, &oy);
   __CPROVER_assert (out == h [2][0], "the output's validity is the input's of three steps before");
   if (out) __CPROVER_assert (ox == h [2][1] && oy == h [2][2], "and so is its velocity");
   int n [3][3] = { { v, vx, vy }, { h [0][0], h [0][1], h [0][2] }, { h [1][0], h [1][1], h [1][2] } };
   for (int s = 0; s < 3; s++)
      __CPROVER_assert (km_v [s] == n [s][0] && km_q [s][0] == n [s][1] && km_q [s][1] == n [s][2], "the invariant holds again");
   DONE ();
   return 0;
}
#endif

// ---- Lamport's single-decree Paxos (px_* in proof_boss.c): agreement for every schedule.
//   PAXOS_INIT   px_init leaves a state satisfying the invariant px_inv below
//   PAXOS_STEP   px_inv is inductive: from ANY state satisfying it, any one step keeps it
//   PAXOS_AGREE  px_inv implies agreement: no two values are chosen, the learner learns only a
//                chosen value
// So agreement holds in every reachable state, after any number of steps.  The network is the
// set of every message ever sent (ghost state g_*): a step delivers any of them, any number of
// times, in any order, or never, which is reordering, duplication and loss at once.  Prepare
// messages may even be forged (any ballot, any acceptor), and an Accepted message is anything:
// px_accepted checks the vote itself.  The precondition (the game's): Promise and Accept messages
// are the ones px_prepare and px_promise produced.  Values are 1..3, own values any of them.
#if defined PAXOS_INIT || defined PAXOS_STEP || defined PAXOS_AGREE
#define PX_V 3
static int g_ps [PX_A][PX_B], g_ppb [PX_A][PX_B], g_ppv [PX_A][PX_B];   // Promise(b, pb, pv) sent by a
static int g_as [PX_B];                                                  // Accept(b, v) sent: v, 0 none
static int owner (int b) { return (b - 1) % 2; }
static int pop3 (int m) { return (m & 1) + ((m >> 1) & 1) + ((m >> 2) & 1); }
static int px_inv (void) {
   for (int a = 0; a < PX_A; a++) {                     // acceptors: votes, highest vote, promise
      if (px_prom [a] < 0 || px_prom [a] >= PX_B || px_abal [a] < 0 || px_abal [a] > px_prom [a]) return 0;
      if (px_vote [a][0] != 0) return 0;
      for (int b = 1; b < PX_B; b++) {
         int v = px_vote [a][b];
         if (v < 0 || v > PX_V) return 0;
         if (b > px_abal [a] && v != 0) return 0;
         if (v != 0 && g_as [b] != v) return 0;         // a vote is for the value proposed in b
      }
      if (px_abal [a] == 0 ? px_aval [a] != 0 : (px_aval [a] < 1 || px_vote [a][px_abal [a]] != px_aval [a])) return 0;
      if (px_lbal [a] < 0 || px_lbal [a] >= PX_B) return 0;   // the learner's record of a
      if (px_lbal [a] == 0 ? px_lval [a] != 0 : (px_lval [a] < 1 || px_vote [a][px_lbal [a]] != px_lval [a])) return 0;
      for (int b = 0; b < PX_B; b++) {                  // a promise a sent reports its highest vote below b
         if (b == 0) { if (g_ps [a][0]) return 0; continue; }
         if (!g_ps [a][b]) continue;
         int pb = g_ppb [a][b], pv = g_ppv [a][b];
         if (px_prom [a] < b || pb < 0 || pb >= b) return 0;
         if (pb == 0 ? pv != 0 : (pv < 1 || px_vote [a][pb] != pv)) return 0;
         for (int c = pb + 1; c < b; c++) if (px_vote [a][c] != 0) return 0;
      }
   }
   if (g_as [0] != 0) return 0;
   for (int b = 1; b < PX_B; b++) {                     // a proposed value is safe at its ballot
      int v = g_as [b];
      if (v < 0 || v > PX_V) return 0;
      if (v == 0) continue;
      int p = owner (b);
      if (px_pbal [p] < b || (px_pbal [p] == b && (px_pph [p] != 2 || px_pval [p] != v))) return 0;
      for (int c = 1; c < b; c++) {                     // SafeAt: some quorum did or will vote v in c
         int ok [PX_A];
         for (int a = 0; a < PX_A; a++) ok [a] = px_vote [a][c] == v || (px_vote [a][c] == 0 && px_prom [a] > c);
         if (ok [0] + ok [1] + ok [2] < 2) return 0;
      }
   }
   for (int p = 0; p < 2; p++) {                        // proposers
      int b = px_pbal [p];
      if (px_own [p] < 1 || px_own [p] > PX_V || b < 0 || b >= PX_B) return 0;
      if ((b == 0) != (px_pph [p] == 0) || px_pph [p] < 0 || px_pph [p] > 2) return 0;
      for (int c = b + 1; c < PX_B; c++) if (owner (c) == p && g_as [c] != 0) return 0;   // nothing proposed ahead
      if (b == 0) { if (px_pset [p] || px_phb [p] || px_pval [p]) return 0; continue; }
      if (owner (b) != p || px_pset [p] < 0 || px_pset [p] > 7) return 0;
      if (px_pph [p] == 1 && (pop3 (px_pset [p]) >= 2 || g_as [b] != 0)) return 0;
      if (px_pph [p] == 2 && (pop3 (px_pset [p]) < 2 || g_as [b] != px_pval [p])) return 0;
      int hb = 0, hit = 0;                              // phb, pval: the highest vote reported so far
      for (int a = 0; a < PX_A; a++)
         if ((px_pset [p] >> a) & 1) {
            if (!g_ps [a][b]) return 0;
            if (g_ppb [a][b] > hb) hb = g_ppb [a][b];
         }
      if (px_phb [p] != hb) return 0;
      if (hb == 0) { if (px_pval [p] != px_own [p]) return 0; }
      else {
         for (int a = 0; a < PX_A; a++) hit |= ((px_pset [p] >> a) & 1) && g_ppb [a][b] == hb && g_ppv [a][b] == px_pval [p];
         if (!hit) return 0;
      }
   }
   if (px_learned < 0 || px_learned > PX_V || (px_learned && !px_chosen (px_learned))) return 0;
   return 1;
}
static int nd (int lo, int hi) { int v = nondet_int (); __CPROVER_assume (v >= lo && v <= hi); return v; }
static void any_px_state (void) {                       // any state at all, then: it satisfies px_inv
   for (int a = 0; a < PX_A; a++) {
      px_prom [a] = nondet_int (); px_abal [a] = nondet_int (); px_aval [a] = nondet_int ();
      px_lbal [a] = nondet_int (); px_lval [a] = nondet_int ();
      for (int b = 0; b < PX_B; b++) { px_vote [a][b] = nondet_int (); g_ps [a][b] = nd (0, 1); g_ppb [a][b] = nondet_int (); g_ppv [a][b] = nondet_int (); }
   }
   for (int b = 0; b < PX_B; b++) g_as [b] = nondet_int ();
   for (int p = 0; p < 2; p++) {
      px_own [p] = nondet_int (); px_pbal [p] = nondet_int (); px_pval [p] = nondet_int ();
      px_pph [p] = nondet_int (); px_pset [p] = nondet_int (); px_phb [p] = nondet_int ();
   }
   px_learned = nondet_int ();
   __CPROVER_assume (px_inv ());
}
#endif
#ifdef PAXOS_INIT
int main (void) {
   int v0 = nd (1, PX_V), v1 = nd (1, PX_V);
   px_init (v0, v1);                                    // the ghosts start empty (static)
   __CPROVER_assert (px_inv (), "px_init satisfies the invariant");
   DONE ();
   return 0;
}
#endif
#ifdef PAXOS_STEP
int main (void) {
   any_px_state ();
   int a = nd (0, PX_A - 1), p = nd (0, 1), b = nd (0, PX_B - 1), v = nd (0, PX_V), pb, pv;
   switch (nd (0, 4)) {
   case 0: px_start (nd (-1, 2), nd (-1, PX_B)); break;              // any start, enabled or not
   case 1:                                                            // Prepare(b) to a: forgeable
      if (px_prepare (a, b, &pb, &pv)) { g_ps [a][b] = 1; g_ppb [a][b] = pb; g_ppv [a][b] = pv; }
      break;
   case 2:                                                            // a Promise a sent, to p
      __CPROVER_assume (g_ps [a][b]);
      if (px_promise (p, a, b, g_ppb [a][b], g_ppv [a][b])) g_as [b] = px_pval [p];   // Accept(b, pval) to all
      break;
   case 3:                                                            // an Accept that was sent, to a
      __CPROVER_assume (g_as [b] != 0);
      px_accept (a, b, g_as [b]);                                     // Accepted(b, v) goes out
      break;
   case 4: px_accepted (a, b, v); break;                              // any Accepted at all
   }
   __CPROVER_assert (px_inv (), "every step keeps the invariant");
   DONE ();
   return 0;
}
#endif
#ifdef PAXOS_AGREE
int main (void) {
   any_px_state ();
   int v = nd (1, PX_V), w = nd (1, PX_V);
   __CPROVER_assume (v != w);
   __CPROVER_assert (!(px_chosen (v) && px_chosen (w)), "agreement: no two values are chosen");
   __CPROVER_assert (px_learned == 0 || px_chosen (px_learned), "the learner learns only a chosen value");
   DONE ();
   return 0;
}
#endif
