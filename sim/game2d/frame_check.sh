#!/bin/bash
# sim/game2d/frame_check.sh: the game2d end-to-end check.  Runs Lantern Drift (sw/game2d) for
# FRAMES frames on the strict-BRAM sim of a game2d netlist (CPU, SDRAM, VDP, APU, video), captures
# the DVI scan-out, and compares it pixel for pixel with the frame the host build of the same code
# predicts through the VDP reference model (sw/vdp/vdp_ref.c).  The sound: the APU's trace
# (APU_TRACE) is replayed into the APU reference model (sw/apu/replay.c: every sample equal), and
# its writes must be exactly the host build's.  Also reports the CPU cycles per frame the title
# used.
#   sim/game2d/frame_check.sh [<game2d build dir>]     (default build/game2dv; FRAMES=40)
#   TITLE=proof sim/game2d/frame_check.sh ...           (Proof Obligation; default lantern)
set -e
R=$(cd "$(dirname "$0")/../.." && pwd); cd "$R"
B=${1:-build/game2dv}
FRAMES=${FRAMES:-40}
TITLE=${TITLE:-lantern}
L=$B/frame_check; [ "$TITLE" = lantern ] || L=${L}_$TITLE; mkdir -p $L
FRAMES=$FRAMES sw/game2d/build.sh > $L/build.log 2>&1
build/game2d/${TITLE}_host $FRAMES $L/expect.ppm $L/expect_apu.log
cc -O2 -o build/apu_replay sw/apu/replay.c sw/apu/apu_ref.c
rm -f $L/got.ppm sim/strict_bram/apu_trace.txt
INCLUDE_VDP=1 INCLUDE_APU=1 EXTRA_VFLAGS=-DAPU_TRACE TB_NOCOV=1 UART_CPB=50 BUILD_DIR=obj_dir_game2d VERILOG_ALL=$R/$B/verilog_all.v \
  TB_TX_TRACE=1 TB_HELLO_DEADLINE=$(( FRAMES * 420000 + 30000000 )) \
  sim/strict_bram/run.sh --strict=warn $R/sw/game2d/${TITLE}_f$FRAMES.bin +fb_ppm=$R/$L/got.ppm > $L/sim.log 2>&1 || true
# judged on the program's UART output (TB_TX_TRACE), like the other non-hello images: the bench's
# own verdict compares the output with hello.bin's and so always fails here
python3 - $L/sim.log <<'PY' || { echo "frame_check: the title did not finish ($L/sim.log)"; exit 1; }
import re, sys
d = open(sys.argv[1], 'rb').read().decode('latin-1')
tx = ''.join(chr(int(h, 16)) for h in re.findall(r'tx (0x[0-9a-fA-F]+)', d)).rsplit(']', 1)[-1]
m = re.search(r'game2d: .*', tx)
print(m.group(0).strip() if m else 'game2d: no statistics line')
sys.exit(0 if m and 'tick 00000000' in tx else 1)
PY
python3 - $L/expect.ppm $L/got.ppm <<'PY'
import sys
a, b = (open(f, 'rb').read() for f in sys.argv[1:3])
if len(a) != len(b): print(f"frame_check: FAIL (sizes {len(a)} {len(b)})"); sys.exit(1)
h = len(b"P6\n640 480\n255\n")
bad = [i for i in range(h, len(a), 3) if a[i:i+3] != b[i:i+3]]
if bad:
    p = (bad[0] - h) // 3
    print(f"frame_check: FAIL ({len(bad)} pixels differ; first at x={p % 640} y={p // 640})"); sys.exit(1)
print("frame_check: PASS (640x480 identical to the reference model)")
PY
# the sound: the APU's samples against the reference model, its writes against the host build's
T=$(ls -t sim/strict_bram/apu_trace.txt sim/strict_bram/obj_dir_game2d/apu_trace.txt apu_trace.txt 2>/dev/null | head -1)
[ -n "$T" ] || { echo "frame_check: FAIL (no APU trace)"; exit 1; }
mv "$T" $L/apu_trace.txt
build/apu_replay $L/apu_trace.txt $L/expect_apu.log
