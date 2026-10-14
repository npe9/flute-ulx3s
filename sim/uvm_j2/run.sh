#!/bin/bash
# ================================================================
# run.sh — J2 full-UVM strict-BRAM sim driver (Track J).
#
#   ./run.sh                          # boot_hello_test, STRICT_BRAM=error
#   TEST=corrupt_xor_test ./run.sh
#   TEST=garbage_seq_test ./run.sh
#   TEST=chunk_delay_test ./run.sh
#   SMOKE=1 ./run.sh                  # banner-only plumbing check (~seconds)
#   CORRUPT_BYTE=300 ./run.sh         # negative gate: flip one image byte
#   IMAGE=/path.img.bin ./run.sh      # non-default payload
#   STRICT_BRAM=warn ./run.sh
#   LINT_ONLY=1 ./run.sh              # verilate --lint-only
#
# Env: VERILOG_ALL (netlist under test, default the live tree build),
#      BUILD_DIR (default obj_dir_$TEST), SEED (+verilator+seed+N).
#
# Reuses sim/strict_bram verbatim: the strict BRAM2 model, the SDRAM
# model, the sim board wrapper, the J1 uart agent / scoreboard /
# coverage (option-B components, zero edits).  Adds the vendored UVM
# library (2020-3.2 nodpi variant) and the J2 packages on top, built
# with the side-by-side UVM-capable binary.  File order: UVM pkg first,
# then the J1 list (BSC lib filter, ASSIGN1/netlist/Top, models, J1 SV
# components), then the J2 packages and top.
# ================================================================

set -uo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
SB="$PWD/../strict_bram"
BSC_LIB="${BSC:-$HOME/src/bsc/inst}/lib/Verilog"
VUVM="$HOME/src/verilator-uvm"
UVM_DIR="$VUVM/share/verilator/uvm"
UVM_PKG="$UVM_DIR/uvm_pkg_all_v2020_3_2_nodpi.svh"
VERILATOR_BIN="${VERILATOR:-$VUVM/bin/verilator}"

TEST="${TEST:-boot_hello_test}"
IMAGE="${IMAGE:-$ROOT/sw/hello.bin}"
STRICT="${STRICT_BRAM:-error}"
VERILOG_ALL="${VERILOG_ALL:-$ROOT/build/verilog_all.v}"
BUILD_DIR="${BUILD_DIR:-obj_dir_$TEST}"
UVM_VERBOSITY="${UVM_VERBOSITY:-UVM_LOW}"
SMOKE="${SMOKE:-0}"
CORRUPT_BYTE="${CORRUPT_BYTE:-}"
SEED="${SEED:-}"

case "$STRICT" in
    warn|corrupt|error) ;;
    *) echo "[run.sh] unknown STRICT_BRAM=$STRICT (want warn|corrupt|error)" >&2; exit 2 ;;
esac
export STRICT_BRAM="$STRICT"

[[ -f "$UVM_PKG" ]] || { echo "[run.sh] MISSING $UVM_PKG" >&2; exit 2; }

mkdir -p "$BUILD_DIR"

# ---- image -> hex (one byte per line) -------------------------------
img="$IMAGE"
if [[ -n "$CORRUPT_BYTE" ]]; then
    img="$BUILD_DIR/image_corrupt.bin"
    python3 - "$IMAGE" "$CORRUPT_BYTE" "$img" <<'PY'
import sys
src, off, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = bytearray(open(src, 'rb').read())
assert 0 <= off < len(d), f"offset {off} out of range (len {len(d)})"
d[off] ^= 0x01
open(dst, 'wb').write(bytes(d))
print(f"[run.sh] negative-gate image: byte {off} flipped -> {dst}")
PY
fi
[[ -f "$img" ]] || { echo "[run.sh] cannot open image $img" >&2; exit 2; }
LEN=$(wc -c < "$img" | tr -d ' ')
od -An -v -tx1 "$img" | tr ' ' '\n' | grep -v '^$' > "$BUILD_DIR/image.hex"
IMG_HEX="$BUILD_DIR/image.hex"

echo "[run.sh] J2 UVM sim: TEST=$TEST IMAGE=$img LEN=$LEN STRICT_BRAM=$STRICT SMOKE=$SMOKE"
echo "[run.sh] VERILOG_ALL=$VERILOG_ALL"
echo "[run.sh] BUILD_DIR=$BUILD_DIR"

