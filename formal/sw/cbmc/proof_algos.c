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
