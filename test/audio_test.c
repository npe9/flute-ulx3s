// audio_test: bare-metal check of src/Audio.v through the register bridge.  Silent: VOLUME stays
// 0 (mute), so it is safe on a board with headphones plugged in.  Registers and reset values, FIFO
// depth, drop and underrun accounting, the drain rate.  UART: 'T' on entry, "M <id> <exp> <got>" on
// a mismatch, 'D' when done (the strict-bench convention).
//
// Built with -DAUDIBLE it is the listening demo instead, at low volume: a 440 Hz tone on both
// channels, then a PCM tone on the left only, then on the right only.  Not for CI.
//
// Build: riscv64-unknown-elf-gcc -march=rv32imac_zicsr -mabi=ilp32 -Os -ffreestanding
//   -nostdlib -nostartfiles -T sd_test.ld; objcopy -O binary; pad to 4 bytes.
#include <stdint.h>

__asm__ (".section .text.start\n.globl _start\n_start:\n"
         "  li sp, 0x81000000\n"
         "  la t0, __bss_start\n  la t1, __bss_end\n"
         "2: bgeu t0, t1, 3f\n  sw zero, 0(t0)\n  addi t0, t0, 4\n  j 2b\n"
         "3: call main\n1: j 1b\n.text\n");

#define REG(a) (*(volatile uint32_t *) (a))
#define UART_THR REG (0xC0000000)
#define UART_LSR REG (0xC0000014)
#define AUD(o)   REG (0xC0009000 + (o))
enum { ID = 0x00, CTRL = 0x04, VOLUME = 0x08, RATE = 0x0C, TONE = 0x10, FIFO = 0x14, STATUS = 0x18 };
enum { PCM = 1, TONE_ON = 2, DROP = 1 << 16, UNDERRUN = 1 << 17, LEVEL = 0x1FF };

static void putc_ (char c) { while (! (UART_LSR & 0x20)) ; UART_THR = c; }
static void puts_ (const char *s) { while (*s) putc_ (*s++); }
static void puthex (uint32_t v, int n) {
   for (int i = n - 1; i >= 0; i--) putc_ ("0123456789abcdef"[(v >> (4 * i)) & 15]);
}
static int errs;
static void check (int id, uint32_t exp, uint32_t got) {
   if (exp != got) {
      errs++;
      putc_ ('M'); putc_ (' '); puthex (id, 2); putc_ (' '); puthex (exp, 8); putc_ (' ');
      puthex (got, 8); puts_ ("\r\n");
   }
}
static inline uint32_t cycles (void) { uint32_t c; __asm__ volatile ("rdcycle %0" : "=r" (c)); return c; }

#ifdef AUDIBLE
#define CLK_HZ 50000000u
static void wait_s (uint32_t tenths) {
   for (uint32_t i = 0; i < tenths; i++) { uint32_t t0 = cycles (); while (cycles () - t0 < CLK_HZ / 10) ; }
}
// A 441 Hz triangle at 44.1 kHz; the amplitude is a quarter of full scale, before VOLUME.
static void pcm_tone (int left, uint32_t samples) {
   int32_t v = 0, step = 320;
   while (samples--) {
      while ((AUD (STATUS) & LEVEL) >= 256) ;
      v += step;
      if (v >= 8000 || v <= -8000) step = -step;
      uint32_t s = (uint16_t) v;
      AUD (FIFO) = left ? s : s << 16;
   }
}
int main (void) {
   puts_ ("audio demo: low volume\r\n");
   AUD (VOLUME) = 2;                 // output >> 6: low, on purpose
   puts_ ("tone, both channels\r\n");
   AUD (CTRL) = TONE_ON;
   wait_s (20);
   AUD (CTRL) = PCM;
   puts_ ("pcm, left\r\n");
   pcm_tone (1, 88200);
   puts_ ("pcm, right\r\n");
   pcm_tone (0, 88200);
   while (AUD (STATUS) & LEVEL) ;
   AUD (CTRL) = 0;
   AUD (VOLUME) = 0;
   puts_ ("audio demo: done, muted\r\n");
   return 0;
}
#else
int main (void) {
   putc_ ('T');
   check (0x01, 0x41554431, AUD (ID));
   check (0x02, 0, AUD (CTRL));
   check (0x03, 0, AUD (VOLUME));
   check (0x04, 1133, AUD (RATE));
   check (0x05, 28408, AUD (TONE));
   check (0x06, 0, AUD (STATUS) & LEVEL);

   // Fill while stopped: 256 go in, the next is dropped and counted.
   for (uint32_t i = 0; i < 256; i++) AUD (FIFO) = i;
   check (0x10, 256, AUD (STATUS));
   AUD (FIFO) = 0xFFFFFFFF;
   check (0x11, 256 | DROP, AUD (STATUS));
   AUD (STATUS) = 0;
   check (0x12, 256, AUD (STATUS));

   // Drain at 100 clocks per sample, and time it.  The rdcycle clock is the audio clock.  The sample
   // counter runs free, so the first sample can come up to one old period (1134 clocks) late.
   AUD (RATE) = 99;
   check (0x20, 99, AUD (RATE));
   uint32_t t0 = cycles ();
   AUD (CTRL) = PCM;
   while ((AUD (STATUS) & LEVEL) && cycles () - t0 < 1000000u) ;
   uint32_t dt = cycles () - t0;
   check (0x21, 0, AUD (STATUS) & LEVEL);
   if (dt < 25400 || dt > 26900) { errs++; puts_ ("drain cycles "); puthex (dt, 8); puts_ ("\r\n"); }

   // Empty at the next sample time: underrun is sticky until written.
   t0 = cycles ();
   while (cycles () - t0 < 300) ;
   check (0x22, UNDERRUN, AUD (STATUS) & (UNDERRUN | DROP));
   AUD (CTRL) = 0;
   AUD (STATUS) = 0;
   check (0x23, 0, AUD (STATUS));
   AUD (RATE) = 1133;
   check (0x30, 0, AUD (VOLUME));    // still muted

   puts_ (errs ? "audio_test: FAIL\r\n" : "audio_test: ok\r\n");
   putc_ ('D');
   return errs;
}
#endif
