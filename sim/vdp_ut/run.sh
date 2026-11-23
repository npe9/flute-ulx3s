#!/bin/bash
# sim/vdp_ut/run.sh: src/Vdp.v against the reference model sw/vdp/vdp_ref.c (Verilator), frame by
# frame; prints VDP_UT PASS or the failing scenes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"
verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH --top-module vdp_tb \
    -Mdir obj_dir "$ROOT/src/Vdp.v" vdp_tb.v tb.cpp "$ROOT/sw/vdp/vdp_ref.c" \
    -CFLAGS "-O2 -I$ROOT/sw/vdp" > build.log 2>&1 || { tail -30 build.log; exit 1; }
./obj_dir/Vvdp_tb
