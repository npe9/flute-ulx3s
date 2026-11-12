/* Freestanding /init for the F/D Linux boot: no libc.  Forks once; both processes, once a
 * second, load all 32 FP registers and fcsr with process-specific values, sleep (the kernel
 * switches to the other process, which loads its own), then store them back and compare
 * bit for bit: FP context save/restore across switches.  Each also recomputes a fixed
 * sqrt/div/fma chain in double and single and checks it against its first result.
 * The parent prints "tick N  uptime U s  fp ok" (the sim harness waits for "tick 2").
 * It also reads block 0 of /dev/mmcblk0 (microSD over spi-sifive + mmc_spi) once the card has
 * been probed (retried for 30 ticks) and prints "sd: sig XXXX first ..." or "sd: none".
 * The DVI framebuffer: it sets the scan-out to 320x240 RGB565 (simplefb's format) through
 * /dev/mem and prints "video: ..."; the banner and the tick lines also go to tty0 (fbcon).
 * Board devices (lx44): it mounts devtmpfs on /dev, prints the RTC's time ("rtc: ...", rtc-ds1307 on
 * i2c-ocores), whether the buttons (gpio-keys-polled) and the audio card are there, and from then on
 * one line per button press or release ("key CODE down|up").
 * Console commands (one line each, read once a tick): "poweroff" arms the RTC alarm 20 s ahead
 * through /sys/class/rtc/rtc0/wakealarm and powers off (syscon-poweroff, the shutdown pin; MFP
 * powers the board back on); "reboot" reloads the FPGA from flash (syscon-reboot, PROGRAMN). */
