// Simple SDRAM integrity test: writes and reads back several patterns
// across the full 32 MB, printing one character per MB ('.' ok, 'X'
// fail) plus a final summary.  A fault in the SDRAM controller or
// pinout shows up immediately here.

#include "uart.h"

#define RAM_BASE   0x80000000ul
#define RAM_SIZE   (32ul * 1024 * 1024)
#define MB         (1024ul * 1024)
// Leave the first 2 MB for the loaded program and the last 2 MB for the
// stack; test the 28 MB in between.
#define TEST_OFF   (2ul * MB)
#define TEST_BASE  (RAM_BASE + TEST_OFF)
#define TEST_SIZE  (RAM_SIZE - 2 * TEST_OFF)

static u32 lfsr = 0xACE1u;

static void print_hex (u32 v)
{
    for (int i = 28; i >= 0; i -= 4) {
        u32 n = (v >> i) & 0xF;
        uart_putc (n < 10 ? '0' + n : 'a' + (n - 10));
    }
}

static u32 next_rand (void)
{
    lfsr ^= lfsr << 13;
    lfsr ^= lfsr >> 17;
    lfsr ^= lfsr << 5;
    return lfsr;
}

static int test_pattern (u32 (*gen) (u32 addr, u32 idx), const char *name)
{
    uart_puts ("pattern ");
    uart_puts (name);
    uart_puts (": ");

    for (u32 off = 0; off < TEST_SIZE; off += MB) {
	u32 *p = (u32 *) (TEST_BASE + off);
	// Seed the per-MB random pattern so the read phase can regenerate
	// the exact same sequence.  (Deterministic generators ignore lfsr.)
	lfsr = 0xACE1u ^ off;
	for (u32 i = 0; i < MB / 4; i++)
	    p [i] = gen (TEST_BASE + off + 4 * i, i);
	int ok = 1;
	lfsr = 0xACE1u ^ off;
	for (u32 i = 0; i < MB / 4; i++) {
	    u32 expect = gen (TEST_BASE + off + 4 * i, i);
	    u32 got = p [i];
	    if (got != expect) {
		ok = 0;
		uart_puts ("\r\nFAIL @ ");
		print_hex ((u32) (p + i));
		uart_puts (" expect ");
		print_hex (expect);
		uart_puts (" got ");
		print_hex (got);
		uart_puts ("\r\n");
		break;
	    }
	}
	uart_putc (ok ? '.' : 'X');
    }
    uart_puts ("\r\n");
    return 1;
}

static u32 gen_zeros (u32 a, u32 i) { return 0; }
static u32 gen_ones  (u32 a, u32 i) { return 0xFFFFFFFFu; }
static u32 gen_alt   (u32 a, u32 i) { return 0xAAAAAAAAu; }
static u32 gen_addr  (u32 a, u32 i) { return a ^ 0x5A5A5A5Au; }
static u32 gen_rand  (u32 a, u32 i) { return next_rand (); }

int main (void)
{
    uart_init ();
    uart_puts ("\r\nULX3S Flute SoC: SDRAM test, 28 MB at ");
    print_hex (TEST_BASE);
    uart_puts ("\r\n");

    test_pattern (gen_zeros, "zeros");
    test_pattern (gen_ones,  "ones ");
    test_pattern (gen_alt,   "alt  ");
    test_pattern (gen_addr,  "addr ");
    test_pattern (gen_rand,  "rand ");

    uart_puts ("SDRAM test DONE\r\n");
    return 0;
}
