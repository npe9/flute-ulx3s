#!/bin/bash
# sim/apu_ut/run.sh: src/Apu.v against the reference model sw/apu/apu_ref.c (Verilator), sample
# for sample; prints APU_UT PASS or the failing scenes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"
verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH --top-module apu \
    -Mdir obj_dir "$ROOT/src/Apu.v" tb.cpp "$ROOT/sw/apu/apu_ref.c" \
    -CFLAGS "-O2 -I$ROOT/sw/apu" > build.log 2>&1 || { tail -30 build.log; exit 1; }
./obj_dir/Vapu