# ---- file list ------------------------------------------------------
FILES=("$UVM_PKG")
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
        "$SB/BRAM2.v"
        "$SB/ecp5_cells.v"
        "$SB/sdram_model.v"
        "$SB/tb_board.v"
        "$SB/board_pins_if.sv"
        "$SB/uart_agent.sv"
        "$SB/scoreboard.sv"
        "$SB/coverage.sv"
        ./uvm_j2_base_pkg.sv
        ./uvm_j2_agent_pkg.sv
        ./uvm_j2_test_pkg.sv
        ./uvm_tb_top.sv)

FLAGS=(
    --top-module uvm_tb_top
    -DJTAG_TAP
    --timing
    --x-initial unique
    --timescale-override "1ns/1ps"
    -Wno-lint -Wno-style
    -Wno-NOTREDOP
    -Wno-STMTDLY
    -I"$ROOT/src"
    +incdir+"$UVM_DIR"
)
# instrumentation is optional (runtime experiments): ASSERT=0 / COV=0
[[ "${ASSERT:-1}" == "1" ]] && FLAGS+=(--assert)
[[ "${COV:-1}" == "1" ]] && FLAGS+=(--coverage --coverage-user)

if [[ "${LINT_ONLY:-0}" == "1" ]]; then
    "$VERILATOR_BIN" --lint-only "${FLAGS[@]}" "${FILES[@]}"
    rc=$?
    if [[ $rc == 0 ]]; then echo "[run.sh] LINT OK (${#FILES[@]} files)"; else echo "[run.sh] LINT FAILED ($rc)"; fi
    exit $rc
fi

# ---- build ----------------------------------------------------------
"$VERILATOR_BIN" --cc --exe --build -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
    "${FLAGS[@]}" \
    -Mdir "$BUILD_DIR" \
    -o Vuvm_tb_top \
    main.cpp \
    "${FILES[@]}"
rc=$?
if [[ $rc != 0 ]]; then echo "[run.sh] VERILATE/BUILD FAILED ($rc)"; exit $rc; fi

# ---- run ------------------------------------------------------------
RUN=("$BUILD_DIR/Vuvm_tb_top"
     "+STRICT_BRAM=$STRICT"
     "+UVM_TESTNAME=$TEST"
     "+UVM_VERBOSITY=$UVM_VERBOSITY"
     "+UVM_NO_RELNOTES"
     "+IMAGE_HEX=$IMG_HEX"
     "+IMAGE_LEN=$LEN"
     "+verilator+coverage+file+$BUILD_DIR/coverage.dat")
[[ "$SMOKE" == "1" ]] && RUN+=("+SMOKE=1")
[[ -n "$SEED" ]] && RUN+=("+verilator+seed+$SEED")

set +e
"${RUN[@]}" 2>&1 | tee "$BUILD_DIR/run.log"
rc=${PIPESTATUS[0]}
set -e

# ---- coverage hazard-bin gate (full runs only; the smoke run's ------
# census is intentionally incomplete) --------------------------------
if [[ "$SMOKE" != "1" && "${COV:-1}" == "1" && -f "$BUILD_DIR/coverage.dat" ]]; then
    bin_hits() { # $1 = trailing bin hierarchy pattern
        local v
        v=$(grep -- "$1" "$BUILD_DIR/coverage.dat" | awk '{print $NF}' || true)
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
    if [[ "${v:--1}" == "0" || "${v:--1}" == "-1" ]]; then gate_fail=1; fi
    if [[ $gate_fail == 1 && $rc == 0 ]]; then
        echo "[run.sh] COVERAGE HAZARD-BIN GATE FAILED"
        rc=1
    fi
elif [[ "$SMOKE" != "1" ]]; then
    echo "[run.sh] WARNING: $BUILD_DIR/coverage.dat not produced"
fi

if [[ $rc == 0 ]]; then
    echo "[run.sh] J2 UVM-SIM: PASS (TEST=$TEST STRICT_BRAM=$STRICT)"
else
    echo "[run.sh] J2 UVM-SIM: FAIL (exit $rc, TEST=$TEST STRICT_BRAM=$STRICT)"
fi
exit $rc
