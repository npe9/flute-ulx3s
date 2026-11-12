// adc_test: bare-metal check of spi2, the second SPI host (src/AXI4_SPI.bsv), on the on-board ADC's
// pins.  The host's frames are 8 bits, so a 16-bit word is two frames under CSMODE HOLD.
//
// Default build (CI): against sim/common/spi_echo_model.v, which echoes the previous word, so the
// host's register defaults, chip select, framing and both bytes are checked.  It is not an ADC.
//
// -DBOARD builds adc_probe for the ULX3S: it sends the MAX11125 register words used by
// emard/ulx3s-misc examples/adc (max1112x_init_pack.vhd, not checked against the datasheet) and
// prints every 16-bit reply raw, for working out the protocol on the real chip.
//
// UART: 'T' on entry, "M <id> <exp> <got>" on a mismatch, 'D' when done.
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
#define SPI(o)   REG (0xC000A000 + (o))
enum { SCKDIV = 0x00, SCKMODE = 0x04, CSID = 0x10, CSDEF = 0x14, CSMODE = 0x18, FMT = 0x40,
       TXDATA = 0x48, RXDATA = 0x4C };
enum { AUTO = 0, HOLD = 2 };

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

static uint32_t rx (void) {
   uint32_t t0 = cycles (), v;
   while ((v = SPI (RXDATA)) & 0x80000000u)
      if (cycles () - t0 > 100000u) { errs++; puts_ ("spi2: rx timeout\r\n"); return 0xFFFFFFFFu; }
   return v & 0xFF;
}
// One 16-bit word under one chip select: two frames in HOLD, then back to AUTO to release CS.
static uint32_t xfer16 (uint32_t w) {
   SPI (CSMODE) = HOLD;
   SPI (TXDATA) = (w >> 8) & 0xFF;
   SPI (TXDATA) = w & 0xFF;
   uint32_t hi = rx (), lo = rx ();
   SPI (CSMODE) = AUTO;
   return (hi << 8) | lo;
}

int main (void) {
   putc_ ('T');
   check (0x01, 3, SPI (SCKDIV));
   check (0x02, 3, SPI (CSDEF));
   check (0x03, 0, SPI (CSMODE));
   check (0x04, 0, SPI (SCKMODE));
   SPI (SCKDIV) = 1;                           // 12.5 MHz at 50 MHz
   SPI (CSID) = 0;
   while (! (SPI (RXDATA) & 0x80000000u)) ;    // drain
#ifndef BOARD
   check (0x10, 0xA5C3, xfer16 (0x1234));
   check (0x11, 0x1234, xfer16 (0xBEEF));
   check (0x12, 0xBEEF, xfer16 (0x0F0F));
   check (0x13, 0x0F0F, xfer16 (0x8001));
   puts_ (errs ? "adc_test: FAIL\r\n" : "adc_test: ok\r\n");
#else
   static const uint16_t words [] = {
      0x0040, 0x0040,          // RESET (emard: "reset all registers to defaults")
      0x8404,                  // CONFIG_SETUP ("echo on")
      0x8800,                  // UNIPOLAR ("all ch unipolar, REF-")
      0x9000,                  // BIPOLAR ("all ch unipolar")
      0xA000,                  // CUSTOM_SCAN0: none of 15..8
      0xAFF8,                  // CUSTOM_SCAN1: all of 7..0 (emard's pattern, every bit set)
      0x4006,                  // MODE_CONTROL custom_ext
      0, 0, 0, 0, 0, 0, 0, 0,  // NULLs: read the results
      0x4006, 0, 0, 0, 0, 0, 0, 0, 0,
   };
   puts_ ("adc_probe: word -> reply (reply [15:12] channel id?, [11:0] data?)\r\n");
   for (unsigned i = 0; i < sizeof words / sizeof words [0]; i++) {
      uint32_t r = xfer16 (words [i]);
      puthex (words [i], 4); puts_ (" -> "); puthex (r, 4); puts_ ("\r\n");
   }
   puts_ ("adc_probe: done\r\n");
#endif
   putc_ ('D');
   return errs;
}
