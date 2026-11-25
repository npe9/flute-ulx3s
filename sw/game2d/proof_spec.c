// sw/game2d/proof_spec.c: the clauses of notes/proof-obligation-spec.md as predicates.  The
// clause names (I1, S3, ...) are the notes' numbering; keep the two in step.
#include "proof_spec.h"

#define REQUIRE(c, msg) do { if (!(c)) return msg; } while (0)
static int play (int st) { return st == SP_PLAY || st == SP_ARENA || st == SP_FIGHT; }

const char *spec_init (const spec_state *s) {
   REQUIRE (s->state == SP_PLAY && s->demo, "N1: power-on starts the attract demo in a stage");
   REQUIRE (s->lives == SP_LIVES && !s->dead && s->hurt == 0, "N2: with full hearts");
   REQUIRE (s->score == 0 && s->defeated == 0 && s->t == 0, "N3: score 0, nothing discharged");
   return 0;
}

const char *spec_inv (const spec_state *s) {
   REQUIRE (s->state >= SP_TITLE && s->state <= SP_END, "I0: a known phase");
   REQUIRE (s->lives >= 0 && s->lives <= SP_LIVES, "I1: 0..5 hearts");
   REQUIRE ((s->lives == 0) == (s->dead != 0), "I1: no hearts is exactly game over");
   REQUIRE (s->hurt >= 0 && s->hurt <= SP_HURT, "I2: invulnerability 0..90 frames");
   REQUIRE (s->cur_boss >= 0 && s->cur_boss < SP_BOSSES, "I3: one of seven bosses");
   REQUIRE ((s->defeated & ~0x7F) == 0, "I3: only seven bosses can be discharged");
   if (s->state == SP_FIGHT) {
      REQUIRE (s->boss_on && s->hp > 0 && s->hp <= SP_HP, "I4: a fight has a live boss, 1..32 hp");
      REQUIRE (s->attack >= 0 && s->attack < s->nmoves, "I4: the boss runs one of its moves");
      REQUIRE (s->cam == s->arena_x, "I4: the fight's screen is the arena");
      REQUIRE (s->attack < s->nmoves - 1 || s->hp <= SP_LASTHP || s->hooked, "I9: the last lemma only at a quarter HP");
   }
   REQUIRE (s->flash >= 0 && s->flash < SP_FLASH && s->stun >= 0, "I5: hit flash and stun in range");
   if (play (s->state)) {
      REQUIRE (s->cam >= 0 && s->cam <= s->arena_x, "I6: the camera stays in the world");
      REQUIRE (s->x >= s->cam && s->x <= 8 * s->wcols - 16, "I6: the player is on screen, in the world");
   }
   REQUIRE (s->px_agree, "A6: Paxos never chooses two values, and learns only a chosen one");
   REQUIRE (s->certs >= 0, "I7: certificates are counted");
   REQUIRE (s->nshots <= SP_NSHOT && s->nbul <= SP_NBUL && s->nprops <= SP_NPROP, "I7: object tables");
   REQUIRE (s->score >= 0, "I8: score is not negative");
   REQUIRE (s->w_pal <= 256 && s->w_map <= 640 && s->w_spr <= 128 && s->w_reg <= 2, "V2: the flush's writes are bounded");
   if (s->vdp_writes >= 0)
      REQUIRE (s->vdp_writes == s->w_pal + s->w_map + s->w_spr + s->w_reg, "V2: every VDP write is the flush's");
   if (s->weapon >= 0) {
      REQUIRE (s->weapon < SP_NWEAPON && (s->owned & (1 << s->weapon)), "W1: the selected tactic is owned");
      REQUIRE (s->owned & 1, "W1: the lemma is always owned");
      for (int w = 0; w < SP_NWEAPON; w++) REQUIRE (s->energy [w] >= 0 && s->energy [w] <= SP_ENERGY, "W2: energy 0..28");
      int want = s->demo ? (1 << SP_NWEAPON) - 1 : 1 | (s->defeated << 1);
      REQUIRE (s->owned == (want | s->granted), "W3: a tactic is owned exactly when its boss is discharged (all in the demo)");
   }
   return 0;
}

