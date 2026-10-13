// ================================================================
// ULX3S Flute SoC: first-stage boot loader, executed from the
// on-chip Boot ROM at reset (reset PC = 0x0000_1000).
//
// Protocol (little-endian, binary, over UART0 = 16550 @ 0xC0000000,
// register stride 4):
//   - host sends u32 dst address, u32 byte count, then the image
//   - word-aligned images use chunked framing: per 256-byte chunk the
//     host sends [seq, data, XOR] (seq = chunk index & 0xFF) and the
//     ROM ACKs (0x06) or drains ~0.5 s and NAKs (0x15) so the host
//     resends just that chunk; other (unaligned) images stream as raw
//     bytes with a stall watchdog
//   - if count == 0 the loader jumps to <dst> without loading
//   - after loading it prints a head/tail readback, waits ~24 s in a
//     repair window (send 0xA5 + a fresh header to load another
//     segment), then jumps to <dst>
// A new transfer can be started by resetting the board (FIRE1).
//
// Milestone LEDs (GPIO @ 0xC000_2000, active high):
//   LED0  FPGA/clock alive (set immediately)
//   LED1  executing boot ROM
//   LED2  UART initialized
//   LED3  SDRAM initialized (first word readback OK)
//   LED4  loader waiting / banner printed
//   LED5  kernel received
//   LED6  kernel readback OK
//   LED7  jumped to kernel
// ================================================================

typedef unsigned int  u32;
typedef unsigned char u8;

#define UART_BASE 0xC0000000ul
#define GPIO_BASE 0xC0002000ul
#define REG_RBR   0
#define REG_THR   0
#define REG_IER   1
#define REG_FCR   2
#define REG_LCR   3
#define REG_LSR   5

static volatile u32 *const uart = (volatile u32 *) UART_BASE;
static volatile u32 *const gpio = (volatile u32 *) GPIO_BASE;

static void set_leds (u32 v)
{
    gpio [0] = v;
}

static void putc (char c)
{
    while ((uart [REG_LSR] & 0x20) == 0) { }
    uart [REG_THR] = (u32) c;
}

static u32 getc (void)
{
    while ((uart [REG_LSR] & 0x01) == 0) { }
    return uart [REG_RBR] & 0xff;
}

// CLINT mtime (low word); ticks at the SoC clock (12.5 MHz).
static u32 mtime_lo (void)
{
    return *(volatile u32 *) 0x200BFF8;
}

// ---- Boot forensics recorder -------------------------------------------
// Progress and trap records live at the very top of SDRAM (the host never
// loads images up here), readable over the DMI system bus even when the
// CPU is wedged or abstract commands are unsupported -- the system bus
// does not touch the hart.  LEDs remain the pre-SDRAM-init progress
// channel (readable over DMI at GPIO_BASE).
#define FOREN_BASE        0x81FFFF80ul
#define FOREN_MAGIC_PGRS  0xF0E1D2C3ul
#define FOREN_MAGIC_TRAP  0x7A9C4E1Ful

static volatile u32 *const foren = (volatile u32 *) FOREN_BASE;

// Boot milestones: 1 SDRAM ok, 2 banner, 3 load-wait, 4 header rx,
// 5 chunk load active, 6 load done, 7 repair window, 8 jumping.
static void forensic_progress (u32 step)
{
    foren [0] = FOREN_MAGIC_PGRS;
    foren [1] = step;
}

static void forensic_trap (u32 mcause, u32 mepc, u32 mtval, u32 mstatus)
{
    foren [4] = FOREN_MAGIC_TRAP;
    foren [5] = mcause;
    foren [6] = mepc;
    foren [7] = mtval;
    foren [8] = mstatus;
    foren [9] += 1;    // trap count: grows under trap loops
}

