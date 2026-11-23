// formal/sw/sail/socdev.c: the game2d SoC's devices as the environment of a program running on
// the Sail RISC-V model (formal/sw/sail/soc-mmio.patch routes every word access in
// 0xC0000000-0xC1FFFFFF here, and every trap to soc_trap).  Tier 1 of
// notes/sw-verification-plan.md.
//
// Spec S1 (checked here): every device access is a word access to a register the device's
// spec defines, with the right direction (reads of read registers, writes of write
// registers); no trap of any kind (the title uses no interrupts and no ecall).  A violation
// prints "S1 VIOLATION" and exits 3 (trap) or 4 (access).
// Spec S2 (checked by formal/sw/fuzz.sh): the device-write trace written to $SOC_TRACE --
// "F" at each button read (once a frame, board.c), "W addr data" for each device write,
// UART excluded -- equals the host build's (formal/sw/host_trace.c).
//
// Environment (what a read returns), from the device specs:
//   buttons (0xC0008004): the next word of $SOC_BUTTONS (hex, one per frame; 0 after the end)
//   VDP_ID / APU_ID: their ID values;  UART LSR: THR empty;  video FRAME: advances.
//   SOC_CHAOS=<seed>: LSR's THR-empty bit and the frame counter's advance are random instead
//   (any value the hardware may show): the trace must not depend on them.
// The run ends (exit 0) when the program prints BENCH-DONE (bench_rt.c, after main returns), or
// with SOC_FRAMES=<n> at the (n+1)th button read: so the board's own binary (lantern.elf, which
// never returns) runs exactly n frames.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

typedef uint64_t mach_bits;
typedef int unit;

static FILE *trace, *btns;
static int init, chaos;
static uint32_t rng = 1, frame_ctr, nframes, maxframes;
static char uart [64]; static int un;

static void setup (void) {
   if (init) return;
   init = 1;
   const char *t = getenv ("SOC_TRACE"), *b = getenv ("SOC_BUTTONS"), *c = getenv ("SOC_CHAOS");
   trace = t ? fopen (t, "w") : NULL;
   if (t && !trace) { perror (t); exit (2); }
   btns = b ? fopen (b, "r") : NULL;
   if (b && !btns) { perror (b); exit (2); }
   if (c) { chaos = 1; rng = (uint32_t) strtoul (c, NULL, 0) | 1; }
   const char *f = getenv ("SOC_FRAMES");
   if (f) maxframes = (uint32_t) strtoul (f, NULL, 0);
}
static uint32_t xr (void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

static void violation (int code, const char *what, uint32_t a, uint32_t d) {
   fprintf (stderr, "S1 VIOLATION: %s %08x (data %08x) at frame %u\n", what, a, d, nframes);
   if (trace) { fprintf (trace, "X %s %08x\n", what, a); fclose (trace); }
   exit (code);
}

// the registers each device defines (sw/vdp/vdp.h, sw/apu/apu.h, README's video and audio maps)
static bool in (uint32_t a, uint32_t base, uint32_t bytes) { return a >= base && a - base < bytes; }
static bool writable (uint32_t a) {
   if (a == 0xC0000000u) return true;                                   // UART THR
   if (a == 0xC0009004u || a == 0xC0009008u) return true;               // audio CTRL, VOLUME
   if (a == 0xC0010004u) return true;                                   // video MODE
   if (in (a, 0xC0010400u, 256 * 4)) return true;                       // video palette
   if (a >= 0xC0020004u && a <= 0xC002000Cu) return true;               // VDP CTRL, SCROLL, BACKDROP
   if (a == 0xC0020010u) return true;                                   // VDP STATUS (clears)
   if (in (a, 0xC0020400u, 64 * 8)) return true;                        // VDP sprites
   if (in (a, 0xC1080000u, 2048 * 2)) return true;                      // VDP map
   if (in (a, 0xC1088000u, 8192 * 4)) return true;                      // VDP patterns
   if (a == 0xC0040004u || a == 0xC0040008u) return true;               // APU CTRL, MASTER
   if (a == 0xC0040014u || a == 0xC0040018u) return true;               // APU KEYON, KEYOFF
   if (in (a, 0xC0040100u, 8 * 0x20) && (a & 0x1F) != 0x1C) return true; // voice regs (ENV is RO)
   if (in (a, 0xC0048000u, 32768)) return true;                         // APU wave RAM
   return false;
}

mach_bits soc_read (mach_bits pa) {
   setup ();
   uint32_t a = (uint32_t) pa;
   if (a & 3) violation (4, "unaligned read", a, 0);
   switch (a) {
   case 0xC0000014u: return chaos ? (xr () & 0x20) : 0x20;              // UART LSR
   case 0xC0008004u: {                                                  // buttons: a new frame
      uint32_t v = 0;
      if (maxframes && nframes == maxframes) {                          // n frames done
         if (trace) fclose (trace);
         fprintf (stderr, "socdev: done, %u frames\n", nframes);
         exit (0);
      }
      if (btns && fscanf (btns, "%x", &v) != 1) v = 0;
      if (trace) fprintf (trace, "F\n");
      nframes++;
      return v;
   }
   case 0xC001000Cu: frame_ctr += chaos ? (xr () & 1) : 1; return frame_ctr; // video FRAME
   case 0xC0020000u: return 0x31504456u;                                // VDP_ID
   case 0xC0040000u: return 0x31555041u;                                // APU_ID
   }
   violation (4, "read of no readable register", a, 0);
   return 0;
}

unit soc_write (mach_bits pa, mach_bits data) {
   setup ();
   uint32_t a = (uint32_t) pa, d = (uint32_t) data;
   if (!writable (a)) violation (4, "write to no writable register", a, d);
   if (a == 0xC0000000u) {                                              // UART: watch for the end
      char ch = (char) d;
      fputc (ch, stderr);
      if (ch == '\r') return 0;                                       // bench_putc's CR LF
      if (un < (int) sizeof uart - 1) uart [un++] = ch;
      if (ch == '\n') {
         uart [un] = 0;
         if (!strcmp (uart, "BENCH-DONE\n")) {
            if (trace) fclose (trace);
            fprintf (stderr, "socdev: done, %u frames\n", nframes);
            exit (0);
         }
         un = 0;
      }
      return 0;
   }
   if (trace) fprintf (trace, "W %08x %08x\n", a, d);
   return 0;
}

unit soc_trap (bool intr, mach_bits cause, mach_bits pc) {
   setup ();
   char w [64];
   snprintf (w, sizeof w, "%s %u", intr ? "interrupt" : "exception", (unsigned) cause);
   violation (3, w, (uint32_t) pc, 0);
   return 0;
}
