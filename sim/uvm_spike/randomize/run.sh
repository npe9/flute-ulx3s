#!/bin/bash
# run.sh — probe: constrained randomization subset under --no-timing.
# Main test + two secondary probes for grammar-based randomization
# (randcase / randsequence), which are compile-attempted separately.
set -uo pipefail
cd "$(dirname "$0")"
rm -rf obj_dir

echo "=== main: tb_randomize.sv ==="
verilator --binary --no-timing -j 4 -Wno-lint -Wno-style \
    --top-module tb_top -Mdir obj_dir -o tb tb_randomize.sv > build.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then
    echo "RESULT: COMPILE FAIL ($rc)"; grep -m8 "%Error" build.log; exit $rc
fi
./obj_dir/tb 2>&1 | tee run.log
rc=$?
echo "RESULT(main): RUN exit=$rc"

echo "=== secondary: randcase ==="
verilator --binary --no-timing -j 4 -Wno-lint -Wno-style \
    --top-module tb_top -Mdir obj_rc -o tb tb_randcase.sv > build_rc.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then grep -m3 "%Error" build_rc.log; echo "RESULT(randcase): COMPILE FAIL"; else ./obj_rc/tb | grep -E "RANDCASE|RESULT"; fi

echo "=== secondary: randsequence ==="
verilator --binary --no-timing -j 4 -Wno-lint -Wno-style \
    --top-module tb_top -Mdir obj_rs -o tb tb_randsequence.sv > build_rs.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then grep -m3 "%Error" build_rs.log; echo "RESULT(randsequence): COMPILE FAIL"; else ./obj_rs/tb | grep -E "RANDSEQ|RESULT"; fi
exit 0
