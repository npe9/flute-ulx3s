#!/bin/bash
# run_testrig.sh: TestRIG lockstep run, Sail (implementation A, reference) vs
# Flute RVFI-DII Bluesim (implementation B).  See testrig/README.md.
#
#   testrig/run_testrig.sh [-o LOGDIR] [QCVEngine args...]
#   e.g. testrig/run_testrig.sh -r rv32imac -I arith -n 200
#
# Env: SAIL (riscv_rvfi_RV32), QCV (QCVEngine), DUT (Flute_RVFI_DII),
#      BSC_BIN (dir with bluetcl), SAIL_FLAGS, PORT_BASE.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SAIL="${SAIL:-$HOME/src/sail-riscv-rvfi/c_emulator/riscv_rvfi_RV32}"
QCV="${QCV:-$HOME/src/TestRIG/vengines/QuickCheckVEngine/bin/QCVEngine}"
# RAM8M=1: Sail's default RVFI-DII platform (8 MiB RAM at 0x8000_0000, rest
# vacant) with the matching DUT build (make -C testrig ram8m).  Default: the
# RAM is [0, 0xffffffc0) on both sides: all but the top 64-byte line (Sail's
# RAM size is XLEN wide, so it cannot cover 2^32; see SoC_Map.bsv).
if [ "${RAM8M:-0}" = 1 ]; then
    DUT="${DUT:-$ROOT/build/testrig-dii-ram8m/Flute_RVFI_DII}"
else
    DUT="${DUT:-$ROOT/build/testrig-dii/Flute_RVFI_DII}"
    export SAIL_RVFI_RAM_BASE=0 SAIL_RVFI_RAM_SIZE=0xffffffc0
fi
BSC_BIN="${BSC_BIN:-$HOME/src/bsc/inst/bin}"
# Sail platform config matching the Flute core (see README "Configuration"):
#   -I  misa not writable        -F  no F/D        -i  mtval = instruction bits on illegal instr
#   16 PMP CSRs visible (Flute implements entries 0-7, 8-15 read-only zero;
#   Sail accepts only 0/16/64), grain G=10 (4 KiB).
SAIL_FLAGS="${SAIL_FLAGS:--I -F -i --pmp-count 16 --pmp-grain 10}"
PORT_BASE="${PORT_BASE:-$((20000 + ($$ % 20000) / 2 * 2))}"
# skip port pairs already in use (several runs may share the machine)
for i in $(seq 1 200); do
    lsof -nP -iTCP:$PORT_BASE -sTCP:LISTEN >/dev/null 2>&1 || lsof -nP -iTCP:$((PORT_BASE + 1)) -sTCP:LISTEN >/dev/null 2>&1 || break
    PORT_BASE=$((PORT_BASE + 2 + RANDOM % 64 * 2))
done
PA=$PORT_BASE
PB=$((PORT_BASE + 1))

LOGDIR=""
if [ "${1:-}" = "-o" ]; then LOGDIR="$2"; shift 2; fi
LOGDIR="${LOGDIR:-$ROOT/build/testrig-runs/run-$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$LOGDIR"
LOGDIR="$(cd "$LOGDIR" && pwd)"

export PATH="$BSC_BIN:$PATH"
"$SAIL" -V $SAIL_FLAGS -r $PA > "$LOGDIR/sail.log" 2>&1 &
SAIL_PID=$!
RVFI_DII_PORT=$PB "$DUT" ${DUT_ARGS:-} > "$LOGDIR/dut.log" 2>&1 &
DUT_PID=$!
cleanup () { kill $SAIL_PID $DUT_PID 2>/dev/null; pkill -P $DUT_PID 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

# wait for both listeners (lsof does not connect: each side accepts only once)
for i in $(seq 1 120); do
    lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 1
done

# make file/dir arguments (-t FILE, -d DIR) absolute before changing directory
ARGS=()
for a in "$@"; do
    if [ -e "$a" ]; then a="$(cd "$(dirname "$a")" && pwd)/$(basename "$a")"; fi
    ARGS+=("$a")
done
set -- "${ARGS[@]}"
cd "$LOGDIR"
# --no-save unless a save dir (-s DIR) is given: with -s, QCVEngine writes
# each failure (re-run with the mcause/mtval suffix) to DIR without prompting.
NOSAVE=--no-save
for a in "$@"; do case "$a" in -s|--save-dir=*) NOSAVE= ;; esac; done
echo "QCVEngine -a $PA -b $PB $NOSAVE $*" > "$LOGDIR/cmd.txt"
"$QCV" -a $PA -b $PB $NOSAVE "$@" < /dev/null 2>&1 | tee "$LOGDIR/qcv.log"
rc=${PIPESTATUS[0]}
echo "logs: $LOGDIR"
exit $rc