// the phase graph: from -> to, outside the demo's exits (S1)
static int edge (int a, int b, const spec_state *s, const spec_state *n) {
   if (a == b) return 1;
   switch (a) {
   case SP_TITLE: return b == SP_PLAY;
   case SP_PLAY:  return b == SP_ARENA || b == SP_OVER;
   case SP_ARENA: return b == SP_FIGHT || b == SP_OVER;
   case SP_FIGHT: return b == SP_WIN || b == SP_OVER;
   case SP_WIN:   return b == SP_TITLE || (b == SP_END && !s->demo && n->defeated == 0x7F);
   case SP_OVER:  return b == SP_TITLE;
   case SP_END:   return b == SP_TITLE;
   }
   return 0;
}

// spec_step's clauses, one function each (the modular proofs, formal/sw/cbmc/proof_rules.c,
// prove them one at a time; spec_step is their conjunction)
const char *spec_S0 (const spec_state *s, uint32_t buttons, const spec_state *n) {
   (void) buttons;
   REQUIRE (n->t == s->t + 1, "S0: one frame passes");
   return 0;
}
const char *spec_S1 (const spec_state *s, uint32_t buttons, const spec_state *n) {
   (void) buttons;
   // S1: phases change only along the graph; the demo may also be left for the title at any time
   // (a button, or its time limit)
   int demo_exit = s->demo && n->state == SP_TITLE;
   REQUIRE (edge (s->state, n->state, s, n) || demo_exit, "S1: a phase change along the graph");
   REQUIRE (!(s->demo && buttons) || !n->demo, "S1: a button ends the demo");
   return 0;
}
const char *spec_S2 (const spec_state *s, uint32_t buttons, const spec_state *n) {
   (void) buttons;
   int entered = s->state == SP_TITLE && n->state == SP_PLAY;
   // S2: hearts: a stage starts with five; otherwise at most one is lost a frame, only when not
   // invulnerable, and losing one starts the invulnerable time
   if (entered) REQUIRE (n->lives == SP_LIVES && !n->dead && n->hurt == 0 && n->certs == 0, "S2: a stage starts with five hearts");
   else {
      unsigned heal = n->got_hearts - s->got_hearts;      // a heart pickup restores one, up to five
      REQUIRE (heal <= 1, "S2: at most one heart pickup a frame");
      int up = s->lives < SP_LIVES ? (int) heal : 0;     // at five hearts a pickup is points only
      REQUIRE (n->lives <= s->lives + up, "S2: hearts are gained only from a pickup");
      REQUIRE (n->lives >= s->lives + up - 1, "S2: at most one heart lost a frame");
      if (n->lives < s->lives + up)
         REQUIRE (s->hurt <= 1 && n->hurt >= SP_HURT - 1, "S2: a heart is lost only when not invulnerable");
      REQUIRE (n->hurt >= s->hurt - 1 || n->hurt >= SP_HURT - 1, "S2: invulnerability counts down one a frame");
   }
   return 0;
}
const char *spec_S3 (const spec_state *s, uint32_t buttons, const spec_state *n) {
   (void) buttons;
   // S3: the boss: full at the fight's start; then hit points only fall, by 1..4, when it is not
   // flashing, and a hit starts the flash
   if (s->state == SP_ARENA && n->state == SP_FIGHT) REQUIRE ((n->hp == SP_HP || n->hooked) && n->flash == 0, "S3: a fight starts at 32 hp");
   if (s->state == SP_FIGHT && (n->state == SP_FIGHT || n->state == SP_WIN)) {
      REQUIRE (n->hp <= s->hp, "S3: a boss never heals");
      if (n->hp < s->hp)
         REQUIRE (s->flash == 0 && s->hp - n->hp <= SP_MAXDMG && n->flash == SP_FLASH - 1, "S3: one hit of 1..4 when not flashing");
      REQUIRE ((n->state == SP_WIN) == (n->hp <= 0), "S3: the fight is won exactly when the boss has no hp");
   }
   return 0;
}
const char *spec_S4 (const spec_state *s, uint32_t buttons, const spec_state *n) {
   (void) buttons;
   // S4: discharged bosses: only a real (not demo) win adds one, the ending's restart clears all
   if (n->defeated != s->defeated) {
      int won = s->state == SP_FIGHT && n->state == SP_WIN && !s->demo && n->defeated == (s->defeated | (1 << s->cur_boss));
      int restart = s->state == SP_END && n->state == SP_TITLE && n->defeated == 0;
      REQUIRE (won || restart, "S4: only a win discharges a boss");
   }
   if (s->state == SP_FIGHT && n->state == SP_WIN && !s->demo) REQUIRE (n->defeated & (1 << s->cur_boss), "S4: a win discharges its boss");
   return 0;
}
const char *spec_S5 (const spec_state *s, uint32_t buttons, const spec_state *n) {
   (void) buttons;
   // S5: score only grows
   REQUIRE (n->score >= s->score, "S5: the score never falls");
   return 0;
}
const char *spec_S6 (const spec_state *s, uint32_t buttons, const spec_state *n) {
   (void) buttons;
   // S6: the camera: in a stage it follows the player, in the fight it is still
   if (s->state == SP_PLAY && n->state == SP_PLAY) {
      int want = n->x - SP_CAMLEAD;
      want = want < 0 ? 0 : want > n->arena_x ? n->arena_x : want;
      REQUIRE (n->cam == want, "S6: the camera follows the player");
   }
   if (s->state == SP_FIGHT && n->state == SP_FIGHT) REQUIRE (n->cam == s->cam, "S6: the arena does not scroll");
   return 0;
}
const char *spec_W45 (const spec_state *s, uint32_t buttons, const spec_state *n) {
   (void) buttons;
   int entered = s->state == SP_TITLE && n->state == SP_PLAY;
   // W4, W5: energy.  A stage starts with every tactic full; otherwise a tactic's energy falls
   // only by firing it (exactly its cost, and only if that much was left) and rises only from an
   // energy pickup (at most 10, one tactic)
   if (s->weapon >= 0 && n->weapon >= 0) {
      static const int cost [SP_NWEAPON] = { 0, 1, 2, 4, 7, 2, 1, 3 };
      if (entered) {
         for (int w = 0; w < SP_NWEAPON; w++) REQUIRE (n->energy [w] == SP_ENERGY, "W4: a stage starts with every tactic full");
      } else {
         unsigned got = n->got_energy - s->got_energy;
         int rose = 0;
         REQUIRE (got <= 1, "W5: at most one energy pickup a frame");
         for (int w = 0; w < SP_NWEAPON; w++) {
            int d = n->energy [w] - s->energy [w];
            if (d < 0) REQUIRE ((w == s->weapon || w == n->weapon) && d == -cost [w] && s->energy [w] >= cost [w],
                                "W4: firing a tactic takes exactly its cost, only if it is left");
            if (d > 0) { REQUIRE (got && d <= SP_REFILL, "W5: energy rises only from a pickup, by at most 10"); rose++; }
         }
         REQUIRE (rose <= 1, "W5: a pickup refills one tactic");
      }
   }
   return 0;
}

const char *spec_step (const spec_state *s, uint32_t buttons, const spec_state *n) {
   const char *(*const clause []) (const spec_state *, uint32_t, const spec_state *) =
      { spec_S0, spec_S1, spec_S2, spec_S3, spec_S4, spec_S5, spec_S6, spec_W45 };
   for (unsigned k = 0; k < sizeof clause / sizeof clause [0]; k++) {
      const char *e = clause [k] (s, buttons, n);
      if (e) return e;
   }
   return 0;
}
