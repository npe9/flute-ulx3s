// bench_rt.c: bare-metal runtime for test/bench (Dhrystone, CoreMark) on the ULX3S Flute SoC.
// Loaded at 0x80000000 by the UART boot loader (scripts/loader.py --no-banner).  Startup clears
// .bss and calls main (0, 0); output goes to the 16550 at 0xC0000000; time is mcycle (the system
// clock, 50 MHz on SYS_PLL=50 builds), cross-checked against the CLINT mtime (25 MHz).  A line
// "BENCH-DONE" ends every run (loader.py relays output until idle).
#include <stdint.h>
#include <stdarg.h>
#include "bench_rt.h"

__asm__ (".section .text.start\n.globl _start\n_start:\n"
         "  li sp, 0x81000000\n"
         "  la t0, __bss_start\n  la t1, __bss_end\n"
         "2: bgeu t0, t1, 3f\n  sw zero, 0(t0)\n  addi t0, t0, 4\n  j 2b\n"
         "3: li a0, 0\n  li a1, 0\n  call main\n  call bench_done\n1: j 1b\n.text\n");

#define REG(a) (*(volatile uint32_t *) (a))
#define UART_THR REG (0xC0000000)
#define UART_LSR REG (0xC0000014)
#define MTIME_LO REG (0x0200BFF8)
#define MTIME_HI REG (0x0200BFFC)

void bench_putc (char c) {
   if (c == '\n') bench_putc ('\r');
   while (! (UART_LSR & 0x20)) ;
   UART_THR = (uint8_t) c;
}
void uart_send_char (char c) { bench_putc (c); }     // CoreMark's ee_printf

uint64_t bench_cycles (void) {
   uint32_t hi, lo, hi2;
   do {
      __asm__ volatile ("csrr %0, mcycleh" : "=r" (hi));
      __asm__ volatile ("csrr %0, mcycle"  : "=r" (lo));
      __asm__ volatile ("csrr %0, mcycleh" : "=r" (hi2));
   } while (hi != hi2);
   return ((uint64_t) hi << 32) | lo;
}
uint64_t bench_instret (void) {
   uint32_t hi, lo, hi2;
   do {
      __asm__ volatile ("csrr %0, minstreth" : "=r" (hi));
      __asm__ volatile ("csrr %0, minstret"  : "=r" (lo));
      __asm__ volatile ("csrr %0, minstreth" : "=r" (hi2));
   } while (hi != hi2);
   return ((uint64_t) hi << 32) | lo;
}
uint64_t bench_mtime (void) {
   uint32_t hi, lo;
   do { hi = MTIME_HI; lo = MTIME_LO; } while (hi != MTIME_HI);
   return ((uint64_t) hi << 32) | lo;
}

// ---- a small printf: %d %i %u %x %X %s %c %%, with l / ll, width and zero pad
static void out_num (uint64_t v, int neg, unsigned base, int width, int zero, int upper) {
   char b [24]; int n = 0;
   const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
   do { b [n++] = dig [v % base]; v /= base; } while (v);
   if (neg) { if (zero) { bench_putc ('-'); width--; } else b [n++] = '-'; }
   while (width-- > n) bench_putc (zero ? '0' : ' ');
   while (n) bench_putc (b [--n]);
}
int bench_vprintf (const char *f, va_list ap) {
   for (; *f; f++) {
      if (*f != '%') { bench_putc (*f); continue; }
      f++;
      int zero = 0, width = 0, lng = 0;
      if (*f == '0') { zero = 1; f++; }
      while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
      while (*f == 'l') { lng++; f++; }
      switch (*f) {
      case 'd': case 'i': {
         int64_t v = (lng >= 2) ? va_arg (ap, long long) : (lng ? va_arg (ap, long) : va_arg (ap, int));
         out_num (v < 0 ? -(uint64_t) v : (uint64_t) v, v < 0, 10, width, zero, 0); break; }
      case 'u': case 'x': case 'X': {
         uint64_t v = (lng >= 2) ? va_arg (ap, unsigned long long)
                    : (lng ? va_arg (ap, unsigned long) : va_arg (ap, unsigned));
         out_num (v, 0, *f == 'u' ? 10 : 16, width, zero, *f == 'X'); break; }
      case 's': { const char *s = va_arg (ap, const char *); int n = 0;
         for (const char *p = s; *p; p++) n++;
         while (width-- > n) bench_putc (' ');
         while (*s) bench_putc (*s++); break; }
      case 'c': bench_putc ((char) va_arg (ap, int)); break;
      case '%': bench_putc ('%'); break;
      default:  bench_putc ('%'); bench_putc (*f); break;
      }
   }
   return 0;
}
int bench_printf (const char *f, ...) {
   va_list ap; va_start (ap, f); bench_vprintf (f, ap); va_end (ap); return 0;
}

// x / y to 3 decimals, without floating point
void bench_print_ratio (const char *label, uint64_t x, uint64_t y) {
   uint64_t m = y ? (x * 1000 + y / 2) / y : 0;
   bench_printf ("%s%llu.%03llu\n", label, m / 1000, m % 1000);
}

static uint64_t t_c0, t_i0, t_m0;
void bench_mark (void) { t_c0 = bench_cycles (); t_i0 = bench_instret (); t_m0 = bench_mtime (); }
void bench_report (const char *name, uint64_t work) {
   uint64_t c = bench_cycles () - t_c0, i = bench_instret () - t_i0, m = bench_mtime () - t_m0;
   bench_printf ("BENCH %s cycles=%llu instret=%llu mtime=%llu work=%llu\n", name, c, i, m, work);
   bench_print_ratio ("BENCH IPC ", i, c);
   bench_print_ratio ("BENCH mcycle/mtime (expect 2.000 at 50 MHz) ", c, m);
}

void bench_done (void) { bench_printf ("BENCH-DONE\n"); }
