#!/bin/bash
# sim/mc_ut/run.sh -- Mem_Controller data-integrity unit test (Bluesim).  PASS = "[mc_ut] PASS".
set -e
cd "$(dirname "$0")"
BSC=${BSC:-$HOME/src/bsc/inst/bin/bsc}
F=../../Flute
P="+:$F/src_Testbench/SoC:$F/src_Testbench/Fabrics/AXI4:$F/src_Core/BSV_Additional_Libs:$F/src_Core/ISA:$F/src_Core/Core:$F/src_Core/CPU:$F/src_Core/Cache_Config:$F/src_Core/PLIC:$F/src_Core/Near_Mem_IO:$F/src_Core/Debug_Module:$F/src_Core/RegFiles:$F/src_Core/Near_Mem_VM_WT_L1"
mkdir -p build
"$BSC" -u -sim -g mkMC_UT -aggressive-conditions -no-warn-action-shadowing \
   -D RV32 -D FABRIC64 -p "$P" -bdir build -simdir build MC_UT.bsv > build/bsc.log 2>&1 || { cat build/bsc.log; exit 1; }
"$BSC" -sim -e mkMC_UT -bdir build -simdir build -o build/mc_ut > build/link.log 2>&1 || { cat build/link.log; exit 1; }
PATH=$(dirname "$BSC"):$PATH BLUESPECDIR=${BLUESPECDIR:-$(dirname "$BSC")/../lib} ./build/mc_ut | grep -v "Mem_Controller.set_addr_map"