// Assembly burst receive into a buffer.  Tight poll loop: per byte =
// LSR poll + RBR read + store + loop (~14 us at 12.5 MHz, under the 16 us
// wire cell at 625000 baud).  Per-byte stall watchdog: a gap > ~5 ms means
// a dropped byte; returns 0 so the caller can NAK just this chunk.
static u32 rx_burst (u8 *dst, u32 n)
{
    u32 ok;
    u32 tbase = mtime_lo ();
    __asm__ volatile (
	"1:\n\t"
	"lw   t0, 20(%[uart])\n\t"          // LSR
	"andi t0, t0, 1\n\t"
	"bnez t0, 2f\n\t"
	"lw   t1, 0(%[mt])\n\t"             // gap watchdog
	"sub  t2, t1, %[tb]\n\t"
	"li   t3, 600000\n\t"                // ~4.8 ms
	"bleu t2, t3, 1b\n\t"
	"li   %[ok], 0\n\t"
	"j    3f\n\t"
	"2:\n\t"
	"lw   t0, 0(%[uart])\n\t"           // RBR
	"sb   t0, 0(%[dst])\n\t"
	"addi %[dst], %[dst], 1\n\t"
	"addi %[n], %[n], -1\n\t"
	"lw   %[tb], 0(%[mt])\n\t"          // refresh gap base
	"bnez %[n], 1b\n\t"
	"li   %[ok], 1\n\t"
	"3:\n\t"
	: [dst] "+r" (dst), [n] "+r" (n), [ok] "=r" (ok), [tb] "+r" (tbase)
	: [uart] "r" ((u32) UART_BASE), [mt] "r" ((u32) 0x200BFF8)
	: "t0", "t1", "t2", "t3", "memory");
    return ok;
}

// getc with a receive stall watchdog: at 625000 baud a byte arrives every
// 16 us, and the consume loop averages ~24-30 us/byte, so a gap > ~5 ms
// means a byte was dropped (RX framing glitch / overflow) and the count-
// based receive would hang forever.  Returns 0 and *ok=0 on timeout.
#define GETC_TIMEOUT_TICKS 600000   // ~48 ms at 12.5 MHz: macOS USB bulk
    // delivery to a full-speed FTDI jitters by a few ms per burst, so the
    // watchdog must be well above that; a truly dropped byte still costs
    // only ~50 ms before the NAK.

static u32 getc_toh (u32 *ok)
{
    u32 t0 = mtime_lo ();
    while ((uart [REG_LSR] & 0x01) == 0) {
	if (mtime_lo () - t0 > GETC_TIMEOUT_TICKS) {
	    *ok = 0;
	    return 0;
	}
    }
    *ok = 1;
    return uart [REG_RBR] & 0xff;
}

static u32 get_u32 (void)
{
   u32 v = 0;
   for (int i = 0; i < 4; i++)
      v |= getc () << (8 * i);
   return v;
}

static void put_hex_u32 (u32 v)
{
   for (int i = 28; i >= 0; i -= 4) {
      u32 n = (v >> i) & 0xF;
      putc (n < 10 ? '0' + n : 'a' + (n - 10));
   }
}

// ----------------------------------------------------------------
// SDRAM self-test (fetch-safe: runs from Boot ROM BRAM).
// Triggered by sending 0xFFFFFFFF as the load address.
//
// Writes test patterns to SDRAM, evicts them from the L1 D-cache and
// the Mem_Controller line cache by sweeping a dummy region, then reads
// them back and reports every mismatch as  "M <addr> <exp> <got>".
// This distinguishes SDRAM read corruption from write corruption:
// mismatches here mean the write path corrupted the data (the read
// side is exercised after full eviction); add a second pass that
// re-reads immediately to compare cached vs uncached behaviour.

#define TEST_BASE  0x80020000ul    // away from the load address (0x80000000)
#define TEST_WORDS 64            // 256 bytes under test
#define DUMMY_BASE 0x80010000ul
#define DUMMY_WORDS 4096         // 16 KB sweep: evicts all 128 L1 lines

