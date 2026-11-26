// formal/sw/cbmc/proof_rules.c: modular proofs of Proof Obligation's specification
// (notes/proof-obligation-spec.md) on the real proof_frame, one clause family at a time.
// formal/sw/cbmc/run_rules.sh builds it with the engine and replaces proof_frame's callees by
// stubs generated from the writer census (gen_stubs.py): a stub havocs everything except the
// family's variables, and calls the family's real writer if the census says the callee may
// reach it.  So the theorem covers every behaviour of every callee the census allows.
//   S3_FRAME  from any state of the whole engine satisfying I4 and I5 for the boss's hit points
//             and flash, one frame (any buttons) satisfies spec_S3 and keeps I4 and I5 for
//             them: the fight starts at 32, the boss never heals, loses 1..4 only when not
//             flashing, a hit starts the flash, and the fight is won exactly at 0 hp
//   S2_FRAME  from any state of the engine with I1 and I2 (0..5 hearts, none exactly when dead,
//             0..90 frames of invulnerability), one frame satisfies spec_S2 and keeps I1 and I2:
//             a stage starts with five hearts, hearts come back only from pickups (one each, up
//             to five), at most one is lost a frame and only when not invulnerable
//   W45_FRAME from any state with W2 (every tactic's energy 0..28) and a valid tactic, one frame
//             satisfies spec_W45 and keeps W2: a stage starts full, firing takes exactly the
//             tactic's cost and only if it is left, energy rises only from pickups
//   HURT_NOOP while invulnerable, player_hurt changes no heart variable (why a stub needs at most
//             one effective call a frame: nothing a stub reaches counts the invulnerability down)
//   BD_NOOP   while the boss flashes, boss_damage changes neither hit points nor flash (why a
//             stub needs at most one call to it a frame: the first effective hit sets the flash,
//             which proof_frame counts down only after every callee has run)
#include "proof.c"
#define feet_kind boss_feet_kind                // the one static name the two files share
#include "proof_boss.c"
#undef feet_kind
#include "proof_spec.c"

int nondet_int (void);
static int nd (int lo, int hi) { int v = nondet_int (); __CPROVER_assume (v >= lo && v <= hi); return v; }
#ifdef VACUITY
#define DONE() __CPROVER_assert (0, "vacuity: the assumptions are satisfiable")
#else
#define DONE()
#endif
#include "stubs.h"                              // generated: havoc_nonrule, stub_* (gen_stubs.py)

