#!/bin/sh
# riscv-tests debug suite (gdbserver.py: gdb + OpenOCD end to end) on the ULX3S Flute SoC over the
# US1 cable's JTAG.  The board must run a JTAGG build (lx45d+; the promoted bit): this script does
# not program it.  The FT231X is not a UART while the JTAG server runs (put back on exit).
#   test/debug/run.sh [gdbserver.py args, e.g. a test name]
# Needs: build/ext/riscv-tests (riscv-software-src/riscv-tests), a venv with pexpect at
# build/ext/debug-venv, riscv64-unknown-elf-gcc, riscv64-elf-gdb, openocd.  Logs: test/debug/logs/.
set -e
R=$(cd "$(dirname "$0")/../.." && pwd)
D=$R/build/ext/riscv-tests/debug
python3 "$R/scripts/ft231x_jtag.py" --server 4567 --persist > "$R/build/debug-jtag-server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null' EXIT
sleep 1
cd "$D"                       # the suite compiles with -I ../env (relative)
RISCV_TESTS_DEBUG_GCC=${RISCV_TESTS_DEBUG_GCC:-riscv64-unknown-elf-gcc} \
RISCV_TESTS_DEBUG_GDB=${RISCV_TESTS_DEBUG_GDB:-riscv64-elf-gdb} \
"$R/build/ext/debug-venv/bin/python3" "$D/gdbserver.py" --server_cmd "$R/test/debug/openocd012.sh" --logs "$R/test/debug/logs" \
  "$R/test/debug/FluteUlx3s.py" "$@"
