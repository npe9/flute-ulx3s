#!/bin/bash
# ================================================================
# run.sh — F1 strict-BRAM Verilator boot sim, end to end (J1 wiring).
#
#   ./run.sh                # STRICT_BRAM=error (default), boot scenario
#   ./run.sh --strict=warn  # report-only strict mode
#   ./run.sh --strict=corrupt
#   ./run.sh <path.bin>     # load a different image (default sw/hello.bin)
#   ./run.sh --lint-only    # just run verilator --lint-only
#   ./run.sh --scenario=boot   # only scenario implemented (J1 phase 1);
#   ./run.sh --scenario=other  # anything else: clean error, see J2
#
# J1 changes on top of F1: the verilation top is now sv_tb_top (wraps
# sim_board + board_pins_if + SV agents/scoreboard/coverage, see
# sv_tb_top.sv); --assert arms the concurrent assertions and the
# scoreboard's immediate assertions (a failed assertion exits nonzero =
# the gate); --coverage --coverage-user collects line/toggle coverage
# plus the functional covergroups, written to obj_dir/coverage.dat via
# +verilator+coverage+file+ (NEVER stdout — run_sweep.sh diffs stdout
# across seeds).  The C++ bench keeps the scenario FSM and drives the
# agents through DPI exports.
#
# File list replicates the Makefile's BSC_VERILOG_FILES filter
# (all of $BSC/inst/lib/Verilog/*.v minus Load*/InoutConnect*/Probe*/
# main.v) with ONE substitution: the stock lib BRAM2.v is replaced by
# sim/strict_bram/BRAM2.v (strict DP16KD model).  Then, in the same
# relative order as the Yosys recipe:
#   src/ASSIGN1.v  build/verilog_all.v  src/Top.v
# followed by the local ecp5 cells, the SDRAM model, the sim wrapper,
# and (appended for J1, order: interface -> packages -> top) the SV
# verification components.
# ================================================================

set -uo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
BSC_LIB="${BSC:-$HOME/src/bsc/inst}/lib/Verilog"
# Netlist under test: default the LIVE tree path so Step 3's later gates
# work unchanged; J1 validation points VERILOG_ALL at the frozen baseline
# snapshot (build/timing-exp/verilog_all.v.pre-step3).
VERILOG_ALL="${VERILOG_ALL:-$ROOT/build/verilog_all.v}"
# Build/run directory: default obj_dir; overridable so a foreign agent can
# gate a DIFFERENT netlist in its own dir without clobbering a validated
# build (verilator output is not shareable across differing inputs).
BUILD_DIR="${BUILD_DIR:-obj_dir}"
SIM_BIN="$BUILD_DIR/Vsv_tb_top"

STRICT="${STRICT_BRAM:-error}"
LINT_ONLY=0
IMAGE=""
SCENARIO="boot"
EXTRA_PLUSARGS=()

for a in "$@"; do
    case "$a" in
        --strict=*)   STRICT="${a#--strict=}" ;;
        --lint-only)  LINT_ONLY=1 ;;
        --scenario=*) SCENARIO="${a#--scenario=}" ;;
        +*)           EXTRA_PLUSARGS+=("$a") ;;   # e.g. +verilator+seed+N
        *)            IMAGE="$a" ;;
    esac
done
case "$STRICT" in
    warn|corrupt|error) ;;
    *) echo "run.sh: unknown --strict=$STRICT (want warn|corrupt|error)" >&2; exit 2 ;;
esac
case "$SCENARIO" in
    boot) ;;
    *) echo "run.sh: --scenario=$SCENARIO is not implemented (J1 phase 1 supports 'boot' only; sequences land in J2)" >&2; exit 2 ;;
esac
export STRICT_BRAM="$STRICT"

