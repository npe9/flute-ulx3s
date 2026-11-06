// fb_test: bare-metal check of the DVI framebuffer (src/Video_DVI.v) through the register-bus
// bridge (src/AXI4_RegBus.bsv): control at 0xC001_0000, pixel RAM at 0xC100_0000.  Loaded at
// 0x80000000 by the UART boot loader.  UART output: 'T' on entry, "M <id> <exp> <got>" per
// mismatch, info lines, 'D' when done (the strict-bench convention).
// Checks: ID / MODE / FBSIZE / palette reset values, a full pixel-RAM word fill read back,
// byte and halfword stores, reads past the backed RAM, palette writes, the frame counter
// running in the test-pattern mode.  It leaves a CPU-drawn RGB565 picture on the screen
// (colour ramps, a white frame, a diagonal), so the board result can be checked by eye.
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
#define VID(o)   REG (0xC0010000 + (o))
#define FB32     ((volatile uint32_t *) 0xC1000000)
#define FB16     ((volatile uint16_t *) 0xC1000000)
#define FB8      ((volatile uint8_t  *) 0xC1000000)
enum { ID = 0x000, MODE = 0x004, STATUS = 0x008, FRAME = 0x00c, FBSIZE = 0x010, PAL = 0x400 };
#define WORDS 38400

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
static inline uint32_t pat (uint32_t i) { return (i * 0x9E3779B1u) ^ 0xA5C3E1F0u; }

int main (void) {
   putc_ ('T');
   puts_ ("\r\n");

   check (0x01, 0x56494431, VID (ID));
   check (0x02, 0, VID (MODE));
   check (0x03, 153600, VID (FBSIZE));
   check (0x04, 0xFFFF55, VID (PAL + 4 * 14));     // VGA yellow
   check (0x05, 0x920000, VID (PAL + 4 * 0x80));   // RGB332 0x80

   // full word fill, then read back
   uint32_t t0 = cycles ();
   for (uint32_t i = 0; i < WORDS; i++) FB32 [i] = pat (i);
   uint32_t t1 = cycles ();
   uint32_t bad = 0, first = 0xFFFFFFFF;
   for (uint32_t i = 0; i < WORDS; i++)
      if (FB32 [i] != pat (i)) { if (! bad) first = i; bad++; }
   uint32_t t2 = cycles ();
   check (0x10, 0, bad);
   if (bad) { puts_ ("first bad word "); puthex (first, 8); puts_ ("\r\n"); }
   puts_ ("fill "); puthex (t1 - t0, 8); puts_ (" readback "); puthex (t2 - t1, 8);
   puts_ (" cycles for 38400 words\r\n");

   // byte and halfword stores
   FB32 [5] = 0x11223344;
   FB8 [20] = 0xAA;
   FB8 [23] = 0xBB;
   check (0x11, 0xBB2233AA, FB32 [5]);
   FB32 [6] = 0;
   FB16 [13] = 0xCAFE;
   check (0x12, 0xCAFE0000, FB32 [6]);
   check (0x13, 0xCAFE, FB16 [13]);
   check (0x14, 0xBB, FB8 [23]);
   // the last word, and past the backed RAM (reads 0, writes dropped)
   FB32 [WORDS - 1] = 0x600DF00D;
   check (0x15, 0x600DF00D, FB32 [WORDS - 1]);
   FB32 [WORDS] = 0x12345678;
   check (0x16, 0, FB32 [WORDS]);
   check (0x17, pat (0), FB32 [0]);

   // palette
   VID (PAL + 4 * 200) = 0x123456;
   VID (PAL + 4 * 201) = 0xFFABCDEF;
   check (0x20, 0x123456, VID (PAL + 4 * 200));
   check (0x21, 0xABCDEF, VID (PAL + 4 * 201));
   VID (PAL + 4 * 200) = 0xDB4900;                     // put the RGB332 defaults back
   VID (PAL + 4 * 201) = 0xDB4955;                     // (200 = 110 010 00, 201 = 110 010 01)
   check (0x22, 0xDB4900, VID (PAL + 4 * 200));

   // the frame counter runs once scan-out is on
   VID (MODE) = 7;
   check (0x30, 7, VID (MODE));
   uint32_t f0 = VID (FRAME), n = 0;
   while (VID (FRAME) - f0 < 2 && n < 4000000) n++;
   check (0x31, 2, VID (FRAME) - f0);

   // leave a picture: 320x240 RGB565, red ramp across, green ramp down, blue checker,
   // a white frame and a white diagonal
   for (uint32_t y = 0; y < 240; y++)
      for (uint32_t x = 0; x < 320; x += 2) {
         uint32_t px [2];
         for (int k = 0; k < 2; k++) {
            uint32_t xx = x + k;
            uint32_t r = xx * 31 / 319, g = y * 63 / 239, b = (((xx >> 5) ^ (y >> 5)) & 1) ? 24 : 0;
            px [k] = (r << 11) | (g << 5) | b;
            if (xx == 0 || xx == 319 || y == 0 || y == 239 || xx == y + 40) px [k] = 0xFFFF;
         }
         FB32 [(y * 640 + x * 2) / 4] = px [0] | (px [1] << 16);
      }
   VID (MODE) = 2;
   check (0x32, 2, VID (MODE));

   puts_ (errs ? "fb_test: errors\r\n" : "fb_test: ok\r\n");
   putc_ ('D');
   puts_ ("\r\n");
   return 0;
}
