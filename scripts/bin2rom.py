#!/usr/bin/env python3
"""Convert a raw binary image to the memhex word-per-line format expected by
Flute's Boot_ROM_Generator/Gen_BSV_fn_read_ROM.py.

Each output line is one 32-bit ROM word, printed most-significant byte
first (matching gen_bootrom.cc).  The image is zero-padded to a
multiple of 8 bytes (two words per 8-byte ROM pair read by Boot_ROM).
"""

import sys


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: bin2rom.py <bin> <memhex>\n")
        return 1
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    pad = (-len(data)) % 8
    data += b"\x00" * pad
    with open(sys.argv[2], "w") as f:
        for i in range(0, len(data), 4):
            w = data[i : i + 4]
            f.write("{:02x}{:02x}{:02x}{:02x}\n".format(w[3], w[2], w[1], w[0]))
    sys.stderr.write(
        "bin2rom: {} bytes (+{} pad) -> {}\n".format(len(data) - pad, pad, argv_out(sys.argv))
    )
    return 0


def argv_out(sys_argv):
    return sys_argv[2]


if __name__ == "__main__":
    sys.exit(main())
