// sd_test: bare-metal microSD check over the SPI host (src/AXI4_SPI.bsv, SiFive SPI registers at
// 0xC000_4000).  Loaded at 0x80000000 by the UART boot loader.  UART output: 'T' on entry,
// "M <id> <exp> <got>" per mismatch, info lines, 'D' when done (the strict-bench convention).
// SD init in SPI mode (CMD0, CMD8, ACMD41, CMD58), CMD9 CSD, CMD17 read of block 0 with the
// data CRC16 checked; prints the MBR signature.  -DSD_WRITE (simulation only; it overwrites
// blocks 100-102): CMD24 single and CMD25 multi-block writes read back with CMD17 / CMD18.
// Build: riscv64-unknown-elf-gcc -march=rv32imac -mabi=ilp32 -Os -ffreestanding -nostdlib
//   -nostartfiles -T sd_test.ld [-DSD_WRITE]; objcopy -O binary; pad to 4 bytes.
#include <stdint.h>

__asm__ (".section .text.start\n.globl _start\n_start:\n"
         "  li sp, 0x81000000\n"
         "  la t0, __bss_start\n  la t1, __bss_end\n"
         "2: bgeu t0, t1, 3f\n  sw zero, 0(t0)\n  addi t0, t0, 4\n  j 2b\n"
         "3: call main\n1: j 1b\n.text\n");

#define REG(a) (*(volatile uint32_t *) (a))
#define UART_THR REG (0xC0000000)
#define UART_LSR REG (0xC0000014)
#define SPI(o)   REG (0xC0004000 + (o))
enum { SCKDIV = 0x00, SCKMODE = 0x04, CSID = 0x10, CSDEF = 0x14, CSMODE = 0x18, FMT = 0x40,
       TXDATA = 0x48, RXDATA = 0x4c, TXMARK = 0x50, RXMARK = 0x54, IE = 0x70, IP = 0x74 };

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

static uint8_t xfer (uint8_t b) {
   SPI (TXDATA) = b;
   uint32_t r;
   do r = SPI (RXDATA); while (r & 0x80000000u);
   return r;
}
static uint16_t crc16 (uint16_t c, uint8_t b) {
   c ^= (uint16_t) b << 8;
   for (int k = 0; k < 8; k++) c = (c & 0x8000) ? (c << 1) ^ 0x1021 : (c << 1);
   return c;
}
static uint8_t cmd (int idx, uint32_t arg, uint8_t crc) {
   xfer (0xFF);
   xfer (0x40 | idx);
   xfer (arg >> 24); xfer (arg >> 16); xfer (arg >> 8); xfer (arg);
   xfer (crc);
   uint8_t r = 0xFF;
   for (int i = 0; i < 10 && (r & 0x80); i++) r = xfer (0xFF);
   return r;
}
// read a data block (after its command's R1); returns 0 if the token and CRC are good
static int read_data (uint8_t *buf, int n) {
   uint8_t t = 0xFF;
   for (int i = 0; i < 100000 && t == 0xFF; i++) t = xfer (0xFF);
   if (t != 0xFE) return 0x100 | t;
   uint16_t c = 0;
   for (int i = 0; i < n; i++) { buf [i] = xfer (0xFF); c = crc16 (c, buf [i]); }
   uint16_t got = xfer (0xFF) << 8; got |= xfer (0xFF);
   return (got == c) ? 0 : 0x200;
}
static int wait_ready (void) {
   for (int i = 0; i < 1000000; i++) if (xfer (0xFF) == 0xFF) return 0;
   return 1;
}
#ifdef SD_WRITE
static int write_data (uint8_t token, const uint8_t *buf) {
   uint16_t c = 0;
   xfer (token);
   for (int i = 0; i < 512; i++) { xfer (buf [i]); c = crc16 (c, buf [i]); }
   xfer (c >> 8); xfer (c);
   uint8_t r = xfer (0xFF);
   wait_ready ();
   return r & 0x1F;
}
#endif

static uint8_t blk [512], blk2 [512];

