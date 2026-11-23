// sw/vdp/vdp.h: the VDP1 tile-and-sprite engine (src/Vdp.v): register map, the C reference model
// (vdp_ref.c, the definition the RTL is compared against frame by frame), and bare-metal helpers.
//
// Picture: 320x240, shown through the video block's MODE 4 (src/Video_DVI.v), each pixel doubled
// to 640x480; colours come from the video palette (0xC001_0400, 256 x 0x00RRGGBB).
//
// Layers, back to front: BACKDROP (one palette index), the background (BG) tile layer, sprites.
// A colour index of 0 within a tile or sprite (nibble 0) is transparent.
//
// BG: a 64 x 32 map of 8x8 tiles (a 512 x 256 pixel plane, wrapping both ways), scrolled by
// BG_SCROLL: screen pixel (x, y) shows plane pixel ((x + SX) mod 512, (y + SY) mod 256).
//   Map entry (16 bits): [9:0] tile, [13:10] palette bank, [14] hflip, [15] vflip.
//   Pattern RAM: 1024 tiles of 8x8 at 4 bits per pixel, 32 bytes per tile, row r in the 32-bit
//   word 8 * tile + r, the left pixel in bits [3:0].  Pixel nibble n of bank b is palette index
//   16 * b + n.
// Sprites: 64 entries of two 32-bit words, 16x16 pixels from four consecutive tiles t, t+1 (top
//   left, top right), t+2, t+3 (bottom left, bottom right), before flipping.
//   word 0: [8:0] X, [24:16] Y: the sprite covers screen columns (X + i) mod 512 and rows
//           (Y + j) mod 512, i, j in 0..15 (so X = 505 shows the right 9 columns at x = 0..8).
//   word 1: [9:0] tile, [13:10] palette bank, [14] hflip, [15] vflip, [16] enable,
//           [17] behind: its pixels show only where the BG pixel is transparent.
//   Per line, the first 16 enabled sprites (lowest index first) covering it are drawn; more set
//   STATUS.OVERFLOW.  They are drawn highest index first, each opaque pixel replacing what is
//   there (a behind sprite only over a transparent BG pixel), so the lowest index ends on top.
//
// Register writes take effect at the next line rendered (the VDP renders line y + 1 while line
// y is on screen; line 0 during the vertical blank).  Exactly: CTRL, BG_SCROLL and BACKDROP are
// copied for line L at pixel clock 784 of scanline 2L - 3 (line 0: scanline 522, line 1: 524),
// so a write completed before then shows from line L on.  Writes to VRAM and the sprite table go
// straight into the block RAMs the renderer reads.
#ifndef SW_VDP_VDP_H
#define SW_VDP_VDP_H
#include <stdint.h>

#define VDP_W 320
#define VDP_H 240

// ---- register map (bus addresses)
#define VDP_BASE        0xC0020000u
#define VDP_ID          (VDP_BASE + 0x000)   // RO 0x31504456 ("VDP1")
#define VDP_CTRL        (VDP_BASE + 0x004)   // RW [0] BG on, [1] sprites on
#define VDP_BG_SCROLL   (VDP_BASE + 0x008)   // RW [8:0] SX, [23:16] SY
#define VDP_BACKDROP    (VDP_BASE + 0x00C)   // RW [7:0] palette index
#define VDP_STATUS      (VDP_BASE + 0x010)   // RO [0] sprite overflow since the last write here;
                                             // W  clears it
#define VDP_SPRITES     (VDP_BASE + 0x400)   // 64 x 2 words (RW)
#define VDP_VRAM        0xC1080000u
#define VDP_MAP         (VDP_VRAM + 0x0000)  // 2048 x 16 bits (64 x 32), RW, byte writes work
#define VDP_PATTERNS    (VDP_VRAM + 0x8000)  // 8192 x 32 bits (1024 tiles), RW
#define VDP_ID_VALUE    0x31504456u

// ---- the reference model
typedef struct {
   uint16_t map [2048];
   uint32_t pat [8192];
   uint32_t spr [128];
   uint32_t ctrl, scroll, backdrop;
} vdp_state;

#ifdef __cplusplus
extern "C" {
#endif
// One line's palette indices (out [x]); returns 1 if more than 16 sprites cover the line.
int  vdp_ref_line (const vdp_state *s, int y, uint8_t out [VDP_W]);
// A whole frame with the state unchanged during it; returns the OR of the overflow flags.
int  vdp_ref_frame (const vdp_state *s, uint8_t out [VDP_H][VDP_W]);
#ifdef __cplusplus
}
#endif

// ---- helpers for programs on the SoC (static inline: no library needed)
#define VDP_REG(a) (*(volatile uint32_t *) (uintptr_t) (a))
static inline void vdp_sprite (int i, int x, int y, int tile, int bank, int flags) {
   VDP_REG (VDP_SPRITES + 8 * i)     = (uint32_t) (x & 511) | ((uint32_t) (y & 511) << 16);
   VDP_REG (VDP_SPRITES + 8 * i + 4) = (uint32_t) (tile & 1023) | ((uint32_t) (bank & 15) << 10)
                                       | ((uint32_t) flags << 14);
}
#define VDP_SPR_HFLIP  1
#define VDP_SPR_VFLIP  2
#define VDP_SPR_ON     4
#define VDP_SPR_BEHIND 8
static inline uint16_t vdp_map_entry (int tile, int bank, int hflip, int vflip) {
   return (uint16_t) ((tile & 1023) | ((bank & 15) << 10) | ((hflip & 1) << 14) | ((vflip & 1) << 15));
}
#endif
