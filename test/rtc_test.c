// rtc_test: the MCP7940N on the ULX3S (I2C 0x6F through src/Board_IO.v), datasheet DS20005010J.
// Turns battery backup on (VBATEN, RTCWKDAY bit 3: off at the chip's power-on, so without it the battery
// is not used), starts the oscillator if it is stopped (ST), then sets alarm 0 to the seconds two ahead
// (ALM0MSK = 000, ALMPOL = 0: MFP pulled low, the polarity that wakes the board), waits for ALM0IF,
// and turns the alarm off again.  Time and date are left as they are.  Safe on the board: the alarm
// pulse on MFP is the power-on request, and the board is already on.
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
#define I2C(o)   REG (0xC0006000 + (o))
enum { PRERLO = 0x00, PRERHI = 0x04, CTR = 0x08, XR = 0x0C, CSR = 0x10 };
enum { STA = 0x80, STO = 0x40, RD = 0x20, WR = 0x10, NACK = 0x08, IACK = 0x01 };
enum { RXACK = 0x80, TIP = 0x02 };
enum { RTCSEC = 0x00, RTCWKDAY = 0x03, CONTROL = 0x07, ALM0SEC = 0x0A, ALM0WKDAY = 0x0D };
enum { ST = 0x80, VBATEN = 0x08, ALM0EN = 0x10, ALM0IF = 0x08 };

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
static int rd (uint32_t reg, uint32_t *v) {
   if (! (send (0x6F << 1, STA) && send (reg, 0) && send ((0x6F << 1) | 1, STA))) { cmd (STO); return 0; }
   *v = recv (NACK | STO);
   return 1;
}
static int wr (uint32_t reg, uint32_t v) {
   if (send (0x6F << 1, STA) && send (reg, 0) && send (v, STO)) return 1;
   cmd (STO); errs++; puts_ ("rtc: write failed\r\n"); return 0;
}
static uint32_t bcd_inc (uint32_t s, int k) {            // seconds, BCD, + k mod 60
   int v = ((s >> 4) & 7) * 10 + (s & 15);
   v = (v + k) % 60;
   return ((v / 10) << 4) | (v % 10);
}

int main (void) {
   putc_ ('T');
   I2C (CTR) = 0; I2C (PRERLO) = 99; I2C (PRERHI) = 0; I2C (CTR) = 0x80;   // 100 kHz at 50 MHz
   uint32_t sec, wk, ctl, a;
   if (! rd (RTCSEC, &sec)) { puts_ ("rtc: no answer at 0x6f\r\n"); errs++; goto out; }
   if (! (sec & ST)) { puts_ ("rtc: oscillator stopped, setting ST\r\n"); wr (RTCSEC, sec | ST); }
   rd (RTCWKDAY, &wk);
   puts_ ("rtc wkday reg "); puthex (wk, 2); puts_ ((wk & 0x10) ? " (PWRFAIL: power was lost)" : ""); puts_ ("\r\n");
   if ((wk & 7) == 0) wk = (wk & ~7u) | 1;                  // weekday must be 1..7
   wr (RTCWKDAY, (wk & 0x07) | VBATEN);                     // battery on; this write clears PWRFAIL
   rd (RTCWKDAY, &wk);
   check (0x01, VBATEN, wk & (VBATEN | 0x10));

   rd (CONTROL, &ctl);
   wr (CONTROL, ctl & ~ALM0EN);                             // alarm 0 off while it is set up
   rd (RTCSEC, &sec);
   uint32_t at = bcd_inc (sec & 0x7F, 2);
   wr (ALM0SEC, at);
   wr (ALM0WKDAY, wk & 7);                                  // ALMPOL 0, mask 000, clears ALM0IF
   rd (ALM0WKDAY, &a);
   check (0x02, 0, a & ALM0IF);
   wr (CONTROL, (ctl & ~0x40u) | ALM0EN);                   // SQWEN off, alarm 0 on
   puts_ ("rtc: alarm 0 at second "); puthex (at, 2); puts_ ("\r\n");
   int fired = 0;
   for (int i = 0; i < 200 && ! fired; i++) {               // up to ~4 s on the board
      uint32_t t0 = cycles (); while (cycles () - t0 < 1000000u) ;
      if (rd (ALM0WKDAY, &a) && (a & ALM0IF)) fired = 1;
      rd (RTCSEC, &sec);
      if (! fired && (sec & 0x7F) == bcd_inc (at, 3)) break;
   }
   check (0x03, 1, fired);
   wr (CONTROL, ctl & ~(ALM0EN | 0x40u));                   // alarm off
   wr (ALM0WKDAY, wk & 7);                                  // clear ALM0IF
   rd (ALM0WKDAY, &a);
   check (0x04, 0, a & ALM0IF);
   rd (RTCSEC, &sec);
   puts_ ("rtc now "); puthex (sec, 2); puts_ (fired ? ", alarm fired\r\n" : ", alarm did not fire\r\n");
out:
   puts_ (errs ? "rtc_test: FAIL\r\n" : "rtc_test: ok\r\n");
   putc_ ('D');
   return errs;
}
