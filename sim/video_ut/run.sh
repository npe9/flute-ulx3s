#!/bin/bash
# sim/video_ut/run.sh: build and run the video_fb unit bench (Verilator).  Frames land in
# sim/video_ut/build/*.ppm.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"
verilator --cc --exe --build -O2 -Wno-fatal -Wno-WIDTH --top-module video_fb \
    -Mdir obj_dir "$ROOT/src/Video_DVI.v" tb.cpp -CFLAGS "-O2 -std=c++17" > build.log 2>&1 || { tail -30 build.log; exit 1; }
./obj_dir/Vvideo_fb
