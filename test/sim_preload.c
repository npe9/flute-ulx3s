// ================================================================
// BDPI helpers for Repl_Boot_Tb (Bluesim): blob preload, the SDRAM model's array, console
// mode, and the host pty of the virtual board.
//
// Loads templeos/build/ulx3s_repl.blob.bin into memory once, then serves
// 16-bit halfwords: halfword i = blob bytes {2i+1, 2i} little-endian,
// matching the W9825G6KH model layout (Sdram_Controller maps AXI
// 0x80000000 + X to model halfword index X>>1).
//
// Path is relative to the sim working directory (flute-ulx3s).
// ================================================================

// glibc declares posix_openpt / ptsname (sim_pty.h) and cfmakeraw only with _GNU_SOURCE; without
// it ptsname is implicitly int and its pointer is truncated (segfault on the Linux CI runner).
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>

#include "sim_pty.h"

static unsigned char *blob      = NULL;
static unsigned int   blob_bytes = 0;

unsigned int   c_blob_open (void);
unsigned int   c_blob_halves (void);
unsigned short c_blob_half (unsigned int idx);

// Opens and slurps the blob file; RETURNS the halfword count.
// (One call serves both roles on the BSV side: bsc treats BDPI value
// functions as pure and reorders/CSEs them, so a separate open+count
// pair in one rule can execute in the wrong order.)
unsigned int c_blob_open (void)
{
    const char *path = getenv ("SIM_BLOB");
    if (path && strcmp (path, "none") == 0)
        return 0;                       // nothing preloaded: the boot ROM waits for a loader
    if (!blob) {
        // $SIM_BLOB, else a local TempleOS build, else the committed prebuilt REPL.
        FILE *f = NULL;
        if (path) f = fopen (path, "rb");
        else {
            path = "templeos/build/ulx3s_repl.blob.bin";
            f = fopen (path, "rb");
            if (!f) { path = "templeos/prebuilt/ulx3s_repl.blob.bin"; f = fopen (path, "rb"); }
        }
        if (!f) {
            fprintf (stderr, "[preload] cannot open %s\n", path);
            exit (1);
        }
        fseek (f, 0, SEEK_END);
        blob_bytes = (unsigned int) ftell (f);
        fseek (f, 0, SEEK_SET);
        blob = (unsigned char *) malloc (blob_bytes ? blob_bytes : 1);
        if (!blob || fread (blob, 1, blob_bytes, f) != blob_bytes) {
            fprintf (stderr, "[preload] failed to read %u bytes\n", blob_bytes);
            exit (1);
        }
        fclose (f);
        fprintf (stderr, "[preload] %s: %u bytes\n", path, blob_bytes);
    }
    return (blob_bytes + 1) / 2;
}

unsigned int c_blob_halves (void)
{
    return (blob_bytes + 1) / 2;
}

unsigned short c_blob_half (unsigned int idx)
{
    unsigned int lo = (2 * idx     < blob_bytes) ? blob [2 * idx]     : 0;
    unsigned int hi = (2 * idx + 1 < blob_bytes) ? blob [2 * idx + 1] : 0;
    return (unsigned short) (lo | (hi << 8));
}

// ---- SDRAM model array (W9825G6KH: 4 banks x 8192 rows x 512 cols x 16 bits) ----
// The TB's model addresses it as {bank, row, col}.  calloc: never-written memory reads as zero
// on every run (Bluesim's RegFile malloc was not zeroed, and zero-filling it cost 16M cycles).
unsigned int   c_mem_load (unsigned char map);
unsigned short c_mem_rd (unsigned int addr);
void           c_mem_wr (unsigned int addr, unsigned short data);

#define MEM_HALVES (1u << 24)
static unsigned short *mem = NULL;

static void mem_alloc (void)
{
    if (!mem && !(mem = (unsigned short *) calloc (MEM_HALVES, sizeof *mem))) {
        fprintf (stderr, "[preload] cannot allocate the SDRAM model\n");
        exit (1);
    }
}

// Model address of blob halfword idx (= byte offset from 0x80000000 / 2) under the controller's
// mapping.  map 0: bank = byte[10:9]:  {idx[10:9], idx[23:11], idx[8:0]}.
// map 1 (memlat controller, each 64-byte line in one bank/row):
//                                      {idx[6:5], idx[23:11], idx[10:7], idx[4:0]}.
static unsigned int mem_map (unsigned char map, unsigned int idx)
{
    if (map == 0)
        return ((idx & 0x600) << 13) | ((idx >> 2) & 0x3FFE00) | (idx & 0x1FF);
    return ((idx & 0x60) << 17) | ((idx >> 2) & 0x3FFE00) | ((idx >> 2) & 0x1E0) | (idx & 0x1F);
}

// Places the blob in the model; returns its halfword count.
unsigned int c_mem_load (unsigned char map)
{
    unsigned int n = c_blob_open (), i;
    mem_alloc ();
    if (n > MEM_HALVES) {
        fprintf (stderr, "[preload] blob larger than the 32 MB SDRAM\n");
        exit (1);
    }
    for (i = 0; i < n; i++)
        mem [mem_map (map, i) & (MEM_HALVES - 1)] = c_blob_half (i);
    return n;
}

