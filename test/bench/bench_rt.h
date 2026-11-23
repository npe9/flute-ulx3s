// bench_rt.h: see bench_rt.c
#ifndef BENCH_RT_H
#define BENCH_RT_H
#include <stdint.h>
#include <stdarg.h>
void     bench_putc (char c);
uint64_t bench_cycles (void);
uint64_t bench_instret (void);
uint64_t bench_mtime (void);
int      bench_printf (const char *f, ...);
int      bench_vprintf (const char *f, va_list ap);
void     bench_print_ratio (const char *label, uint64_t x, uint64_t y);
void     bench_mark (void);                              // start the counters
void     bench_report (const char *name, uint64_t work); // cycles / instret / mtime since the mark
void     bench_done (void);
#endif
