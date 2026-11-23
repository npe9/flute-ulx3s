// sw/game2d/hw.h: what a game2d title needs from the machine.  board.c implements it on the SoC
// (memory-mapped VDP, video palette, buttons, APU1); host.c implements it on a PC
// against the VDP reference model (sw/vdp/vdp_ref.c), so a title's frames can be predicted
// exactly and compared with the simulated SoC's screen.
#ifndef SW_GAME2D_HW_H
#define SW_GAME2D_HW_H
#include <stdint.h>

// buttons (src/Board_IO.v gpio1 BTN; FIRE1 is the SoC reset, so titles do not use it)
#define BTN_FIRE2 (1u << 2)
#define BTN_UP    (1u << 3)
#define BTN_DOWN  (1u << 4)
#define BTN_LEFT  (1u << 5)
#define BTN_RIGHT (1u << 6)

void     hw_vdp_write (uint32_t addr, uint32_t value);   // a 32-bit VDP register / VRAM write
void     hw_palette (int index, uint32_t rgb);           // video palette entry (0x00RRGGBB)
void     hw_video_on (void);                             // video MODE 4 (the VDP)
void     hw_wait_frame (void);                           // returns at the start of vertical blank
uint32_t hw_buttons (void);
void     hw_apu_write (uint32_t addr, uint32_t value);   // a 32-bit APU1 write (sw/apu/apu.h)
#endif
