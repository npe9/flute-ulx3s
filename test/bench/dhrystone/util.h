// util.h for riscv-tests' Dhrystone on test/bench's runtime (replaces riscv-tests' benchmarks/common)
#ifndef DHRY_UTIL_H
#define DHRY_UTIL_H
#include "../bench_rt.h"
#define read_csr(reg) ({ unsigned long __v; __asm__ volatile ("csrr %0, " #reg : "=r" (__v)); __v; })
void bench_dhry_check (int, int, char, char, int, int);
static inline void setStats (int enable) { if (enable) bench_mark (); }
#endif