# ---- file list ------------------------------------------------------
FILES=()
for f in "$BSC_LIB"/*.v; do
    b="$(basename "$f")"
    case "$b" in
        Load*|InoutConnect*|Probe*|main.v) continue ;;
        BRAM2.v) continue ;;            # replaced by the strict model below
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

echo "run.sh: STRICT_BRAM=$STRICT scenario=$SCENARIO  ($(( ${#FILES[@]} )) files)"
echo "run.sh: VERILOG_ALL=$VERILOG_ALL"

COMMON_FLAGS=(
    --top-module sv_tb_top
    -DJTAG_TAP
    --no-timing
    --x-initial unique
    --timescale-override "1ns/1ps"
    --assert
    --coverage --coverage-user
    -Wno-lint -Wno-style
    -Wno-NOTREDOP
    -Wno-STMTDLY
    -I"$ROOT/src"
)

if [[ "$LINT_ONLY" == "1" ]]; then
    verilator --lint-only "${COMMON_FLAGS[@]}" "${FILES[@]}"
    rc=$?
    if [[ $rc == 0 ]]; then echo "run.sh: LINT OK"; else echo "run.sh: LINT FAILED ($rc)"; fi
    exit $rc
fi

# ---- build ----------------------------------------------------------
verilator --cc --exe --build -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
    "${COMMON_FLAGS[@]}" \
    -Mdir "$BUILD_DIR" \
    -o Vsv_tb_top \
    tb_top.cpp \
    "${FILES[@]}"
rc=$?
if [[ $rc != 0 ]]; then echo "run.sh: VERILATE/BUILD FAILED ($rc)"; exit $rc; fi

# ---- run ------------------------------------------------------------
RUN_ARGS=()
[[ -n "$IMAGE" ]] && RUN_ARGS+=("$IMAGE")
# coverage database under the build dir, never stdout
RUN_ARGS+=("+verilator+coverage+file+$BUILD_DIR/coverage.dat")
for p in "${EXTRA_PLUSARGS[@]+"${EXTRA_PLUSARGS[@]}"}"; do
    RUN_ARGS+=("$p")
done
set +e
if ((${#RUN_ARGS[@]})); then
    "$SIM_BIN" "${RUN_ARGS[@]}"
else
    "$SIM_BIN"
fi
rc=$?
set -e

# ---- J1 coverage bin gate -------------------------------------------
# The hazard covergroup bins mirror BRAM2's per-RAM counters.  Every
# `hit` bin must stay EMPTY for a pass, except btb_cross_ba which
# carries the known benign branch-predictor census.  This is what makes
# a --strict=warn run with census violations FAIL (in --strict=error
# the model itself $fatals first).
COV_DB="$BUILD_DIR/coverage.dat"
if [[ -f "$COV_DB" ]]; then
    bin_hits() { # $1 = trailing bin hierarchy pattern
        local v
        v=$(grep -- "$1" "$COV_DB" | awk '{print $NF}' || true)
        echo "${v:-MISSING}"
    }
    echo "[run.sh] coverage hazard bins:"
    gate_fail=0
    for pat in icw_lost_a.hit icw_lost_b.hit icw_cross_ab.hit icw_cross_ba.hit \
               ict_lost_a.hit ict_lost_b.hit ict_cross_ab.hit ict_cross_ba.hit \
               dcw_lost_a.hit dcw_lost_b.hit dcw_cross_ab.hit dcw_cross_ba.hit \
               dct_lost_a.hit dct_lost_b.hit dct_cross_ab.hit dct_cross_ba.hit \
               btb_lost_a.hit btb_lost_b.hit btb_cross_ab.hit; do
        v=$(bin_hits "$pat")
        printf '[run.sh]   %-18s %s\n' "$pat" "${v:-MISSING}"
        if [[ "${v:--1}" != "0" ]]; then gate_fail=1; fi
    done
    v=$(bin_hits "btb_cross_ba.hit")
    printf '[run.sh]   %-18s %s (benign BTB census, must be > 0)\n' "btb_cross_ba.hit" "${v:-MISSING}"
    if [[ "${v:--1}" == "0" || "${v:--1}" == "-1" ]]; then
        if [[ "${J1_WAIVE_BTB_CENSUS:-0}" == "1" ]]; then
            echo "[run.sh] WARNING: btb_cross_ba census is ${v:-MISSING} but J1_WAIVE_BTB_CENSUS=1 (train-FIFO variants decouple bp_train from predict, eliminating the stock collision pattern; census-alive is cross-checked by the strict model's other bins and rc). Waiving."
        else
            gate_fail=1
        fi
    fi
    if [[ $gate_fail == 1 && $rc == 0 ]]; then
        echo "run.sh: COVERAGE HAZARD-BIN GATE FAILED"
        rc=1
    fi
else
    echo "[run.sh] WARNING: $COV_DB not produced"
fi

if [[ $rc == 0 ]]; then
    echo "run.sh: RESULT: PASS (STRICT_BRAM=$STRICT)"
else
    echo "run.sh: RESULT: FAIL (exit $rc, STRICT_BRAM=$STRICT)"
fi
exit $rc
