#!/bin/bash
# scripts/pnr_seeds.sh <build dir> [make vars...]: synth the build's verilog_all.v, then place and
# route seeds 3, 5, 7 (two at a time) with the shipped flow (video floorplan pre-place); prints
# each seed's clocks and the cell use.  Packs seed 3 to <build dir>/ulx3s_top.bit.
#   scripts/pnr_seeds.sh build/game2d SOC=game2d SYS_PLL=50 FP=1 FPU_TRIM=1
set -e
L=$1; shift
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"
mkdir -p $L
if [ -z "$PNR_ONLY" ]; then     # PNR_ONLY=1: place and route the existing <build dir>/ulx3s_top.json
rm -f build/vid/boot_loader.memhex
make "$@" BUILD=$L $L/ulx3s_top.json > $L/synth.log 2>&1 || { echo "synth failed: $L/synth.log"; exit 1; }
git -C Flute checkout src_Testbench/SoC/fn_read_ROM_RV32.bsvi; rm -f build/vid/boot_loader.memhex
fi
NP=$(make -s -p -n 2>/dev/null | sed -n 's/^NEXTPNR ?= .*//p' >/dev/null; ls ../bluespec-ulx3s/toolchain/nextpnr-build/nextpnr-ecp5 2>/dev/null || command -v nextpnr-ecp5)
EP=$(ls ../bluespec-ulx3s/toolchain/prjtrellis-install/bin/ecppack 2>/dev/null || command -v ecppack)
run() { $NP --85k --package CABGA381 --json $L/ulx3s_top.json --lpf constraints/ulx3s_85f.lpf \
      --pre-place constraints/video_floorplan.py --textcfg $L/s$1.config --seed $1 --ignore-loops \
      --timing-allow-fail > $L/pnr-s$1.log 2>&1; }
clocks() { grep 'Max frequency for clock' $L/pnr-s$1.log | tail -3 | sed -E "s/.*glbnet.([a-z_]+)': ([0-9.]+) MHz.*/\1=\2/" | tr '\n' ' '; }
run 3 & run 5 & wait
run 7
$EP --compress $L/s3.config $L/ulx3s_top.bit
for s in 3 5 7; do echo "s$s: $(clocks $s)"; done
grep -E "TRELLIS_COMB:|TRELLIS_FF:|DP16KD:|MULT18X18D:" $L/pnr-s3.log | sed 's/Info://'
echo "packed s3: $(md5 -q $L/ulx3s_top.bit)"
