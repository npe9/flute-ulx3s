// sw/apu/apu.h: APU1, the game2d sound chip (src/Apu.v): its programming model, register map and
// the reference model's interface (sw/apu/apu_ref.c, which src/Apu.v matches sample for sample).
//
// Eight voices, each a pulse (4 duty cycles), triangle, noise (15-bit LFSR, long or short) or
// 8-bit sample voice (from a 32 KB wave RAM, one-shot or looped), with a pitch, an ADSR envelope
// and a left / right volume, mixed into a stereo 16-bit stream at 32 kHz (one sample tick every
// APU_TICK_CLKS system clocks).  The stream goes into src/Audio.v's DAC path, on the jack, after
// Audio's VOLUME (reset 0, mute: set it, e.g. 4, to hear the APU).
//
// Timing: every bus write (register, KEYON / KEYOFF, wave RAM) is queued and applied at the first
// sample tick after it is taken, in order; the tick then computes the voices.  A program's sound
// is therefore exactly determined by which tick each write landed before, and the reference
// model takes (tick, write) events.  Reads return the last value written (the queue does not
// delay them), or status.
//
// Each tick, per sounding voice (state: the phase P, the envelope E and its stage, the LFSR):
//   1. its output, from the state as it stands (before step 2):
//        w (signed): pulse    step = P[18:14] (0-31); w = step < H ? +96 : -96, H = 4, 8, 16, 24
//                             for DUTY 0-3 (12.5, 25, 50, 75 %)
//                    triangle t = step < 16 ? step : 31 - step; w = 16 * t - 120
//                    noise    w = (LFSR & 1) ? +96 : -96
//                    sample   w = wave [(START + P[26:12]) mod 32768] (P counts from START)
//                    MODE 0 (or 5-7) w = 0 (the envelope and phase still run)
//        e = w * E[15:8] (signed 16 bits); l = (e * VOL_L) >> 8, r = (e * VOL_R) >> 8 (arithmetic)
//   2. the advance:
//        tone modes  P = (P + PITCH) mod 2^19 (f = PITCH * 32000 / 524288 Hz)
//        noise       also steps the LFSR once for each 2^14 boundary P crossed (0-4 steps; a
//                    step: fb = bit0 ^ (SHORT ? bit6 : bit1), LFSR = (LFSR >> 1) | (fb << 14))
//        sample      P = (P + PITCH) mod 2^27 (PITCH is 4.12: 0x1000 = a byte a tick); then
//                    with a = START + P[26:12] (17 bits, unwrapped): if a >= END, with LOOP
//                    P[26:12] = (P[26:12] - (END - LOOP)) mod 2^15 (P[11:0] kept), without LOOP
//                    the voice stops
//        envelope    attack   A = 0: E = 0xFFFF; else E = min (E + A, 0xFFFF); at 0xFFFF -> decay
//                    decay    D = 0: -> sustain (E kept); else E = E - D, and if that is at or
//                             below S << 8 (or below 0): E = S << 8, -> sustain
//                    sustain  E kept
//                    release  R = 0 or E <= R: E = 0, the voice stops; else E = E - R
// Modes other than sample advance as tone modes.
// The mix: the eight l (r) summed, times MASTER, >> 6 (arithmetic), saturated to 16 bits; with
// CTRL[0] clear the output is 0 (the voices still run).  A stopped voice (stage 0: never keyed,
// ended, released) contributes 0 and its state holds.
// KEYON resets a voice whatever its registers: P = 0, E = 0, attack, LFSR = 1 (so a queued write
// costs the same few clocks whatever it is: the tick's work is bounded, src/Apu.v's deadline).
// KEYOFF sends a sounding voice to release.  Both act in queue order with the register writes
// around them, before the voices are computed.
#ifndef SW_APU_APU_H
#define SW_APU_APU_H
#include <stdint.h>

#define APU_TICK_CLKS   1563u                  // system clocks per sample tick (31.99 kHz at 50 MHz)
#define APU_VOICES      8
#define APU_WAVE_BYTES  32768u

