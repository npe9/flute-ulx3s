// esp32_bridge: the board's console UART (uart0, 1000000 baud) <-> the ESP32's UART0 (uart1,
// 115200 baud), with the ESP32 started in its ROM's download mode, so that esptool on the host
// reaches the ESP32 through the FPGA (scripts/esp32_bridge.py runs it and gives esptool a pty).
//
// Download mode: GPIO0 is held low by src/Top.v; gpio1 0x0C [2] STRAP drives GPIO2 (sd_d0) low
// while EN rises, then lets it go (src/Board_IO.v).  The ROM answers SYNC at 115200.
// The two links run at different rates, so each direction has a 16 KB ring; esptool waits for
// each answer, so the rings only ever hold one command or one reply.
//
// UART0: "esp32_bridge: ready\r\n" once, then only the ESP32's bytes.  It never returns: reload
// the bitstream to leave.  uart0's DMI bridge magic (src/Uart_DMI_Bridge.bsv) cannot occur in
// esptool's SLIP traffic (0xDB is only ever followed by 0xDC or 0xDD there).
// Build: riscv64-unknown-elf-gcc -march=rv32imac_zicsr -mabi=ilp32 -Os -ffreestanding
//   -nostdlib -nostartfiles -T sd_test.ld; objcopy -O binary; pad to 4 bytes.
#include <stdint.h>

__asm__ (".section .text.start\n.globl _start\n_start:\n"
         "  li sp, 0x81000000\n"
         "  la t0, __bss_start\n  la t1, __bss_end\n"
         "2: bgeu t0, t1, 3f\n  sw zero, 0(t0)\n  addi t0, t0, 4\n  j 2b\n"
         "3: call main\n1: j 1b\n.text\n");

#define REG(a) (*(volatile uint32_t *) (a))
#define U0(o)    REG (0xC0000000 + (o))
#define U1(o)    REG (0xC0007000 + (o))
#define ESP32_EN REG (0xC000800C)
enum { RBR = 0x00, THR = 0x00, LSR = 0x14 };
enum { DR = 0x01, THRE = 0x20 };
#define RING 16384u

static uint8_t to_esp [RING], to_host [RING];
static uint32_t te_h, te_t, th_h, th_t;

static inline uint32_t cycles (void) { uint32_t c; __asm__ volatile ("rdcycle %0" : "=r" (c)); return c; }
static void wait_ms (uint32_t ms) { uint32_t t0 = cycles (); while (cycles () - t0 < ms * 50000u) ; }
static void puts0 (const char *s) {
   for (; *s; s++) { while (! (U0 (LSR) & THRE)) ; U0 (THR) = (uint8_t) *s; }
}

int main (void) {
   ESP32_EN = 0;                         // hold in reset, STRAP off
   wait_ms (50);
   ESP32_EN = 4;                         // GPIO2 low, EN still low
   wait_ms (5);
   ESP32_EN = 5;                         // EN rises: GPIO0 low + GPIO2 low = download mode
   wait_ms (50);
   ESP32_EN = 1;                         // release GPIO2 (the SD card's DO again)
   while (U1 (LSR) & DR) (void) U1 (RBR);   // drop anything the ROM printed
   puts0 ("esp32_bridge: ready\r\n");
   for (;;) {
      // drain both receivers first: uart0 runs ~9x faster than uart1 can send
      while ((U0 (LSR) & DR) && te_h - te_t < RING) to_esp [te_h++ % RING] = (uint8_t) U0 (RBR);
      while ((U1 (LSR) & DR) && th_h - th_t < RING) to_host [th_h++ % RING] = (uint8_t) U1 (RBR);
      if (te_t != te_h && (U1 (LSR) & THRE)) U1 (THR) = to_esp [te_t++ % RING];
      if (th_t != th_h && (U0 (LSR) & THRE)) U0 (THR) = to_host [th_t++ % RING];
   }
}
