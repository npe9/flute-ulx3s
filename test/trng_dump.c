// trng_dump: capture Zkr seed CSR words (ring-oscillator samples after decimation, 16 per word) for
// the SP 800-90B entropy estimators (scripts/trng_capture.py; notes/linux-isa-plan.md item 8).
// Waits for 'g' on the UART, then polls seed (csrrw: every access consumes) into SDRAM at 0x80100000
// as fast as it can, so a word's successor starts within a few samples, then sends:
//   "TRNG" u32le n_words u32le n_polls u32le n_bist u32le n_dead u32le cycles, then n_words u16le words.
// n_bist: polls that read BIST after a WAIT / ES16 (each a health-test failure); n_dead: polls reading DEAD.
// Build: riscv64-unknown-elf-gcc -march=rv32imac_zicsr -mabi=ilp32 -Os -ffreestanding
//   -nostdlib -nostartfiles -T test/sd_test.ld; objcopy -O binary; pad to 4 bytes.
#include <stdint.h>

__asm__ (".section .text.start\n.globl _start\n_start:\n"
         "  li sp, 0x81000000\n"
         "  la t0, __bss_start\n  la t1, __bss_end\n"
         "2: bgeu t0, t1, 3f\n  sw zero, 0(t0)\n  addi t0, t0, 4\n  j 2b\n"
         "3: call main\n1: j 1b\n.text\n");

#define REG(a) (*(volatile uint32_t *) (a))
#define UART_RBR REG (0xC0000000)
#define UART_THR REG (0xC0000000)
#define UART_LSR REG (0xC0000014)
#ifndef N_WORDS
#define N_WORDS  131072u                    // 2,097,152 samples (90B wants >= 1,000,000)
#endif
// (-DN_WORDS=63u: test/trng_restart.bin, 1008 samples per power-up for the restart test)
#define BUF      ((volatile uint16_t *) 0x80100000)

static void putc_ (uint8_t c) { while (! (UART_LSR & 0x20)) ; UART_THR = c; }
static void put32 (uint32_t v) { for (int i = 0; i < 4; i++) putc_ (v >> (8 * i)); }
static inline uint32_t seed (void) { uint32_t v; __asm__ volatile ("csrrw %0, 0x015, x0" : "=r" (v)); return v; }
static inline uint32_t cycles (void) { uint32_t c; __asm__ volatile ("rdcycle %0" : "=r" (c)); return c; }

int main (void) {
   while (1) {
      while (! (UART_LSR & 1)) ;
      if ((UART_RBR & 0xFF) == 'g') break;
   }
   uint32_t polls = 0, bist = 0, dead = 0, n = 0, prev = 0;
   uint32_t t0 = cycles ();
   while (n < N_WORDS) {
      uint32_t v = seed ();
      polls++;
      uint32_t op = v >> 30;
      if (op == 2) BUF[n++] = (uint16_t) v;
      else if (op == 0 && prev != 0) bist++;
      else if (op == 3) { dead++; if (dead > 1000000u) break; }
      prev = op;
   }
   uint32_t dt = cycles () - t0;
   putc_ ('T'); putc_ ('R'); putc_ ('N'); putc_ ('G');
   put32 (n); put32 (polls); put32 (bist); put32 (dead); put32 (dt);
   for (uint32_t i = 0; i < n; i++) { uint16_t w = BUF[i]; putc_ (w); putc_ (w >> 8); }
   return 0;
}