#define SYS_write 64
#define SYS_clone 220
#define SYS_getpid 172
#define SYS_clock_gettime64 403
#define SYS_openat 56
#define SYS_close 57
#define SYS_read 63
#define SYS_mmap2 222
#define SYS_ioctl 29
#define SYS_mount 40
#define SYS_reboot 142
#define SYS_sync 81
#define O_NONBLOCK 0x800
#define RTC_RD_TIME 0x80247009   /* _IOR('p', 0x09, struct rtc_time) */
#define AT_FDCWD (-100)
#define VIDEO_PAGE 0xc0010   /* 0xc0010000 >> 12: ID at +0, MODE at +4 */

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
static long sys6(long n, long a, long b, long c, long d, long e, long f)
{
	register long a7 asm("a7") = n, a0 asm("a0") = a, a1 asm("a1") = b, a2 asm("a2") = c,
		a3 asm("a3") = d, a4 asm("a4") = e, a5 asm("a5") = f;
	asm volatile ("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2), "r"(a3), "r"(a4), "r"(a5) : "memory");
	return a0;
}
static int slen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static long tty0 = -1;    /* fbcon, if the framebuffer is up */
static void puts1(const char *s)
{
	sys3(SYS_write, 1, (long)s, slen(s));
	if (tty0 >= 0) sys3(SYS_write, tty0, (long)s, slen(s));
}

/* Turn on the DVI scan-out in simplefb's format and open the framebuffer console. */
static void video_on(void)
{
	long fd = sys5(SYS_openat, AT_FDCWD, (long)"/dev/mem", 2 /* O_RDWR */ | 0x101000 /* O_SYNC */, 0, 0);
	if (fd < 0) { puts1("video: no /dev/mem\n"); return; }
	long p = sys6(SYS_mmap2, 0, 4096, 3 /* PROT_READ|WRITE */, 1 /* MAP_SHARED */, fd, VIDEO_PAGE);
	sys3(SYS_close, fd, 0, 0);
	if ((unsigned long)p >= 0xfffff000ul) { puts1("video: mmap failed\n"); return; }
	volatile u32 *v = (volatile u32 *)p;
	if (v[0] != 0x56494431) { puts1("video: none\n"); return; }
	v[1] = 2;
	tty0 = sys5(SYS_openat, AT_FDCWD, (long)"/dev/tty0", 1 /* O_WRONLY */, 0, 0);
	if (tty0 < 0) tty0 = -1;
	puts1(tty0 >= 0 ? "video: 320x240 RGB565 on DVI, console on tty0\n" : "video: on, no tty0\n");
}
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
static void put2(u32 v) { char b[3] = { '0' + v / 10 % 10, '0' + v % 10, 0 }; puts1(b); }

/* lx44 board devices.  keys_fd stays open for the tick loop. */
static long keys_fd = -1;
static long con_fd = -1;    /* /dev/console, non-blocking: console commands */
static void board_devices(void)
{
	long r = sys5(SYS_mount, (long)"devtmpfs", (long)"/dev", (long)"devtmpfs", 0, 0);
	if (r < 0) { puts1("devtmpfs: mount failed "); putu((u32)-r); puts1("\n"); }
	struct { int sec, min, hour, mday, mon, year, wday, yday, isdst; } tm;
	long fd = sys5(SYS_openat, AT_FDCWD, (long)"/dev/rtc0", 0, 0, 0);
	if (fd < 0) puts1("rtc: no /dev/rtc0\n");
	else {
		r = sys3(SYS_ioctl, fd, RTC_RD_TIME, (long)&tm);
		sys3(SYS_close, fd, 0, 0);
		if (r < 0) { puts1("rtc: read error "); putu((u32)-r); puts1(" (time not set?)\n"); }
		else {
			puts1("rtc: "); putu(tm.year + 1900); puts1("-"); put2(tm.mon + 1); puts1("-"); put2(tm.mday);
			puts1(" "); put2(tm.hour); puts1(":"); put2(tm.min); puts1(":"); put2(tm.sec); puts1("\n");
		}
	}
	keys_fd = sys5(SYS_openat, AT_FDCWD, (long)"/dev/input/event0", O_NONBLOCK, 0, 0);
	puts1(keys_fd >= 0 ? "keys: /dev/input/event0\n" : "keys: none\n");
	fd = sys5(SYS_openat, AT_FDCWD, (long)"/dev/snd/controlC0", 0, 0, 0);
	if (fd >= 0) sys3(SYS_close, fd, 0, 0);
	puts1(fd >= 0 ? "audio: card 0\n" : "audio: none\n");
	con_fd = sys5(SYS_openat, AT_FDCWD, (long)"/dev/console", O_NONBLOCK, 0, 0);
}
/* console commands; con_fd is /dev/console opened non-blocking (canonical mode: whole lines) */
static int streq(const char *a, const char *b) { while (*a && *a == *b) a++, b++; return *a == *b; }
static void write_file(const char *path, const char *v)
{
	long fd = sys5(SYS_openat, AT_FDCWD, (long)path, 1 /* O_WRONLY */, 0, 0);
	long r = fd < 0 ? fd : sys3(SYS_write, fd, (long)v, slen(v));
	if (fd >= 0) sys3(SYS_close, fd, 0, 0);
	puts1(path); puts1(r < 0 ? ": write failed " : ": ok\n");
	if (r < 0) { putu((u32)-r); puts1("\n"); }
}
static void console_poll(void)
{
	static char line[64];
	if (con_fd < 0) return;
	long n = sys3(SYS_read, con_fd, (long)line, sizeof line - 1);
	if (n <= 0) return;
	while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) n--;
	line[n] = 0;
	if (streq(line, "poweroff")) {
		sys5(SYS_mount, (long)"sysfs", (long)"/sys", (long)"sysfs", 0, 0);
		write_file("/sys/class/rtc/rtc0/wakealarm", "0");
		write_file("/sys/class/rtc/rtc0/wakealarm", "+20");
		puts1("poweroff: wake in 20 s\n");
		sys3(SYS_sync, 0, 0, 0);
		sys5(SYS_reboot, 0xfee1dead, 672274793, 0x4321fedc /* POWER_OFF */, 0, 0);
		puts1("poweroff: still running\n");
	} else if (streq(line, "reboot")) {
		puts1("reboot: reconfigure from flash\n");
		sys3(SYS_sync, 0, 0, 0);
		sys5(SYS_reboot, 0xfee1dead, 672274793, 0x01234567 /* RESTART */, 0, 0);
		puts1("reboot: still running\n");
	} else if (n) { puts1("commands: poweroff, reboot\n"); }
}
/* button events since the last call: struct input_event on rv32 (time64) is 16 bytes */
static void keys_poll(void)
{
	struct { u32 sec, usec; unsigned short type, code; int value; } ev[8];
	if (keys_fd < 0) return;
	long n = sys3(SYS_read, keys_fd, (long)ev, sizeof ev);
	for (long i = 0; n > 0 && i < n / (long)sizeof ev[0]; i++)
		if (ev[i].type == 1 /* EV_KEY */ && ev[i].value != 2) {
			puts1("key "); putu(ev[i].code); puts1(ev[i].value ? " down\n" : " up\n");
		}
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
	int sd_done = (tag != 1);
	for (u32 n = 1;; n++) {
		if (! sd_done) {
			long fd = sys5(SYS_openat, AT_FDCWD, (long)"/dev/mmcblk0", 0, 0, 0);
			if (fd >= 0) {
				static unsigned char blk[512];
				long r = sys3(SYS_read, fd, (long)blk, 512);
				sys3(SYS_close, fd, 0, 0);
				if (r == 512) {
					puts1("sd: sig "); putx((u32)blk[510] << 8 | blk[511]);
					puts1(" first "); putx((u32)blk[0] << 24 | blk[1] << 16 | blk[2] << 8 | blk[3]);
					puts1("\n");
				} else { puts1("sd: read error\n"); }
				sd_done = 1;
			} else if (n >= 30) { puts1("sd: none\n"); sd_done = 1; }
		}
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
			keys_poll();
			console_poll();
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
	board_devices();
	video_on();
	puts1("\nHello from Linux user space on Flute RV32IMAFDC (ULX3S): FP context test\n");
	long pid = sys5(SYS_clone, 17 /* SIGCHLD */, 0, 0, 0, 0);
	if (pid < 0) { puts1("clone failed\n"); run(1); }
	run(pid == 0 ? 2 : 1);
}

asm(".globl _start\n_start:\n  .option push\n  .option norelax\n  la gp, __global_pointer$\n  .option pop\n  call _start_c\n1: j 1b\n");
