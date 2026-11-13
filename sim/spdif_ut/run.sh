#!/bin/bash
# sim/spdif_ut: S/PDIF through src/Audio.v, decoded like a receiver (decode.py).
set -e
cd "$(dirname "$0")"; R=../..
iverilog -g2012 -o tb.vvp tb.v $R/src/Audio.v $R/src/Spdif_Tx.v
vvp -n tb.vvp | grep -v '^VCD'
python3 decode.py 2