static void sdram_selftest (void)
{
    volatile u32 *t = (volatile u32 *) TEST_BASE;
    volatile u32 *d = (volatile u32 *) DUMMY_BASE;
    u32 errors = 0;

    putc ('S'); putc ('E'); putc ('L'); putc ('F');
    putc ('T'); putc ('E'); putc ('S'); putc ('T');
    putc ('\r'); putc ('\n');

    // Pass 1: 0xAAAA0000 + index, word granularity.
    for (u32 i = 0; i < TEST_WORDS; i++)
        t [i] = 0xAAAA0000u + i;

    // Evict: sweep the dummy region (L1 D-cache + Mem_Controller line).
    for (u32 i = 0; i < DUMMY_WORDS; i++)
        d [i] = i;

    for (u32 i = 0; i < TEST_WORDS; i++) {
        u32 exp = 0xAAAA0000u + i;
        u32 got = t [i];
        if (got != exp) {
            putc ('M'); putc (' ');
            put_hex_u32 ((u32) & t [i]);
            putc (' '); put_hex_u32 (exp);
            putc (' '); put_hex_u32 (got);
            putc ('\r'); putc ('\n');
            errors++;
        }
    }

    // Pass 2: inverse pattern, halfword granularity check via
    // 0x5A5A0000 | (~i << 16) so the high halfword varies per word.
    for (u32 i = 0; i < TEST_WORDS; i++)
        t [i] = 0xA5A50000u | ((~i & 0xFFFF) << 16);

    for (u32 i = 0; i < DUMMY_WORDS; i++)
        d [i] = i ^ 0xFFFFFFFFu;

    for (u32 i = 0; i < TEST_WORDS; i++) {
        u32 exp = 0xA5A50000u | ((~i & 0xFFFF) << 16);
        u32 got = t [i];
        if (got != exp) {
            putc ('N'); putc (' ');
            put_hex_u32 ((u32) & t [i]);
            putc (' '); put_hex_u32 (exp);
            putc (' '); put_hex_u32 (got);
            putc ('\r'); putc ('\n');
            errors++;
        }
    }

    putc ('D'); putc ('O'); putc ('N'); putc ('E');
    putc (' ');
    put_hex_u32 (errors);
    putc ('\r'); putc ('\n');

    while (1)
        __asm__ volatile ("");
}

// Simple trap handler in the Boot ROM. It records mcause/mepc/mtval to
// the DMI-readable forensic slot FIRST (UART-independent, so a trap
// before UART init is still captured), then prints and hangs.
static void __attribute__ ((aligned (4))) trap_hang (void)
{
    while (1)
        __asm__ volatile ("");
}

static void __attribute__ ((aligned (4))) trap_handler (void)
{
    u32 mcause, mepc, mtval, mstatus;
    __asm__ volatile ("csrr %0, mcause" : "=r" (mcause));
    __asm__ volatile ("csrr %0, mepc"   : "=r" (mepc));
    __asm__ volatile ("csrr %0, mtval"  : "=r" (mtval));
    __asm__ volatile ("csrr %0, mstatus": "=r" (mstatus));

    // If the record write itself faults (the wedge IS a memory-system
    // fault), spin at trap_hang instead of recursing into this handler.
    __asm__ volatile ("csrw mtvec, %0" :: "r" (trap_hang));
    forensic_trap (mcause, mepc, mtval, mstatus);

    putc ('E');
    put_hex_u32 (mcause);
    putc (' ');
    put_hex_u32 (mepc);
    putc (' ');
    put_hex_u32 (mtval);
    putc ('\r');
    putc ('\n');

    while (1)
        __asm__ volatile ("");
}

