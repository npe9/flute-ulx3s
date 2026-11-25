// sw/game2d/proof_spec.h: Proof Obligation as a specification (notes/proof-obligation-spec.md).
// The game is specified by what can be observed of it each frame (spec_state) and three
// predicates over observations, independent of how proof.c computes them:
//   spec_init (s)          the state after proof_init
//   spec_inv  (s)          holds after every frame
//   spec_step (s, b, s')   relates the observations before and after one frame with buttons b
// Each returns 0 when the clause holds, or the violated clause ("I4: ...").  The functions are
// pure (no engine state), so the same text is the host oracle (host.c, HOST_SPEC=1: checked on
// every frame of every host run) and the statement CBMC proofs are about.
#ifndef SW_GAME2D_PROOF_SPEC_H
#define SW_GAME2D_PROOF_SPEC_H
#include <stdint.h>

enum { SP_TITLE, SP_PLAY, SP_ARENA, SP_FIGHT, SP_WIN, SP_OVER, SP_END };   // the game's phases
#define SP_BOSSES   7
#define SP_HP       32                // a boss's hit points
#define SP_LASTHP   8                 // the last lemma (move nmoves - 1) only at this HP or less
#define SP_LIVES    5                 // hearts a stage
#define SP_HURT     90                // frames of invulnerability after a hit
#define SP_FLASH    14                // frames a hit boss cannot be hit again
#define SP_MAXDMG   4                 // the most one hit takes (a weakness)
#define SP_CAMLEAD  140               // the camera keeps the player this far from its left edge
#define SP_NSHOT    3
#define SP_NBUL     24
#define SP_NPROP    10
#define SP_NWEAPON  8                 // the lemma and seven bosses' tactics
#define SP_ENERGY   28                // a tactic's full energy
#define SP_REFILL   10                // what an energy pickup gives

typedef struct {
   int state, demo;                   // SP_*; the attract demo is playing
   int cur_boss, defeated;            // the stage's boss; bit b: boss b discharged (not in the demo)
   int lives, dead, hurt;             // hearts; game over pending; invulnerable frames left
   int certs;                         // proof certificates held
   int x, y;                          // the player's sprite, world pixels
   int cam, arena_x, wcols;           // the camera's left edge; the arena's left edge; world columns
   int score;
   unsigned t;                        // frames since power-on
   int boss_on, hp, flash, stun, shield, attack, nmoves;
   int nshots, nbul, nprops;          // live player shots, boss bullets, boss props
   int w_pal, w_map, w_spr, w_reg;    // this frame's flush: palette, map, sprite, register writes
   int vdp_writes;                    // all VDP writes this frame (host.c counts them; -1: unknown)
   // tactics (the weapons won from bosses): tactic b+1 is boss b's; weapon < 0: not observed
   int weapon, owned, energy [SP_NWEAPON];
   int granted;                       // tactics the host test hook adds (0 on the board)
   int hooked;                        // the host test hook forces the move or pins HP (0 on the board)
   int px_agree;                      // Lamport's Paxos: no two values chosen; the learned one is chosen
   unsigned got_hearts, got_energy;   // heart and energy pickups taken since power-on
} spec_state;

void proof_observe (spec_state *s);   // proof.c: fill s from the engine
const char *spec_init (const spec_state *s);
const char *spec_inv (const spec_state *s);
const char *spec_step (const spec_state *s, uint32_t buttons, const spec_state *n);
#endif
