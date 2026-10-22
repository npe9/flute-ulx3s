#!/bin/bash
# build_only.sh — verilate+build the J1 harness exactly like run.sh, but
# do not run the sim.  Used to iterate on model changes quickly.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
BSC_LIB="${BSC:-$HOME/src/bsc/inst}/lib/Verilog"
# see run.sh: VERILOG_ALL overrides the netlist under test (J1 baseline
# validation); default keeps the live tree path for Step 3's gates.
VERILOG_ALL="${VERILOG_ALL:-$ROOT/build/verilog_all.v}"
BUILD_DIR="${BUILD_DIR:-obj_dir}"

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
        ./tb_board.v
        ./board_pins_if.sv
        ./uart_agent.sv
        ./scoreboard.sv
        ./coverage.sv
        ./sv_tb_top.sv)

verilator --cc --exe --build -j "${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}" \
    --top-module sv_tb_top \
    -DJTAG_TAP \
    --no-timing \
    --x-initial unique \
    --timescale-override "1ns/1ps" \
    --assert \
    --coverage --coverage-user \
    -Wno-lint -Wno-style \
    -Wno-NOTREDOP \
    -Wno-STMTDLY \
    -I"$ROOT/src" \
    -Mdir "$BUILD_DIR" \
    -o Vsv_tb_top \
    tb_top.cpp \
    "${FILES[@]}"
rc=$?
echo "BUILD rc=$rc"
exit $rc
