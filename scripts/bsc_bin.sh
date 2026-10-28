#!/bin/sh
# Print the bsc binary: $BSC if it is a file, else <install root>/bin/bsc for the install
# scripts/bsc_lib.sh resolves ($BSC_LIB / $BSC / ~/src/bsc/inst / PATH).
if [ -n "$BSC" ] && [ -f "$BSC" ]; then echo "$BSC"; exit 0; fi
lib=$("$(dirname "$0")/bsc_lib.sh") || exit 1
echo "$(dirname "$(dirname "$lib")")/bin/bsc"