#ifdef S3_FRAME
static int i45 (void) {                         // the slice of I4 and I5 this family keeps
   if (boss.flash < 0 || boss.flash >= 14) return 0;
   if (g_state == G_FIGHT && !(boss.on && boss.hp >= 1 && boss.hp <= BOSS_HP)) return 0;
   return 1;
}
int main (void) {
   havoc_nonrule ();                            // any state of the engine at all
   __CPROVER_havoc_object (&boss);
   g_state = nondet_int (); demo = nondet_int (); cur_boss = nd (0, 6); defeated = nondet_int ();
   pl_lives = nondet_int (); pl_dead = nondet_int (); pl_hurt = nondet_int (); pl_certs = nondet_int ();
   score = nondet_int (); pl_weapon = nd (0, NWEAPON - 1); pl_owned = nondet_int (); t = nondet_int ();
   __CPROVER_havoc_object (&pl_energy); got_hearts = nondet_int (); got_energy = nondet_int ();
   // so every global is arbitrary except: g_state is one of the seven phases, cur_boss one of the
   // seven bosses, pl_weapon one of the tactics (the indexes the frame needs in range), and the
   // slice of I4/I5 holds.  Function-local statics (text buffers of the boss moves) are left at
   // their initial values; the moves that own them are all stubbed in S3.
   __CPROVER_assume (g_state >= G_TITLE && g_state <= G_END);
   __CPROVER_assume (i45 ());
   spec_state pre, post;
   proof_observe (&pre);
   uint32_t b = (uint32_t) nondet_int ();
   proof_frame (b);
   proof_observe (&post);
   __CPROVER_assert (spec_S3 (&pre, b, &post) == 0, "S3 holds for this frame");
   __CPROVER_assert (i45 (), "I4 and I5 (hit points, flash) hold again");
   DONE ();
   return 0;
}
#endif
#if defined S2_FRAME || defined HURT_NOOP
static int i12 (void) {                          // I1 and I2
   if (pl_lives < 0 || pl_lives > 5 || (pl_lives == 0) != (pl_dead != 0)) return 0;
   return pl_hurt >= 0 && pl_hurt <= 90;
}
#endif
#ifdef S2_FRAME
int main (void) {
   havoc_nonrule ();
   __CPROVER_havoc_object (&boss); __CPROVER_havoc_object (&pl_energy);
   g_state = nd (G_TITLE, G_END); demo = nondet_int (); cur_boss = nd (0, 6); defeated = nondet_int ();
   pl_lives = nondet_int (); pl_dead = nondet_int (); pl_hurt = nondet_int (); pl_certs = nondet_int ();
   score = nondet_int (); pl_weapon = nd (0, NWEAPON - 1); pl_owned = nondet_int (); t = nondet_int ();
   got_hearts = nondet_int (); got_energy = nondet_int ();
   __CPROVER_assume (i12 ());
   spec_state pre, post;
   proof_observe (&pre);
   uint32_t b = (uint32_t) nondet_int ();
   proof_frame (b);
   proof_observe (&post);
   __CPROVER_assert (spec_S2 (&pre, b, &post) == 0, "S2 holds for this frame");
   __CPROVER_assert (i12 (), "I1 and I2 (hearts, invulnerability) hold again");
   DONE ();
   return 0;
}
#endif
#ifdef W45_FRAME
static int w2 (void) {                           // W2 (energy 0..28) and W1's range (a tactic)
   if (pl_weapon < 0 || pl_weapon >= NWEAPON) return 0;
   for (int w = 0; w < NWEAPON; w++) if (pl_energy [w] < 0 || pl_energy [w] > W_ENERGY) return 0;
   return 1;
}
int main (void) {
   havoc_nonrule ();
   __CPROVER_havoc_object (&boss); __CPROVER_havoc_object (&pl_energy);
   g_state = nd (G_TITLE, G_END); demo = nondet_int (); cur_boss = nd (0, 6); defeated = nondet_int ();
   pl_lives = nondet_int (); pl_dead = nondet_int (); pl_hurt = nondet_int (); pl_certs = nondet_int ();
   score = nondet_int (); pl_weapon = nondet_int (); pl_owned = nondet_int (); t = nondet_int ();
   got_hearts = nondet_int (); got_energy = nondet_int ();
   __CPROVER_assume (w2 ());
   spec_state pre, post;
   proof_observe (&pre);
   uint32_t b = (uint32_t) nondet_int ();
   proof_frame (b);
   proof_observe (&post);
   __CPROVER_assert (spec_W45 (&pre, b, &post) == 0, "W4 and W5 hold for this frame");
   __CPROVER_assert (w2 (), "W2 (energy 0..28) and the tactic range hold again");
   DONE ();
   return 0;
}
#endif
#ifdef HURT_NOOP
int main (void) {
   havoc_nonrule ();
   g_state = nondet_int (); pl_lives = nondet_int (); pl_dead = nondet_int (); pl_hurt = nondet_int ();
   __CPROVER_assume (i12 () && pl_hurt != 0);
   int l = pl_lives, d = pl_dead, h = pl_hurt;
   player_hurt ();
   __CPROVER_assert (pl_lives == l && pl_dead == d && pl_hurt == h, "player_hurt does nothing while invulnerable");
   DONE ();
   return 0;
}
#endif
#ifdef BD_NOOP
int main (void) {
   __CPROVER_havoc_object (&boss); score = nondet_int ();
   __CPROVER_assume (boss.flash != 0);
   int hp = boss.hp, fl = boss.flash;
   boss_damage (nd (1, 4));
   __CPROVER_assert (boss.hp == hp && boss.flash == fl, "boss_damage does nothing to a flashing boss");
   DONE ();
   return 0;
}
#endif