void real_start (void)
{
    // LED0: clock/FPGA alive
    set_leds (0x01);

    uart [REG_LCR] = 0x03;    // 8N1
    uart [REG_IER] = 0x00;    // polling only, no interrupts
    uart [REG_FCR] = 0x07;    // enable + clear 16550 RX/TX FIFOs (16-deep)

    // LED2: UART initialized
    set_leds (0x05);

    // SDRAM self-test: write magic patterns and read them back.
    // Done at the top of RAM (not near 0x80000000) so the dirty
    // line-cache state from the test cannot interfere with a
    // subsequently loaded image's first words.
    {
        volatile u32 *sdram = (volatile u32 *) 0x81FFFF00ul;
        sdram [0] = 0x12345678;
        sdram [1] = 0x9abcdef0;
        u32 r0 = sdram [0];
        u32 r1 = sdram [1];
        putc ('T');
        put_hex_u32 (r0);
        putc (' ');
        put_hex_u32 (r1);
        putc ('\r');
        putc ('\n');

        // LED3: SDRAM readback returned non-zero; forensics: SDRAM usable
        if (r0 != 0 && r1 != 0) {
            set_leds (0x0d);
            forensic_progress (1);
        }
    }

    static const char banner [] = "\r\nULX3S Flute SoC: boot loader\r\n";
    forensic_progress (2);

    // Print the banner, but watch the receiver after every character
    // so we can switch to the load protocol before the 16-byte 16550
    // RX FIFO overflows.
    while (1) {
	for (const char *p = banner; *p; p++) {
	    if (uart [REG_LSR] & 0x01)
		goto load_protocol;
	    putc (*p);
	}
	// crude ~0.1 s delay at 12.5 MHz, also polling
	for (volatile u32 d = 0;
	     d < 500000 && ((uart [REG_LSR] & 0x01) == 0);
	     d++)
	    __asm__ volatile ("");
    }

load_protocol:
    // LED1: executing boot ROM protocol + LED4: loader waiting
    set_leds (0x13);
    forensic_progress (3);

    while (1) {
    receive_header:
	u32 addr = get_u32 ();

	if (addr == 0xFFFFFFFFul)
	    sdram_selftest ();

	// Diagnostic peek: read back 8 words at 0x80000000 through the
	// D-cache/SDRAM path and print them, then hang.  Lets a sim or
	// hardware host verify a preloaded image without jumping to it.
	if (addr == 0xFFFFFFFEul) {
	    volatile u32 *w = (volatile u32 *) 0x80000000ul;
	    putc ('[');
	    for (int i = 0; i < 8; i++) {
		if (i > 0) putc (' ');
		put_hex_u32 (w [i]);
	    }
	    putc (']');
	    putc ('\r');
	    putc ('\n');
	    while (1)
		__asm__ volatile ("");
	}

	u32 len  = get_u32 ();
	forensic_progress (4);

	u8 *bp  = (u8 *) addr;

	// Chunked receive for word-aligned images: 256-byte chunks framed as
	//   [seq, 256 data bytes, XOR checksum, 0x55 pad]
	// where seq = (chunk index & 0xFF).  The seq byte anchors the chunk
	// to its POSITION: a stray byte released into the RX pipe after a
	// NAK (the UART DMI bridge can hold a 0xDB for up to ~10 ms past a
	// drain window) is caught -- either it lands in the seq slot and
	// mismatches (drain + NAK + resend), or it coincidentally equals
	// seq and is consumed THERE, leaving the data that follows aligned
	// (the image stores correctly either way).  A position-independent
	// XOR alone cannot do this: [0xDB, b0..b254] + b255-as-checksum
	// passes the XOR by construction when the inserted byte equals the
	// chunk's real XOR -- this exact corruption reached SDRAM and
	// crashed the kernel before seq framing existed.
	//
	// The trailing 0x55 pad guarantees the checksum byte is NEVER the
	// last byte on the wire.  The DMI bridge parks a trailing 0xDB in
	// its magic-match state for a ~10 ms idle timeout before releasing
	// it to the console -- in hardware that release has been observed
	// to land inside the NEXT chunk (or past the ROM's 48 ms receive
	// watchdog), deterministically wedging any chunk whose checksum
	// happens to equal 0xDB.  With a non-magic pad behind it, the 0xDB
	// is released by the very next byte's mismatch replay (~16 us, in
	// order) and the 10 ms timeout path never runs during a load.
	//
	// On seq/checksum mismatch or a receive stall we first drain the RX
	// pipe for ~0.5 s -- the failed chunk's tail is still dribbling out
	// of the macOS/FTDI/USB buffers and would poison an immediate
	// retry -- and only then NAK (0x15); the host resends just this
	// chunk on a guaranteed-clean pipe.  A dropped byte never costs a
	// whole-image restart.  The host ACK-paces the wire, so the 16-deep
	// RX FIFOs never overrun even though the poll loop (~14 us/byte)
	// only barely beats the wire (16 us/byte).
	if ((((u32) addr) & 3) == 0 && (len & 3) == 0 && len != 0) {
	    u8 cbuf [256];
	    u32 off = 0;
	    while (off < len) {
		u32 m = (len - off < 256) ? (len - off) : 256;
		u32 oks, okx, okp;
		u32 sq = getc_toh (&oks);
		u32 good = rx_burst (cbuf, m);
		u32 xo = getc_toh (&okx);
		u32 pad = getc_toh (&okp);   // sacrificial: never let the XOR
					     // byte be last on the wire (see
					     // framing note above)
		u32 xs = 0;
		for (u32 i = 0; i < m; i++)
		    xs ^= cbuf [i];
		if (! oks || ! good || ! okx || ! okp
		    || sq != ((off >> 8) & 0xFF)
		    || xs != xo) {
		    // Drain whatever the host still has in flight (its OS/USB
		    // buffers hold the unsent tail of this chunk); a retried
		    // chunk must start on a clean pipe.  ~0.48 s at 12.5 MHz
		    // is ~100x the wire time of a full stale chunk.
		    {
			u32 t0 = mtime_lo ();
			while (mtime_lo () - t0 < 6000000)
			    if (uart [REG_LSR] & 0x01)
				(void) uart [REG_RBR];
		    }
		    // Diagnostic NAK line (ASCII only, never 0x06/0x15 inside):
		    // NAK N <seq> <xor> <flags>  with flags = s/g/x for
		    // oks/good/okx ok, '-' for timeout/fail.  Tells the host
		    // exactly which check failed and what values arrived.
		    putc (0x15);              // NAK: host resends this chunk
		    putc ('N');
		    putc (' ');
		    put_hex_u32 (sq);
		    putc (' ');
		    put_hex_u32 (xo);
		    putc (' ');
		    putc (oks ? 's' : '-');
		    putc (good ? 'g' : '-');
		    putc (okx ? 'x' : '-');
		    putc ('\r');
		    putc ('\n');
		    continue;
		}
		for (u32 i = 0; i < m; i += 4)
		    *(volatile u32 *) (bp + off + i) =
			((u32) cbuf [i])
			| ((u32) cbuf [i + 1] << 8)
			| ((u32) cbuf [i + 2] << 16)
			| ((u32) cbuf [i + 3] << 24);
		putc (0x06);                  // ACK
		off += m;
		if ((off & 0xFFFF) == 0)
		    putc ('.');
	    }
	    forensic_progress (5);
	    goto load_done;
	}

	u32 acc = 0;
	u32 rem = 0;
	u32 rxleft = len;

	while (rxleft > 0) {
	    if (((len - rxleft) & 0xFFF) == 0) putc ('.');

	    // Drain the 16550 RX FIFO in one quick burst so the FIFO never
	    // overflows while we are writing previous bytes to SDRAM.
	    u8 buf [16];
	    u32 n = rxleft < 16 ? rxleft : 16;
	    for (u32 i = 0; i < n; i++) {
		u32 ok;
		buf [i] = (u8) getc_toh (&ok);
		if (! ok) {
		    putc ('\r'); putc ('\n');
		    const char *m_ = "LOAD STALL\r\n"; while (*m_) putc (*m_++);
		    // Drain whatever the host still has in flight (its OS/USB
		    // buffers hold the unsent tail of the image); the host waits
		    // out this drain before re-sending from scratch.
		    {
			u32 t0 = mtime_lo ();
			while (mtime_lo () - t0 < 40000000)   // ~3.2 s
			    if (uart [REG_LSR] & 0x01)
				(void) uart [REG_RBR];
		    }
		    goto receive_header;
		}
	    }

	    // Unpack the burst into memory, preserving the original byte-at-a-time
	    // behaviour so unaligned dst/len work correctly.
	    for (u32 i = 0; i < n; i++) {
		acc |= ((u32) buf [i]) << (8 * rem);
		rem++;
		if (rem == 4) {
		    *(volatile u32 *) bp = acc;
		    bp += 4;
		    acc = 0;
		    rem = 0;
		}
	    }

	    rxleft -= n;
	}

	// Flush any trailing partial word with a read-modify-write so we never
	// issue a sub-word store (the byte-store path is suspect).
	if (rem != 0) {
	    u32 mask = (1u << (8 * rem)) - 1;
	    volatile u32 *wp = (volatile u32 *) bp;
	    u32 old = *wp;
	    *wp = (old & ~mask) | (acc & mask);
	}

    load_done:
	if (len != 0)
	    putc ('\r'), putc ('\n');

	// LED5: kernel received
	set_leds (0x33);
	forensic_progress (6);

	// Diagnostic: read back the first several words of the loaded image,
	// plus the last 8 words -- a lost ACK shifts every subsequent chunk
	// by one position, which leaves the head intact but corrupts the
	// tail, so the host verifies both ends.
	if (len >= 4) {
	    volatile u32 *w = (volatile u32 *) addr;
	    putc ('[');
	    for (int i = 0; i < 8 && (u32)(i * 4) < len; i++) {
		if (i > 0) putc (' ');
		put_hex_u32 (w [i]);
	    }
	    if (len >= 32) {
		volatile u32 *t = (volatile u32 *) (addr + len - 32);
		putc (' '); putc (':'); putc (' ');
		for (int i = 0; i < 8; i++) {
		    if (i > 0) putc (' ');
		    put_hex_u32 (t [i]);
		}
	    }
	    putc (']');
	    putc ('\r');
	    putc ('\n');

	    // LED3/6: if SDRAM readback looks like real code, light them
	    if (w [0] != 0)
		set_leds (0x7f);

	    // Repair-load window: if the host sends the 0xA5 marker within
	    // ~24 s followed by a fresh header, loop back and receive it.
	    // This enables segmented loads that heal UART byte-drops
	    // mid-stream (a drop shifts all subsequent data; reloading from
	    // the first-divergence offset repairs it without re-streaming
	    // the whole image).  Any other byte (e.g. the host's CR pad) is
	    // discarded as junk.  Idle unit = one LSR-poll
		    // iteration (~150 cycles @12.5 MHz); 2M iterations ~ 24 s.
		    // (The old 60M count looked like ~30 s but was really ~12 min.)
	    {
		u32 idle = 0;
		forensic_progress (7);
		while (1) {
		    if (uart [REG_LSR] & 0x01) {
			if (getc () == 0xA5)
			    break;
			idle = 0;            // junk: keep waiting
			continue;
		    }
		    if (++idle > 2000000)
			goto jump_to_kernel;
		}
		continue;
	    }
	}

jump_to_kernel:
	// Make the loaded image visible to the I-cache and memory system
	__asm__ volatile ("fence");
	__asm__ volatile ("fence.i");

	// Install a trap handler so we can report the reason if the loaded
	// image crashes instead of silently restarting at mtvec=0x1000.
	__asm__ volatile ("csrw mtvec, %0" :: "r" (trap_handler));

	// LED7: jumped to kernel
	set_leds (0xff);
	forensic_progress (8);

	void (*entry) (void) = (void (*) (void)) addr;
	entry ();
    }
}
