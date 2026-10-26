#!/bin/bash
# usage: testrig/netlist_hash.sh <tag>
# Builds the production ULX3S netlist exactly as build/timing-exp/v7-bsc.log does
# (SOC_BUILD_DATE pinned to 20261021) into build/testrig-<tag>/ and hashes the Verilog.
set -u
cd "$(dirname "$0")/.."
T=build/testrig-$1
R=$PWD
mkdir -p $T/bsc $T/verilog $T/info
P="+:$R/src:$R/Flute/src_Core/CPU:$R/Flute/src_Core/ISA:$R/Flute/src_Core/RegFiles:$R/Flute/src_Core/Core:$R/Flute/src_Core/Cache_Config:$R/Flute/src_Core/Near_Mem_VM_WT_L1:$R/Flute/src_Core/PLIC:$R/Flute/src_Core/Near_Mem_IO:$R/Flute/src_Core/Debug_Module:$R/Flute/src_Core/BSV_Additional_Libs:$R/Flute/src_Testbench/SoC:$R/Flute/src_Testbench/Fabrics/AXI4"
nice $HOME/src/bsc/inst/bin/bsc -u -verilog -g mkULX3S_Top -keep-fires -aggressive-conditions -no-warn-action-shadowing -show-schedule -no-show-timestamps -suppress-warnings G0020 +RTS -K128M -RTS -D RV32 -D ISA_I -D ISA_M -D ISA_A -D ISA_C -D ISA_B -D ISA_ZKN -D ISA_ZKR -D ISA_XBOX -D SOC_BUILD_DATE=20261021 -D ISA_PRIV_M -D ISA_PRIV_U -D ISA_PRIV_S -D SV32 -D SV32_ITLB -D SHIFT_BARREL -D MULT_SYNTH -D Near_Mem_Caches -D FABRIC64 -D INCLUDE_ACCEL0 -D INCLUDE_GDB_CONTROL -D JTAG_TAP \
  -p "$P" -bdir $T/bsc -vdir $T/verilog -info-dir $T/info src/ULX3S_Top.bsv > $T/elaboration.log 2>&1
echo "bsc rc=$?"
(cd $T/verilog && ls *.v | sort | xargs cat | shasum -a 256) | tee $T/netlist.sha256
ls $T/verilog | wc -l
