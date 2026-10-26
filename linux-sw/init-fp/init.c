/* Freestanding /init for the F/D Linux boot: no libc.  Forks once; both processes, once a
 * second, load all 32 FP registers and fcsr with process-specific values, sleep (the kernel
 * switches to the other process, which loads its own), then store them back and compare
 * bit for bit: FP context save/restore across switches.  Each also recomputes a fixed
 * sqrt/div/fma chain in double and single and checks it against its first result.
 * The parent prints "tick N  uptime U s  fp ok" (the sim harness waits for "tick 2"). */
#define SYS_write 64
#define SYS_clone 220
#define SYS_getpid 172
#define SYS_clock_gettime64 403

typedef unsigned int u32;
typedef unsigned long long u64;
struct ts64 { long long sec; long long nsec; };

static long sys3(long n, long a, long b, long c)
{
	register long a7 asm("a7") = n, a0 asm("a0") = a, a1 asm("a1") = b, a2 asm("a2") = c;
	asm volatile ("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
	return a0;
}
static long sys5(long n, long a, long b, long c, long d, long e)
{
	register long a7 asm("a7") = n, a0 asm("a0") = a, a1 asm("a1") = b, a2 asm("a2") = c,
		a3 asm("a3") = d, a4 asm("a4") = e;
	asm volatile ("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2), "r"(a3), "r"(a4) : "memory");
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
static void putx(u32 v)
{
	char b[9]; for (int i = 7; i >= 0; i--, v >>= 4) b[i] = "0123456789abcdef"[v & 15];
	b[8] = 0; puts1(b);
}

/* fld f0-f31 from a, fscsr fcsr, clock_nanosleep(CLOCK_MONOTONIC, 0, ts, 0), then fsd
 * f0-f31 to b; returns fcsr after the sleep.  Nothing between the loads and the stores
 * touches an FP register in user space. */
u32 fp_roundtrip(const u64 *a, u64 *b, u32 fcsr, const struct ts64 *ts);
asm(".globl fp_roundtrip\nfp_roundtrip:\n"
#define L(n) "  fld f" #n ", " #n "*8(a0)\n"
    L(0) L(1) L(2) L(3) L(4) L(5) L(6) L(7) L(8) L(9) L(10) L(11) L(12) L(13) L(14) L(15)
    L(16) L(17) L(18) L(19) L(20) L(21) L(22) L(23) L(24) L(25) L(26) L(27) L(28) L(29) L(30) L(31)
    "  fscsr a2\n"
    "  mv t1, a1\n"
    "  li a7, 407\n  li a0, 1\n  li a1, 0\n  mv a2, a3\n  li a3, 0\n  ecall\n"
    "  frcsr a0\n"
#define S(n) "  fsd f" #n ", " #n "*8(t1)\n"
    S(0) S(1) S(2) S(3) S(4) S(5) S(6) S(7) S(8) S(9) S(10) S(11) S(12) S(13) S(14) S(15)
    S(16) S(17) S(18) S(19) S(20) S(21) S(22) S(23) S(24) S(25) S(26) S(27) S(28) S(29) S(30) S(31)
    "  ret\n");

static u64 chain_d(int tag)
{
	volatile double x = 1.0 + tag;
	double s = 0.0;
	for (int i = 1; i <= 64; i++)
		s = __builtin_fma(__builtin_sqrt(x * i) , 1.0 / (i + 0.25), s);
	union { double d; u64 u; } r = { s }; return r.u;
}
static u32 chain_s(int tag)
{
	volatile float x = 2.0f + tag;
	float s = 0.0f;
	for (int i = 1; i <= 64; i++)
		s = __builtin_fmaf(__builtin_sqrtf(x * i), 1.0f / (i + 0.75f), s);
	union { float f; u32 u; } r = { s }; return r.u;
}

static void run(int tag)
{
	u64 a[32], b[32];
	for (int i = 0; i < 32; i++) {
		union { double d; u64 u; } v = { tag * 1000.0 + (double)i / 7.0 };
		a[i] = v.u;
	}
	/* frm RNE / RUP, and different sticky fflags, per process */
	u32 fcsr = (tag == 1) ? ((0u << 5) | 0x01) : ((3u << 5) | 0x10);
	/* the chains round with frm (dynamic rm): take the reference results under this
	 * process's frm */
	asm volatile ("fscsr %0" : : "r"(fcsr));
	u64 d0 = chain_d(tag); u32 s0 = chain_s(tag);
	struct ts64 one = { 1, 0 }, now;
	for (u32 n = 1;; n++) {
		u32 got = fp_roundtrip(a, b, fcsr, &one);
		int bad = (got != fcsr);
		for (int i = 0; i < 32; i++)
			if (a[i] != b[i]) {
				puts1("FP MISMATCH proc "); putu(tag); puts1(" f"); putu(i);
				puts1(" got "); putx((u32)(b[i] >> 32)); putx((u32)b[i]); puts1("\n");
				bad = 1;
			}
		if (got != fcsr) { puts1("FCSR MISMATCH proc "); putu(tag); puts1(" got "); putx(got); puts1("\n"); }
		if (chain_d(tag) != d0 || chain_s(tag) != s0) { puts1("FP CHAIN MISMATCH proc "); putu(tag); puts1("\n"); bad = 1; }
		if (tag == 1) {
			sys3(SYS_clock_gettime64, 1, (long)&now, 0);
			puts1("tick "); putu(n); puts1("  uptime "); putu((u32)now.sec);
			puts1(bad ? " s  fp BAD\n" : " s  fp ok\n");
		} else if ((n & 15) == 0) {
			puts1(bad ? "child fp BAD " : "child fp ok "); putu(n); puts1("\n");
		}
	}
}

void _start_c(void)
{
	puts1("\nHello from Linux user space on Flute RV32IMAFDC (ULX3S): FP context test\n");
	long pid = sys5(SYS_clone, 17 /* SIGCHLD */, 0, 0, 0, 0);
	if (pid < 0) { puts1("clone failed\n"); run(1); }
	run(pid == 0 ? 2 : 1);
}

asm(".globl _start\n_start:\n  .option push\n  .option norelax\n  la gp, __global_pointer$\n  .option pop\n  call _start_c\n1: j 1b\n");
