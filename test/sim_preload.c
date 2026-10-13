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
        const char *path = "templeos/build/ulx3s_repl.blob.bin";
        FILE *f = fopen (path, "rb");
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
