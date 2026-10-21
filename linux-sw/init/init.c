/* Minimal freestanding /init for the first Flute Linux boot: no libc.  Prints a banner, then
 * a tick line once a second using clock_nanosleep (timer interrupts, scheduler, syscalls,
 * U-mode Sv32 paging).  Syscall numbers: asm-generic (rv32 has only the time64 calls). */
#define SYS_write 64
#define SYS_clock_nanosleep_time64 407
#define SYS_clock_gettime64 403

typedef unsigned int u32;
struct ts64 { long long sec; long long nsec; };

static long sys3(long n, long a, long b, long c)
{
	register long a7 asm("a7") = n, a0 asm("a0") = a, a1 asm("a1") = b, a2 asm("a2") = c;
	asm volatile ("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
	return a0;
}
static long sys4(long n, long a, long b, long c, long d)
{
	register long a7 asm("a7") = n, a0 asm("a0") = a, a1 asm("a1") = b, a2 asm("a2") = c, a3 asm("a3") = d;
	asm volatile ("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2), "r"(a3) : "memory");
	return a0;
}
static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static void puts1(const char *s) { sys3(SYS_write, 1, (long)s, slen(s)); }
static void putu(u32 v)
{
	char b[12]; int i = 11; b[i] = 0;
	do { b[--i] = '0' + v % 10; v /= 10; } while (v);
	puts1(b + i);
}

void _start_c(void)
{
	puts1("\nHello from Linux user space on Flute RV32IMAC (ULX3S)\n");
	for (u32 n = 1;; n++) {
		struct ts64 d = { 1, 0 }, now;
		sys4(SYS_clock_nanosleep_time64, 1 /* CLOCK_MONOTONIC */, 0, (long)&d, 0);
		sys3(SYS_clock_gettime64, 1, (long)&now, 0);
		puts1("tick "); putu(n); puts1("  uptime "); putu((u32)now.sec); puts1(" s\n");
	}
}

asm(".globl _start\n_start:\n  .option push\n  .option norelax\n  la gp, __global_pointer$\n  .option pop\n  call _start_c\n1: j 1b\n");
