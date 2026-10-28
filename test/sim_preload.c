// ================================================================
// BDPI blob preload for Repl_Boot_Tb (Bluesim).
//
// Loads templeos/build/ulx3s_repl.blob.bin into memory once, then serves
// 16-bit halfwords: halfword i = blob bytes {2i+1, 2i} little-endian,
// matching the W9825G6KH model layout (Sdram_Controller maps AXI
// 0x80000000 + X to model halfword index X>>1).
//
// Path is relative to the sim working directory (flute-ulx3s).
// ================================================================

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    if (!blob) {
        // $SIM_BLOB, else a local TempleOS build, else the committed prebuilt REPL.
        const char *path = getenv ("SIM_BLOB");
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

unsigned char c_sim_mode (void)
{
    pass_str = getenv ("SIM_PASS_STR");
    if (pass_str) pass_len = strlen (pass_str);
    return pass_str && pass_len ? 1 : 0;
}

unsigned long long c_sim_max_cycles (unsigned long long dflt)
{
    const char *s = getenv ("SIM_MAX_CYCLES");
    return s ? strtoull (s, NULL, 0) : dflt;
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
