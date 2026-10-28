#!/bin/bash
# Formal-only build of mkMem_Controller with the write-buffer limits shrunk
# (idle write-back after 2 idle cycles, age-out after 4 dirty cycles) so BMC depth ~12
# reaches both write-back triggers. Output: ../../../build/fmc/verilog. Then:
#   RTL=../../../build/fmc/verilog ./run.sh 12 [REACH]
set -e
cd "$(dirname "$0")/../../.."
BSC=$(scripts/bsc_bin.sh) || exit 1
F=$PWD/Flute
BP="+:$F/src_Core/ISA:$F/src_Core/Core:$F/src_Core/BSV_Additional_Libs:$F/src_Testbench/SoC:$F/src_Testbench/Fabrics/AXI4:$PWD/src"
O=build/fmc; mkdir -p $O/bsc $O/verilog $O/info
"$BSC" -u -verilog -g mkMem_Controller -keep-fires -aggressive-conditions -no-warn-action-shadowing \
  -no-show-timestamps -suppress-warnings G0020 +RTS -K128M -RTS \
  -D RV32 -D FABRIC64 -D ISA_I -D ISA_M -D ISA_A -D ISA_C -D ISA_F -D ISA_D -D Near_Mem_Caches -D MC_FORMAL_PROBES \
  -D MC_IDLE_WB_CYCLES=${IDLE:-2} -D MC_MAX_DIRTY_CYCLES=${AGE:-4} \
  -p "$BP" -bdir $O/bsc -vdir $O/verilog -info-dir $O/info $F/src_Testbench/SoC/Mem_Controller.bsv
