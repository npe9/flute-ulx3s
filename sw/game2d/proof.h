// sw/game2d/proof.h: Proof Obligation (proof.c, proof_boss.c, proof_sound.c), the game2d
// platformer: seven stages, each ending at a boss whose attacks are their ideas.
#ifndef SW_GAME2D_PROOF_H
#define SW_GAME2D_PROOF_H
#include <stdint.h>
void proof_init (void);                 // graphics, palette, sound; video on; the attract demo
int  proof_frame (uint32_t buttons);    // one frame (call in the vertical blank); returns the score
#endif
