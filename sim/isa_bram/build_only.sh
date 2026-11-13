#!/bin/bash
# build_only.sh — verilate+build the J1 harness exactly like run.sh, but
# do not run the sim.  Used to iterate on model changes quickly.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
BSC_LIB="$(../../scripts/bsc_lib.sh)" || exit 1
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
        "$ROOT/src/Top.v" "$ROOT/src/Video_DVI.v" "$ROOT/src/Board_IO.v" "$ROOT/src/Audio.v" "$ROOT/src/Spdif_Tx.v" "$ROOT/src/Sd_Host.v" "$ROOT/sim/common/i2c_slave_model.v" "$ROOT/sim/common/spi_echo_model.v"
        ./BRAM2.v
        ./ecp5_cells.v
        ./sdram_model.v
        ./tb_board.v
        ./board_pins_if.sv
        ./uart_agent.sv
        ./scoreboard.sv
        ./coverage.sv
        ./sv_tb_top.sv)

# Same knobs as ../linux_bram/build_only.sh: TB_NOCOV=1 drops coverage, UART_CPB /
# SDRAM_TCK_PS for a netlist built at another clock (SYS_PLL=50: UART_CPB=50,
# SDRAM_TCK_PS=20000; the ISA mode waits for the boot-ROM banner).
XFLAGS=()
if [[ "${TB_NOCOV:-0}" != "1" ]]; then XFLAGS+=(--coverage --coverage-user); fi
if [[ -n "${UART_CPB:-}" ]]; then XFLAGS+=(-DUART_CPB=$UART_CPB); fi
if [[ -n "${SDRAM_TCK_PS:-}" ]]; then XFLAGS+=(-DSDRAM_TCK_PS=$SDRAM_TCK_PS); fi

verilator --cc --exe --build -j "${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}" \
    --top-module sv_tb_top \
    -DJTAG_TAP \
    --no-timing \
    --x-initial unique \
    --timescale-override "1ns/1ps" \
    --assert \
    "${XFLAGS[@]}" \
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
