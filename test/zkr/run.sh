#!/bin/bash
# Health-test unit test for the Zkr entropy source: bsc mkTb_Entropy -> Verilator with a driven noise bit.
set -e
cd "$(dirname "$0")"
R=$(cd ../.. && pwd); B=build; mkdir -p $B
BSC=${BSC:-$HOME/src/bsc/inst/bin/bsc}
$BSC -u -verilog -g mkTb_Entropy -bdir $B -vdir $B -p $R/Flute/src_Core/RegFiles:$R/Flute/src_Core/ISA:+ Tb_Entropy.bsv > $B/bsc.log 2>&1 || { cat $B/bsc.log; exit 1; }
verilator --cc --exe --build -Wno-fatal -Mdir $B/obj --top-module mkTb_Entropy $B/mkTb_Entropy.v RO_TRNG_tb.v tb_entropy.cpp -o tb > $B/vl.log 2>&1 || { tail -30 $B/vl.log; exit 1; }
$B/obj/tb
