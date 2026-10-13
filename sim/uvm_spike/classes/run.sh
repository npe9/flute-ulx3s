#!/bin/bash
# run.sh — compile + run a --binary, --no-timing SV probe.
set -uo pipefail
cd "$(dirname "$0")"
rm -rf obj_dir

SRC="${1:-tb_classes.sv}"
TOP="${2:-tb_top}"

verilator --binary --no-timing -j 4 -Wno-lint -Wno-style \
    --top-module "$TOP" -Mdir obj_dir -o tb "$SRC" > build.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then
    echo "RESULT: COMPILE FAIL ($rc)"; grep -m5 "%Error" build.log; exit $rc
fi
./obj_dir/tb 2>&1 | tee run.log
rc=$?
echo "RESULT: RUN exit=$rc"
exit $rc
