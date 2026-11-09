// io_test: bare-metal check of src/Board_IO.v through the register bridge, on the real parts of the
// ULX3S: buttons and switches (read and printed), the RTC at 0x6F (must answer and tick), the HDMI
// EDID at 0x50 (checksum, if a monitor answers).  UART: 'T' on entry, "M <id> <exp> <got>" per
// mismatch, info lines, 'D' when done (the strict-bench convention).
//
// The RTC's only write: if its oscillator is stopped (ST, bit 7 of register 0, clear), this sets ST,
// keeping the seconds, so the clock can be seen ticking.  Nothing else on the RTC changes.
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
#define I2C(o)   REG (0xC0006000 + (o))
#define GPIO(o)  REG (0xC0008000 + (o))
enum { PRERLO = 0x00, PRERHI = 0x04, CTR = 0x08, XR = 0x0C, CSR = 0x10, I2CID = 0x1C };
enum { STA = 0x80, STO = 0x40, RD = 0x20, WR = 0x10, NACK = 0x08, IACK = 0x01 };
enum { RXACK = 0x80, BUSY = 0x40, AL = 0x20, TIP = 0x02 };

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

// Returns the status after the command; a transfer that never ends is an error, not a hang.
static uint32_t cmd (uint32_t c) {
   I2C (CSR) = c;
   uint32_t t0 = cycles ();
   while (I2C (CSR) & TIP)
      if (cycles () - t0 > 5000000u) { errs++; puts_ ("i2c: stuck\r\n"); I2C (CTR) = 0; I2C (CTR) = 0x80; return RXACK; }
   uint32_t sr = I2C (CSR);
   I2C (CSR) = IACK;
   return sr;
}
static int send (uint32_t byte, uint32_t c) { I2C (XR) = byte; return ! (cmd (c | WR) & RXACK); }
static uint32_t recv (uint32_t c) { cmd (c | RD); return I2C (XR); }

// Point a device at a register and turn the bus round; 1 if it answered.
static int select_rd (uint32_t addr, uint32_t reg) {
   if (! send (addr << 1, STA)) { cmd (STO); return 0; }
   if (! send (reg, 0))         { cmd (STO); return 0; }
   if (! send ((addr << 1) | 1, STA)) { cmd (STO); return 0; }
   return 1;
}
static int rtc_read0 (uint32_t *v) {
   if (! select_rd (0x6F, 0)) return 0;
   *v = recv (NACK | STO);
   return 1;
}

int main (void) {
   putc_ ('T');
   puts_ ("\r\n");

   check (0x01, 0x47504931, GPIO (0x00));
   check (0x02, 0x49324331, I2C (I2CID));
   puts_ ("btn "); puthex (GPIO (0x04), 2); puts_ (" sw "); puthex (GPIO (0x08), 1); puts_ ("\r\n");
   check (0x03, 0, GPIO (0x04) >> 7);
   check (0x04, 0, GPIO (0x08) >> 4);

   // 100 kHz at 50 MHz: 50e6 / (5 * 100e3) - 1
   I2C (PRERLO) = 99; I2C (PRERHI) = 0;
   check (0x05, 99, I2C (PRERLO));
   I2C (CTR) = 0x80;
   check (0x06, 0x80, I2C (CTR));
   check (0x07, 0, I2C (CSR) & (BUSY | AL | TIP));

   // nobody lives at 0x10: no ack, and the bus comes back free
   check (0x08, 0, send (0x10 << 1, STA));
   cmd (STO);
   check (0x09, 0, I2C (CSR) & (BUSY | AL | TIP));

   // the RTC
   uint32_t s0 = 0, s1 = 0;
   if (! rtc_read0 (&s0)) { errs++; puts_ ("rtc: no answer at 0x6f\r\n"); }
   else {
      puts_ ("rtc sec reg "); puthex (s0, 2); puts_ ("\r\n");
      if (! (s0 & 0x80)) {
         puts_ ("rtc: oscillator stopped, setting ST\r\n");
         if (! (send (0x6F << 1, STA) && send (0, 0) && send (s0 | 0x80, STO))) { errs++; puts_ ("rtc: write failed\r\n"); cmd (STO); }
         if (! rtc_read0 (&s0)) errs++;
         check (0x0A, 0x80, s0 & 0x80);
      }
      uint32_t t0 = cycles ();
      int ticked = 0;
      while (cycles () - t0 < 125000000u) {        // 2.5 s at 50 MHz
         if (! rtc_read0 (&s1)) { errs++; puts_ ("rtc: lost\r\n"); break; }
         if (s1 != s0) { ticked = 1; break; }
      }
      puts_ ("rtc now "); puthex (s1, 2); puts_ ("\r\n");
      check (0x0B, 1, ticked);
   }

   // the monitor's EDID: a monitor is optional, a bad one is an error
   if (select_rd (0x50, 0)) {
      uint32_t sum = 0, hdr_ok = 1;
      static const uint8_t hdr [8] = { 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0 };
      puts_ ("edid ");
      for (int i = 0; i < 128; i++) {
         uint32_t b = recv (i == 127 ? (NACK | STO) : 0);
         sum += b;
         if (i < 8 && b != hdr [i]) hdr_ok = 0;
         if (i >= 8 && i < 12) puthex (b, 2);
      }
      puts_ (" sum "); puthex (sum & 255, 2); puts_ ("\r\n");
      check (0x0C, 1, hdr_ok);
      check (0x0D, 0, sum & 255);
   }
   else puts_ ("edid: no monitor answered\r\n");

   check (0x0E, 0, I2C (CSR) & (BUSY | AL | TIP));
   puts_ (errs ? "io_test: FAIL\r\n" : "io_test: ok\r\n");
   putc_ ('D');
   return 0;
}
