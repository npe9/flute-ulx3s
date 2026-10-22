#!/bin/bash
# sim/sdram_ut/run.sh -- stand-alone Sdram_Controller unit test (Verilator --timing).
# Regenerates ${OBJ:-build}/v/mkSdram_UT.v from ../../src/Sdram_Controller.bsv, then builds and runs tb.sv.
# PASS = "[sdram_ut] PASS" and "[sdram_chk] summary: 0 error(s)".
set -e
cd "$(dirname "$0")"
BSC=${BSC:-$HOME/src/bsc/inst/bin/bsc}
BSVLIB=${BSVLIB:-$HOME/src/bsc/inst/lib/Verilog}
F=../../Flute
SRC=${SRC:-../../src}
P="+:$SRC:$F/src_Testbench/SoC:$F/src_Testbench/Fabrics/AXI4:$F/src_Core/BSV_Additional_Libs:$F/src_Core/ISA:$F/src_Core/Core:$F/src_Core/CPU:$F/src_Core/Cache_Config:$F/src_Core/PLIC:$F/src_Core/Near_Mem_IO:$F/src_Core/Debug_Module:$F/src_Core/RegFiles:$F/src_Core/Near_Mem_VM_WT_L1"
mkdir -p ${OBJ:-build}/bsc ${OBJ:-build}/v
"$BSC" -u -verilog -g mkSdram_UT -aggressive-conditions -no-warn-action-shadowing \
   -D RV32 -D FABRIC64 -D ISA_PRIV_S -D SV32 -p "$P" -bdir ${OBJ:-build}/bsc -vdir ${OBJ:-build}/v Sdram_UT.bsv > build/bsc.log 2>&1 \
   || { cat build/bsc.log; exit 1; }
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-STMTDLY -Wno-TIMESCALEMOD --top-module tb \
   -Mdir ${OBJ:-build/obj} -y "$BSVLIB" +libext+.v \
   tb.sv dpi_stub.cpp ${OBJ:-build}/v/mkSdram_UT.v ../linux_bram/sdram_model.v ../linux_bram/sdram_timing_check.v > build/verilator.log 2>&1 \
   || { tail -30 build/verilator.log; exit 1; }
${OBJ:-build/obj}/Vtb "$@" | tee build/run.log | grep -E "sdram_ut|sdram_chk|FAIL"
grep -q "\[sdram_ut\] PASS" build/run.log && grep -q "summary: 0 error" build/run.log
