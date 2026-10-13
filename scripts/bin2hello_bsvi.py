#!/usr/bin/env python3
"""Regenerate test/fn_hello_bytes.bsvi from a binary image (default
sw/hello.bin) for SoC_Boot_Tb.  Emits fn_hello_len() alongside
fn_hello_bytes(i) so the tb's loader header tracks the image instead of
hardcoding length bytes (stale length = silent loader desync)."""
import pathlib
import sys

bin_path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "sw/hello.bin")
out_path = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "test/fn_hello_bytes.bsvi")
data = bin_path.read_bytes()

lines = [
    "// generated from %s by scripts/bin2hello_bsvi.py -- do not edit" % bin_path,
    "function Bit #(16) fn_hello_len ();",
    "   return %d;" % len(data),
    "endfunction",
    "",
    "function Bit #(8) fn_hello_bytes (Bit #(16) i);",
    "   case (i)",
]
lines += ["      %d: return 8'h%02x;" % (i, b) for i, b in enumerate(data)]
lines += ["      default: return 8'h00;", "   endcase", "endfunction", ""]
out_path.write_text("\n".join(lines))
print("%s: %d bytes -> %s" % (bin_path, len(data), out_path))
