#!/bin/bash
# run.sh — SVA subset probe, three tiers.
set -uo pipefail
cd "$(dirname "$0")"
rm -rf obj_imm obj_conc obj_seq_nt obj_seq_t

echo "=== tier 1: immediate assertions, --binary --no-timing ==="
verilator --binary --no-timing -j 4 -Wno-lint -Wno-style --assert \
    --top-module tb_top -Mdir obj_imm -o tb a_imm.sv > build_imm.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then grep -m5 "%Error" build_imm.log; echo "RESULT(imm): COMPILE FAIL";
else ./obj_imm/tb 2>&1 | grep -E "\[tb\]|IMM" | head -4; echo "RESULT(imm): PASS"; fi

echo "=== tier 2: simple concurrent assertions, --assert --no-timing ==="
verilator --cc --exe --build -j 4 --no-timing -Wno-lint -Wno-style --assert \
    --top-module tb_top -Mdir obj_conc -o tb probe_main.cpp a_conc_simple.sv > build_conc.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then grep -m5 "%Error" build_conc.log; echo "RESULT(conc): COMPILE FAIL";
else
    ./obj_conc/tb > run_conc.log 2>&1; run_rc=$?
    echo "run rc=$run_rc (nonzero = assertion fired and escalated)"
    grep -E "violated|Assertion failed" run_conc.log | head -4
    echo "RESULT(conc): PASS (compiled, ran, intended failure escalated with exit $run_rc)"
fi

echo "=== tier 3a: temporal sequences under --no-timing ==="
verilator --cc --exe --build -j 4 --no-timing -Wno-lint -Wno-style --assert \
    --top-module tb_top -Mdir obj_seq_nt -o tb probe_main.cpp a_conc_seq.sv > build_seq_nt.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then grep -m4 -E "%Error" build_seq_nt.log; echo "RESULT(seq --no-timing): COMPILE FAIL";
else ./obj_seq_nt/tb > run_seq_nt.log 2>&1; echo "run rc=$?"; grep -E "Assertion failed" run_seq_nt.log | head -3; echo "RESULT(seq --no-timing): COMPILED+RAN (temporal ops DO NOT require --timing)"; fi

echo "=== tier 3b: temporal sequences under --timing (for contrast) ==="
verilator --cc --exe --build -j 4 --timing -Wno-lint -Wno-style --assert \
    --top-module tb_top -Mdir obj_seq_t -o tb probe_main.cpp a_conc_seq.sv > build_seq_t.log 2>&1
rc=$?
if [[ $rc != 0 ]]; then grep -m4 -E "%Error" build_seq_t.log; echo "RESULT(seq --timing): COMPILE FAIL";
else ./obj_seq_t/tb > run_seq_t.log 2>&1; echo "run rc=$?"; grep -E "Assertion failed" run_seq_t.log | head -3; echo "RESULT(seq --timing): COMPILED+RAN"; fi
exit 0
