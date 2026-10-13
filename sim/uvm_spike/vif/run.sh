#!/bin/bash
# run.sh — vif probe: classes + virtual interface + DPI bridge.
set -uo pipefail
cd "$(dirname "$0")"
rm -rf obj_dir

verilator --cc --exe --build -j 4 --no-timing -Wno-lint -Wno-style \
    --top-module tb_top -Mdir obj_dir -o tb probe_main.cpp tb_vif.sv > build.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then
    echo "RESULT: COMPILE FAIL ($rc)"; grep -m8 "%Error" build.log; exit $rc
fi
./obj_dir/tb 2>&1 | tee run.log
rc=$?
echo "RESULT: RUN exit=$rc"
exit $rc
