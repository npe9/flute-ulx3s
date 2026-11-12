// esp32_test: bare-metal check of uart1 (a second UART_Model 16550 at a fixed 115200 baud) and the
// ESP32 EN register (gpio1 0x0C, src/Board_IO.v).  src/Top.v holds the ESP32's GPIO0 low, so a
// released ESP32 can only start its ROM bootloader, never its flashed firmware.
//
// Default build (CI): the strict bench loops the ESP32's RX to its TX while EN is high (a stand-in,
// not the ROM).  Checks EN resets to held, nothing comes back while held, bytes come back released.
//
// -DBOARD builds esp32_probe for the ULX3S: hold, release into the ROM, print what the ROM says,
// send esptool's SYNC packet (SLIP) and look for the ROM's SYNC reply, hold again.
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
#define U1(o)    REG (0xC0007000 + (o))
#define ESP32_EN REG (0xC000800C)
enum { RBR = 0x00, THR = 0x00, LSR = 0x14 };
enum { DR = 0x01, THRE = 0x20 };
#define CLK_HZ 50000000u

static void putc_ (char c) { while (! (UART_LSR & THRE)) ; UART_THR = c; }
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
static void u1_put (uint32_t b) { while (! (U1 (LSR) & THRE)) ; U1 (THR) = b & 0xFF; }
// a byte within t cycles, or -1
static int u1_get (uint32_t t) {
   uint32_t t0 = cycles ();
   while (! (U1 (LSR) & DR)) if (cycles () - t0 > t) return -1;
   return U1 (RBR) & 0xFF;
}

#ifndef BOARD
int main (void) {
   putc_ ('T');
   check (0x01, 0, ESP32_EN);
   check (0x02, THRE, U1 (LSR) & (THRE | DR));
   u1_put ('A');                                   // held: the stand-in does not answer
   check (0x03, (uint32_t) -1, (uint32_t) u1_get (20000));
   ESP32_EN = 1;
   check (0x04, 1, ESP32_EN);
   static const uint8_t bytes [] = { 0x55, 0xC0, 0x12, 0x00, 0xFF };
   for (unsigned i = 0; i < sizeof bytes; i++) {
      u1_put (bytes [i]);
      check (0x10 + i, bytes [i], (uint32_t) u1_get (20000));
   }
   ESP32_EN = 0;
   check (0x05, 0, ESP32_EN);
   puts_ (errs ? "esp32_test: FAIL\r\n" : "esp32_test: ok\r\n");
   putc_ ('D');
   return errs;
}
#else
static uint8_t buf [512];
static unsigned collect (uint32_t ms) {
   unsigned n = 0; int c;
   uint32_t t0 = cycles ();
   while (cycles () - t0 < ms * (CLK_HZ / 1000))
      if ((c = u1_get (CLK_HZ / 1000)) >= 0 && n < sizeof buf) buf [n++] = c;
   return n;
}
static void dump (unsigned n) {
   for (unsigned i = 0; i < n; i++) {
      uint8_t c = buf [i];
      if (c == '\n' || c == '\r' || (c >= 0x20 && c < 0x7F)) putc_ (c);
      else { putc_ ('<'); puthex (c, 2); putc_ ('>'); }
   }
   puts_ ("\r\n");
}
int main (void) {
   putc_ ('T');
   ESP32_EN = 0;
   collect (50);                                   // held in reset; drain
   puts_ ("esp32_probe: released into the ROM bootloader (GPIO0 low)\r\n");
   ESP32_EN = 1;
   unsigned n = collect (400);
   puts_ ("rom says ("); puthex (n, 3); puts_ (" bytes):\r\n");
   dump (n);
   // esptool SYNC: C0 | dir 00, cmd 08, len 0x0024, checksum 0 | 07 07 12 20, 32 x 55 | C0
   int synced = 0;
   for (int tries = 0; tries < 5 && ! synced; tries++) {
      static const uint8_t hdr [] = { 0xC0, 0x00, 0x08, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00,
                                      0x07, 0x07, 0x12, 0x20 };
      for (unsigned i = 0; i < sizeof hdr; i++) u1_put (hdr [i]);
      for (int i = 0; i < 32; i++) u1_put (0x55);
      u1_put (0xC0);
      n = collect (100);
      for (unsigned i = 0; i + 2 < n; i++)
         if (buf [i] == 0xC0 && buf [i + 1] == 0x01 && buf [i + 2] == 0x08) synced = 1;
      puts_ ("sync reply ("); puthex (n, 3); puts_ (" bytes): ");
      for (unsigned i = 0; i < n && i < 24; i++) { puthex (buf [i], 2); putc_ (' '); }
      puts_ ("\r\n");
   }
   ESP32_EN = 0;
   puts_ (synced ? "esp32_probe: the ROM answered SYNC; held in reset again\r\n"
                 : "esp32_probe: no SYNC reply; held in reset again\r\n");
   putc_ ('D');
   return 0;
}
#endif
