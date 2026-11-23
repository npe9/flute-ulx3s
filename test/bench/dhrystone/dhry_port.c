// dhry_port.c: printf (debug_printf is dhrystone.c's no-op) for riscv-tests' Dhrystone on test/bench's runtime, and a
// check of the final values the benchmark itself says they should be ("BENCH-CHECK OK").
#include <stdarg.h>
#include "../bench_rt.h"
int printf (const char *f, ...) { va_list ap; va_start (ap, f); bench_vprintf (f, ap); va_end (ap); return 0; }
void bench_dhry_check (int int_glob, int bool_glob, char ch1, char ch2, int arr1_8, int arr2_87_less_runs) {
   int ok = int_glob == 5 && bool_glob == 1 && ch1 == 'A' && ch2 == 'B' && arr1_8 == 7
            && arr2_87_less_runs == 10;
   bench_printf ("BENCH-CHECK %s\n", ok ? "OK" : "FAIL");
}
