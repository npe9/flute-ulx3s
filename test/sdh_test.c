// sdh_test: bare-metal check of src/Sd_Host.v (native SD mode) through the register bridge, for the
// strict bench with +sd_native (sim/common/sd_native_model.v: byte i of block b = i ^ b, 0x55AA at
// 510 of block 0).  Reset values, the ESP32 interlock, card init to 4-bit, a single and a 3-block
// read (CRCs checked), WPROT refusing CMD24.  Read-only: built with -DSDH_WRITE it is sdh_test_w,
// which also writes two blocks and reads them back -- SIMULATOR ONLY, never on the board.
// UART: 'T' on entry, "M <id> <exp> <got>" on a mismatch, 'D' when done (the strict-bench convention).
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
#define SDH(o)   REG (0xC000D000 + (o))
#define GPIO1(o) REG (0xC0008000 + (o))
enum { ID = 0x00, CTRL = 0x04, ARG = 0x08, CMD = 0x0C, STATUS = 0x10, RESP0 = 0x14, BLKSIZE = 0x24,
       BLKCNT = 0x28, FIFO = 0x30, ABORT = 0x34 };
enum { R48 = 0x100, R136 = 0x200, NOCRC = 0x400, DATA = 0x800, WRITE = 0x1000 };
enum { CBUSY = 1, CDONE = 2, CTMO = 4, CCRC = 8, DBUSY = 0x10, DDONE = 0x20, DCRC = 0x40, DTMO = 0x80,
       BUF = 0x100, DAT0 = 0x200, WPREJ = 0x400, WRERR = 0x800, NATIVE = 0x1000 };

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
static uint32_t wait_not (uint32_t mask) {
   uint32_t s, n = 0;
   do s = SDH (STATUS); while ((s & mask) && ++n < 2000000u);
   return s;
}
static uint32_t wait_any (uint32_t mask) {
   uint32_t s, n = 0;
   do s = SDH (STATUS); while (!(s & mask) && ++n < 2000000u);
   return s;
}
static uint32_t cmd (uint32_t idx, uint32_t arg, uint32_t fl) {
   SDH (ARG) = arg;
   SDH (CMD) = idx | fl;
   return wait_not (CBUSY);
}
static uint32_t rca;
static uint32_t acmd (uint32_t idx, uint32_t arg, uint32_t fl) {
   cmd (55, rca << 16, R48);
   return cmd (idx, arg, fl);
}
static uint32_t pat (uint32_t b, uint32_t w) {        // word w of block b in the model's pattern
   uint32_t v = 0;
   for (int k = 3; k >= 0; k--) {
      uint32_t i = w * 4 + k, x = (i ^ b) & 0xFF;
      if (b == 0 && i == 510) x = 0x55;
      if (b == 0 && i == 511) x = 0xAA;
      v = v << 8 | x;
   }
   return v;
}
static void read_blocks (int id, uint32_t lba, uint32_t n, int written) {
   uint32_t bad = 0, first = 0xFFFFFFFF, s;
   SDH (BLKSIZE) = 512;
   SDH (BLKCNT) = n;
   s = cmd (n > 1 ? 18 : 17, lba, R48 | DATA);
   check (id, 0, s & (CTMO | CCRC | WPREJ));
   for (uint32_t b = 0; b < n; b++) {
      s = wait_any (BUF | DTMO);
      check (id + 1, BUF, s & (BUF | DTMO));
      for (uint32_t w = 0; w < 128; w++) {
         uint32_t v = SDH (FIFO);
         uint32_t e = written ? 0xA5000000u + (lba + b) * 0x10000u + w : pat (lba + b, w);
         if (v != e) { if (!bad) first = b << 16 | w; bad++; }
      }
   }
   check (id + 2, 0, bad);
   if (bad) check (id + 3, 0, first);
   s = wait_not (DBUSY);
   check (id + 4, DDONE, s & (DDONE | DCRC | DTMO));
   if (n > 1) { cmd (12, 0, R48); wait_any (DAT0); }
}

int main (void) {
   putc_ ('T');
   check (0x01, 0x53444831, SDH (ID));
   check (0x02, 0x003E0004, SDH (CTRL));                // SPI mode, WPROT, 397 kHz
   GPIO1 (0x0C) = 1;                                     // ESP32 running: native mode is refused
   SDH (CTRL) = 0x003E000D;
   check (0x03, 0, SDH (STATUS) & NATIVE);
   GPIO1 (0x0C) = 0;
   check (0x04, NATIVE, SDH (STATUS) & NATIVE);
   for (volatile int i = 0; i < 3000; i++) ;            // 74+ clocks
   cmd (0, 0, 0);
   uint32_t s = cmd (8, 0x1AA, R48);
   check (0x10, 0, s & (CTMO | CCRC));
   check (0x11, 0x1AA, SDH (RESP0) & 0xFFF);
   uint32_t ocr = 0;
   for (int i = 0; i < 20 && !(ocr & 0x80000000u); i++) {
      acmd (41, 0x40FF8000, R48 | NOCRC);
      ocr = SDH (RESP0);
   }
   check (0x12, 0xC0000000u, ocr & 0xC0000000u);
   s = cmd (2, 0, R136 | NOCRC);
   check (0x13, 0, s & CTMO);
   cmd (3, 0, R48);
   rca = SDH (RESP0) >> 16;
   check (0x14, 0x4321, rca);
   s = cmd (7, rca << 16, R48);
   check (0x15, 0, s & (CTMO | CCRC));
   acmd (6, 2, R48);
   SDH (CTRL) = 0x0001000F;                              // 4-bit, 12.5 MHz, WPROT
   read_blocks (0x20, 0, 1, 0);
   read_blocks (0x28, 9, 3, 0);
   SDH (BLKCNT) = 1;
   s = cmd (24, 7, R48 | DATA | WRITE);
   check (0x30, WPREJ, s & (WPREJ | DBUSY));
#ifdef SDH_WRITE
   SDH (CTRL) = 0x0001000B;                              // no WPROT (the simulator's card only)
   SDH (BLKSIZE) = 512;
   SDH (BLKCNT) = 2;
   s = cmd (25, 7, R48 | DATA | WRITE);
   check (0x40, 0, s & (CTMO | CCRC | WPREJ));
   for (uint32_t b = 0; b < 2; b++) {
      wait_any (BUF);
      for (uint32_t w = 0; w < 128; w++) SDH (FIFO) = 0xA5000000u + (7 + b) * 0x10000u + w;
   }
   s = wait_not (DBUSY);
   check (0x41, DDONE, s & (DDONE | WRERR | DTMO | DCRC));
   cmd (12, 0, R48);
   wait_any (DAT0);
   SDH (CTRL) = 0x0001000F;
   read_blocks (0x48, 7, 2, 1);
#endif
   SDH (CTRL) = 0x00010004;                              // back to SPI mode
   check (0x50, 0, SDH (STATUS) & NATIVE);
   puts_ (errs ? "sdh_test: FAIL\r\n" : "sdh_test: PASS\r\n");
   putc_ ('D');
   for (;;) ;
}
