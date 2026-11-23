// sw/game2d/sound.h: Lantern Drift's music and effects on APU1 (sw/apu/apu.h), through
// hw_apu_write only, driven once a frame -- so the write sequence depends on nothing but the game
// state, and the host build (host.c) issues exactly the writes the board does (sim/game2d checks).
#ifndef SW_GAME2D_SOUND_H
#define SW_GAME2D_SOUND_H
void sound_init (void);     // voices, wave RAM (the drum sample), output on
void sound_frame (void);    // once a frame: the music sequencer and the effects' envelopes
void sound_fly (void);      // a firefly collected
void sound_crash (void);    // the boat hit a log
#endif
