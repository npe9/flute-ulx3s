#!/bin/bash
# run.sh — J0 feasibility probe against the NEW side-by-side Verilator build.
# Verilator 5.052 has no --uvm switch (that recipe was wrong); upstream's
# supported path is compiling the vendored UVM sources directly, see
# test_regress/t/t_uvm_hello_all_v2020_3_2_nodpi.py in the source tree.
set -uo pipefail
cd "$(dirname "$0")"

VERILATOR="${VERILATOR:-$HOME/src/verilator-uvm/bin/verilator}"
UVM_DIR="${UVM_DIR:-$HOME/src/verilator-uvm/share/verilator/uvm}"
VARIANT="${VARIANT:-uvm_pkg_all_v2020_3_2_nodpi.svh}"
TB="${TB:-tb_uvm.sv}"

echo "verilator : $("$VERILATOR" --version 2>&1)"
echo "uvm dir   : $UVM_DIR (variant $VARIANT)"
ls "$UVM_DIR/$VARIANT" >/dev/null || { echo "MISSING $UVM_DIR/$VARIANT"; exit 2; }

rm -rf obj_dir
echo "=== compile: vendored UVM library + tb_uvm.sv ==="
"$VERILATOR" --binary --timing -j "$(sysctl -n hw.ncpu)" -Wno-lint -Wno-style \
    --top-module tb_top -Mdir obj_dir -o tb \
    +incdir+"$UVM_DIR" \
    "$UVM_DIR/$VARIANT" \
    "$TB" > compile.log 2>&1
rc=$?
tail -5 compile.log
echo "compile rc=$rc"
[[ $rc -ne 0 ]] && exit $rc

echo "=== run ==="
./obj_dir/tb +UVM_NO_RELNOTES 2>&1 | tee run.log
echo "RUN rc=${PIPESTATUS[0]}"