unsigned short c_mem_rd (unsigned int addr)
{
    mem_alloc ();
    return mem [addr & (MEM_HALVES - 1)];
}

void c_mem_wr (unsigned int addr, unsigned short data)
{
    mem_alloc ();
    mem [addr & (MEM_HALVES - 1)] = data;
}

// ---- Console mode (Linux / any image that is judged on its console) ----
// SIM_PASS_STR set: the TB skips the REPL prompt/command phases and feeds every console byte here;
// the sim ends with a pass once the string has appeared.  SIM_MAX_CYCLES overrides the TB cap.
unsigned char c_sim_mode (void);
unsigned long long c_sim_max_cycles (unsigned long long dflt);
unsigned char c_console (unsigned char c);

static char  *pass_str  = NULL;
static size_t pass_len  = 0;
static size_t pass_hit  = 0;     // length of the matched prefix (naive scan, fine for short strings)
static char  *con       = NULL;
static size_t con_len   = 0, con_cap = 0;

// Interactive board mode (SIM_PTY=1, `make sim-board`): the SoC's UART is bridged to a host
// pseudo-terminal; attach with `picocom build/sim-tty` (or screen).  The link path is
// $SIM_PTY_LINK (default build/sim-tty).  A second pty, the board controls ($SIM_CTL_LINK,
// default build/sim-ctl), reports "leds XX" on every LED change and takes '1' / '0' to press /
// release BTN1:  cat build/sim-ctl;  printf 1 > build/sim-ctl.
static int pty_fd = -1, ctl_fd = -1;

static int pty_open (void)
{
    pty_fd = sim_pty_make ("SIM_PTY_LINK", "build/sim-tty", "UART (picocom, scripts/loader.py --sim, scripts/dmi.py)");
    if (pty_fd < 0) return 0;
    ctl_fd = sim_pty_make ("SIM_CTL_LINK", "build/sim-ctl", "board controls (cat: LED changes; write 1/0: press/release BTN1)");
    return 1;
}

// bit 0: SIM_PASS_STR set (console mode, pass on the string); bit 1: SIM_PTY (interactive);
// bit 2: SIM_BLOB=none (no preload and no jump header: the host's loader talks to the boot ROM).
unsigned char c_sim_mode (void)
{
    pass_str = getenv ("SIM_PASS_STR");
    if (pass_str) pass_len = strlen (pass_str);
    const char *p = getenv ("SIM_PTY");
    int pty = p && *p && strcmp (p, "0") != 0 && pty_open ();
    const char *b = getenv ("SIM_BLOB");
    int none = b && strcmp (b, "none") == 0;
    return (pass_str && pass_len ? 1 : 0) | (pty ? 2 : 0) | (none ? 4 : 0);
}

unsigned long long c_sim_max_cycles (unsigned long long dflt)
{
    const char *s = getenv ("SIM_MAX_CYCLES");
    if (s) return strtoull (s, NULL, 0);
    return pty_fd >= 0 ? 0xFFFFFFFFFFULL : dflt;    // interactive: run until killed
}

// Next host byte for the UART RX line: 0x100 | byte, or 0 when none is waiting.
unsigned short c_pty_getc (void)
{
    unsigned char b;
    return (pty_fd >= 0 && read (pty_fd, &b, 1) == 1) ? (unsigned short) (0x100 | b) : 0;
}

// Board controls: the BTN1 level after the bytes waiting on the control pty ('1' press, '0'
// release, anything else ignored); `cur` when nothing changed it.
// Byte-wide arguments are taken as unsigned int and masked: Bluesim passes Bit#(8) sign-extended
// (observed "leds ffffff80" on arm64), and with an unsigned char parameter the compiler drops the
// mask as a no-op.
unsigned char c_ctl_btn (unsigned int cur)
{
    cur &= 1;
    unsigned char b;
    while (ctl_fd >= 0 && read (ctl_fd, &b, 1) == 1)
        if (b == '0' || b == '1') cur = b - '0';
    return cur;
}

void c_ctl_leds (unsigned int leds, unsigned long long cycle)
{
    char line [48];
    int n = snprintf (line, sizeof line, "leds %02x cycle %llu\r\n", leds & 0xFFu, cycle);
    if (ctl_fd >= 0) (void) write (ctl_fd, line, n);
}

// A byte the SoC transmitted (dropped when nobody drains the pty and its buffer is full).
void c_pty_putc (unsigned char c)
{
    if (pty_fd >= 0) (void) write (pty_fd, &c, 1);
}

unsigned char c_console (unsigned char c)
{
    fputc (c, stdout);
    if (c == '\n') fflush (stdout);
    if (con_len + 1 >= con_cap) {
        con_cap = con_cap ? 2 * con_cap : 65536;
        con = (char *) realloc (con, con_cap);
    }
    con [con_len++] = (char) c;
    con [con_len] = 0;
    if (pass_len && con_len >= pass_len
        && memcmp (con + con_len - pass_len, pass_str, pass_len) == 0)
        pass_hit = 1;
    return pass_hit ? 1 : 0;
}
