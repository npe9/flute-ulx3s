#!/bin/bash
# build_f1check.sh — build the ORIGINAL F1 bench (top sim_board, old C++
# main, no J1 SV components, no --assert/--coverage) into obj_dir_f1check,
# to A/B the seed-2 hang against the J1 harness.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
BSC_LIB="${BSC:-$HOME/src/bsc/inst}/lib/Verilog"
# see run.sh: VERILOG_ALL overrides the netlist under test (J1 baseline
# validation); default keeps the live tree path for Step 3's gates.
VERILOG_ALL="${VERILOG_ALL:-$ROOT/build/verilog_all.v}"

FILES=()
for f in "$BSC_LIB"/*.v; do
    b="$(basename "$f")"
    case "$b" in
        Load*|InoutConnect*|Probe*|main.v) continue ;;
        BRAM2.v) continue ;;
    esac
    FILES+=("$f")
done
FILES+=("$ROOT/src/ASSIGN1.v"
        "$VERILOG_ALL"
        "$ROOT/src/Top.v"
        ./BRAM2.v
        ./ecp5_cells.v
        ./sdram_model.v
        ./tb_board.v)

verilator --cc --exe --build -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
    --top-module sim_board \
    -DJTAG_TAP \
    --no-timing \
    --x-initial unique \
    --timescale-override "1ns/1ps" \
    -Wno-lint -Wno-style \
    -Wno-NOTREDOP \
    -Wno-STMTDLY \
    -I"$ROOT/src" \
    -Mdir obj_dir_f1check \
    -o Vsim_board \
    tb_top_f1check.cpp \
    "${FILES[@]}"
rc=$?
echo "F1CHECK BUILD rc=$rc"
exit $rc
