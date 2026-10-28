#!/bin/sh
# Print bsc's Verilog primitive library directory (lib/Verilog).
# Order: $BSC_LIB; $BSC (an install root or the bsc binary); ~/src/bsc/inst if present;
# bsc on PATH (CI image).
if [ -n "$BSC_LIB" ]; then echo "$BSC_LIB"; exit 0; fi
if [ -n "$BSC" ] && [ -d "$BSC" ]; then root=$BSC
elif [ -n "$BSC" ]; then root=$(dirname "$(dirname "$(realpath "$BSC")")")
elif [ -x "$HOME/src/bsc/inst/bin/bsc" ]; then root=$HOME/src/bsc/inst
elif b=$(command -v bsc); then root=$(dirname "$(dirname "$(realpath "$b")")")
else echo "bsc_lib.sh: no bsc found (set BSC or put bsc on PATH)" >&2; exit 1; fi
echo "$root/lib/Verilog"