#define APU_BASE        0xC0040000u
#define APU_ID          (APU_BASE + 0x000)     // RO 0x31555041 ("APU1")
#define APU_CTRL        (APU_BASE + 0x004)     // RW [0] output on
#define APU_MASTER      (APU_BASE + 0x008)     // RW [7:0] master volume (64 = unity), reset 64
#define APU_TICKS       (APU_BASE + 0x00C)     // RO sample ticks since reset
#define APU_STATUS      (APU_BASE + 0x010)     // RO [10:0] writes queued; [23:16] voices sounding
#define APU_KEYON       (APU_BASE + 0x014)     // WO [7:0] key these voices on (queued)
#define APU_KEYOFF      (APU_BASE + 0x018)     // WO [7:0] release these voices (queued)
// voice v (0-7): 0x100 + 0x20 * v
#define APU_VOICE(v)    (APU_BASE + 0x100 + 0x20 * (v))
#define APU_MODE(v)     (APU_VOICE (v) + 0x00) // RW [2:0] 0 off, 1 pulse, 2 triangle, 3 noise,
                                               //    4 sample; [5:4] DUTY; [8] SHORT (noise);
                                               //    [9] LOOP (sample)
#define APU_PITCH(v)    (APU_VOICE (v) + 0x04) // RW [15:0]
#define APU_VOL(v)      (APU_VOICE (v) + 0x08) // RW [7:0] left, [15:8] right
#define APU_ADSR(v)     (APU_VOICE (v) + 0x0C) // RW [7:0] A, [15:8] D, [23:16] S, [31:24] R
#define APU_START(v)    (APU_VOICE (v) + 0x10) // RW [14:0] first byte (sample)
#define APU_LOOP(v)     (APU_VOICE (v) + 0x14) // RW [14:0] loop point (sample)
#define APU_END(v)      (APU_VOICE (v) + 0x18) // RW [15:0] end, exclusive (sample; 32768 = the top)
#define APU_ENV(v)      (APU_VOICE (v) + 0x1C) // RO [7:0] level, [10:8] stage (0 off, 1 attack,
                                               //    2 decay, 3 sustain, 4 release)
#define APU_WAVE        (APU_BASE + 0x8000)    // 32 KB wave RAM: 8-bit signed samples (WO)
#define APU_ID_VALUE    0x31555041u

enum { APU_OFF = 0, APU_PULSE = 1, APU_TRIANGLE = 2, APU_NOISE = 3, APU_SAMPLE = 4 };
#define APU_DUTY(d)     ((uint32_t) (d) << 4)
#define APU_SHORT       (1u << 8)
#define APU_LOOPED      (1u << 9)
static inline uint32_t apu_adsr (int a, int d, int s, int r) {
   return (uint32_t) (a & 255) | ((uint32_t) (d & 255) << 8) | ((uint32_t) (s & 255) << 16)
          | ((uint32_t) (r & 255) << 24);
}
// PITCH for a tone frequency (hundredths of a Hz): f * 524288 / 32000 / 100, rounded
static inline uint32_t apu_pitch_cHz (uint32_t f_cHz) { return (uint32_t) (((uint64_t) f_cHz * 524288u + 1600000u) / 3200000u); }

// ---- the reference model
typedef struct {
   uint32_t ctrl, master, ticks;
   uint32_t reg [APU_VOICES][8];               // MODE, PITCH, VOL, ADSR, START, LOOP, END, -
   uint32_t p [APU_VOICES];                    // phase / sample position
   uint32_t e [APU_VOICES];                    // envelope
   uint32_t stage [APU_VOICES];
   uint32_t lfsr [APU_VOICES];
   int8_t   wave [APU_WAVE_BYTES];
} apu_state;

#ifdef __cplusplus
extern "C" {
#endif
void apu_ref_reset (apu_state *s);
// a queued write (addr: the byte address; strb: byte lanes), applied in order at the next tick
void apu_ref_write (apu_state *s, uint32_t addr, uint32_t data, uint32_t strb);
// one sample tick (after the writes queued before it are applied): the stereo output
void apu_ref_tick (apu_state *s, int16_t *left, int16_t *right);
#ifdef __cplusplus
}
#endif
#endif
