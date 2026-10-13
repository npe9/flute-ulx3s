#!/bin/bash
# run.sh — compile + run the coverage probe; then verify coverage.dat
# bin hit counts the way the J3 gate would (empty hazard bins = pass,
# exercised loader bins = pass).
set -uo pipefail
cd "$(dirname "$0")"
rm -rf obj_dir coverage.dat

verilator --binary --no-timing -j 4 -Wno-lint -Wno-style \
    --coverage --coverage-user \
    --top-module tb_top -Mdir obj_dir -o tb tb_coverage.sv > build.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then
    echo "RESULT: COMPILE FAIL ($rc)"; grep -m8 "%Error" build.log; exit $rc
fi
./obj_dir/tb 2>&1 | tee run.log
rc=$?
echo "run rc=$rc"

if [[ ! -f coverage.dat ]]; then
    echo "RESULT: FAIL — no coverage.dat written"
    exit 1
fi

bin_hits() { # $1 = grep pattern for the bin hierarchy line
    grep "$1" coverage.dat | awk '{print $NF}'
}

echo "--- covergroup bins in coverage.dat ---"
grep "t_covergroup" coverage.dat | grep "bin" | sed "s/^C '//; s/' [0-9]*$//" | head -20

# J3 gate rule: hazard violation bins must be 0
lr=$(bin_hits "lost_read.violated")
cp=$(bin_hits "cross_port_cache.violated")
# loader bins must be exercised
first=$(bin_hits "chunk_idx.first")
mid=$(bin_hits "chunk_idx.middle")
last=$(bin_hits "chunk_idx.last")
none=$(bin_hits "naks.none")
one=$(bin_hits "naks.one")
many=$(bin_hits "naks.many")
xc=$(grep "_x_" coverage.dat | awk '{s+=$NF} END{print s}')   # sum of auto cross bins

echo "checks: hazard lost_read.violated=$lr cross_port.violated=$cp | loader first=$first mid=$mid last=$last nak0=$none nak1=$one nak2=$many cross=$xc"

if [[ "${lr:-1}" == "0" && "${cp:-1}" == "0" &&
     "${first:-0}" != "0" && "${mid:-0}" != "0" && "${last:-0}" != "0" &&
     "${none:-0}" != "0" && "${one:-0}" != "0" && "${many:-0}" != "0" ]]; then
    echo "COVERAGE: PASS (functional covergroup bins + empty-violation-bin gate)"
    exit 0
else
    echo "COVERAGE: FAIL"
    exit 1
fi
