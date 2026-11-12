#!/bin/bash
# sim/jtagg/run.sh [build dir, default build/lx45]: the JTAGG DTM unit bench (tb_jtagg.sv).
set -e
R="$(cd "$(dirname "$0")/../.." && pwd)"; B="${1:-$R/build/lx45}"
LIB="${BSC_VLIB:-/Users/npe/src/bsc/inst/lib/Verilog}"   # the Makefile's bsc
W="$B/jtagg_sim"; mkdir -p "$W"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_jtagg -Mdir "$W" \
    -DBSV_NO_INITIAL_BLOCKS=0 ${JTAGG_SIM_DEFS:-} "$R/sim/jtagg/tb_jtagg.sv" "$R/src/ecp5_jtag_model.v" \
    "$B/verilog/mkJtaggDtm.v" "$LIB/FIFO2.v" > "$W/build.log" 2>&1 || { tail -30 "$W/build.log"; exit 1; }
"$W/Vtb_jtagg"