int main (void) {
   putc_ ('T'); puts_ ("\r\n");

   // registers: reset values, CSDEF probe (one CS)
   check (0x01, 1, SPI (CSDEF));
   SPI (CSDEF) = 0xFFFFFFFF; check (0x02, 1, SPI (CSDEF)); SPI (CSDEF) = 1;
   check (0x03, 0x80000000u, SPI (RXDATA));

   // 400 kHz, mode 0, 8-bit frames; >= 74 clocks with CS deasserted
   SPI (SCKDIV) = 62; SPI (SCKMODE) = 0; SPI (CSID) = 0; SPI (FMT) = 0x00080000;
   SPI (CSMODE) = 3;
   for (int i = 0; i < 10; i++) xfer (0xFF);
   SPI (CSMODE) = 2;

   uint8_t r = cmd (0, 0, 0x95);
   check (0x10, 0x01, r);
   if (r != 0x01) { puts_ ("no card\r\n"); goto done; }
   r = cmd (8, 0x1AA, 0x87);
   check (0x11, 0x01, r);
   uint32_t r7 = 0;
   for (int i = 0; i < 4; i++) r7 = (r7 << 8) | xfer (0xFF);
   check (0x12, 0x1AA, r7 & 0xFFF);
   int n = 0;
   do { cmd (55, 0, 0x65); r = cmd (41, 0x40000000, 0x77); n++; } while (r != 0 && n < 2000);
   check (0x13, 0x00, r);
   r = cmd (58, 0, 0xFD);
   check (0x14, 0x00, r);
   uint32_t ocr = 0;
   for (int i = 0; i < 4; i++) ocr = (ocr << 8) | xfer (0xFF);
   puts_ ("O "); puthex (ocr, 8); puts_ ("\r\n");
   check (0x15, 0x80000000u, ocr & 0x80000000u);    // powered up

   SPI (SCKDIV) = 2;                                 // 50 MHz / 6 = 8.3 MHz
   r = cmd (9, 0, 0xFF);
   check (0x20, 0x00, r);
   check (0x21, 0, read_data (blk, 16));
   puts_ ("C ");
   for (int i = 0; i < 16; i++) puthex (blk [i], 2);
   puts_ ("\r\n");

   r = cmd (17, 0, 0xFF);
   check (0x30, 0x00, r);
   check (0x31, 0, read_data (blk, 512));
   check (0x32, 0x55AA, (blk [510] << 8) | blk [511]);    // MBR / boot-sector signature
   puts_ ("S "); puthex (blk [510], 2); puthex (blk [511], 2);
   puts_ (" "); for (int i = 0; i < 8; i++) puthex (blk [i], 2);
   puts_ ("\r\n");

#ifdef SD_WRITE
   // CMD24: block 100
   for (int i = 0; i < 512; i++) blk2 [i] = (uint8_t) (i * 7 + 1);
   r = cmd (24, 100, 0xFF); check (0x40, 0, r);
   check (0x41, 0x05, write_data (0xFE, blk2));
   r = cmd (17, 100, 0xFF); check (0x42, 0, r);
   check (0x43, 0, read_data (blk, 512));
   for (int i = 0; i < 512; i++) if (blk [i] != blk2 [i]) { check (0x44, blk2 [i], blk [i]); break; }
   // CMD25: blocks 101, 102; CMD18 reads 100..102
   r = cmd (25, 101, 0xFF); check (0x50, 0, r);
   for (int b = 0; b < 2; b++) {
      for (int i = 0; i < 512; i++) blk2 [i] = (uint8_t) (i ^ (0x5A + b));
      check (0x51 + b, 0x05, write_data (0xFC, blk2));
   }
   xfer (0xFD); xfer (0xFF); wait_ready ();
   r = cmd (18, 100, 0xFF); check (0x60, 0, r);
   for (int b = 0; b < 3; b++) {
      check (0x61 + b, 0, read_data (blk, 512));
      uint8_t e = (b == 0) ? 1 : (uint8_t) (0 ^ (0x5A + b - 1));
      check (0x64 + b, e, blk [0]);
   }
   r = cmd (12, 0, 0xFF); check (0x67, 0, r);
   wait_ready ();
   puts_ ("W ok\r\n");
#endif

done:
   SPI (CSMODE) = 0;
   puts_ (errs ? "FAIL\r\n" : "PASS\r\n");
   putc_ ('D'); puts_ ("\r\n");
   for (;;) ;
}
