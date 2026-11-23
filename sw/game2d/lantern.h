// sw/game2d/lantern.h: Lantern Drift (lantern.c), the game2d demo title.
#ifndef SW_GAME2D_LANTERN_H
#define SW_GAME2D_LANTERN_H
#include <stdint.h>
void lantern_init (void);                 // graphics, map, palette, sound; video on; attract mode
int  lantern_frame (uint32_t buttons);    // one frame (call in the vertical blank); returns the score
#endif
