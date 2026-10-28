#!/bin/bash
# AXI4 FVIP check of AXI4_Deburster (both sides). Usage: ./run.sh [depth] [REACH]
# Uses the SVA yosys (see ../README.md). Output: build/ (smt2, logs).
set -e
cd "$(dirname "$0")"
DEPTH=${1:-20}; MODE=${2:-}
Y=${SVA_YOSYS:-$HOME/src/sv-yosys/third_party/yosys/build/yosys}
B=$(dirname "$Y")/yosys-smtbmc
BSVLIB=${BSVLIB:-$(../../../scripts/bsc_lib.sh)}
RTL=${RTL:-../../../build/verilog}
S=../src
mkdir -p build
DEF=""; [ "$MODE" = REACH ] && DEF="-DREACH"
TAG=deb${MODE:+_reach}
cat > build/$TAG.ys <<YS
read_verilog -sv -formal $DEF $S/amba_axi4_protocol_checker_pkg.sv $S/amba_axi4_single_interface_requirements.sv $S/amba_axi4_definition_of_axi4_lite.sv $S/amba_axi4_atomic_accesses.sv $S/amba_axi4_transaction_structure.sv $S/amba_axi4_transaction_attributes.sv $S/amba_axi4_protocol_checker.sv $S/amba_axi4_low_power_interface.sv $S/amba_axi4_low_power_channel.sv $S/amba_axi4_write_response_dependencies.sv $S/amba_axi4_exclusive_access_source_perspective.sv $S/amba_axi4_write_response_channel.sv $S/amba_axi4_write_address_channel.sv $S/amba_axi4_write_data_channel.sv $S/amba_axi4_read_data_channel.sv $S/amba_axi4_read_address_channel.sv deb_fvip_top.sv
read_verilog -sv -formal -DBSV_NO_INITIAL_BLOCKS $RTL/mkAXI4_Deburster_A.v $BSVLIB/FIFO2.v $BSVLIB/FIFO20.v $BSVLIB/FIFO1.v $BSVLIB/SizedFIFO.v
hierarchy -check -top deb_fvip_top
sva2check
proc
async2sync
flatten
opt_clean
memory
opt_clean
setundef -init -zero
tee -o build/$TAG.stat stat
dffunmap
write_smt2 -wires build/$TAG.smt2
YS
"$Y" -q -l build/$TAG.prep.log build/$TAG.ys >/dev/null
# Guard: every assert must reach write_smt2 as a real expression. sv-yosys 03cc3a9f4 folds every
# assertion of a -formal module to constant 1 when a LATER read_verilog lacks -formal.
sed -n '1,13p' build/$TAG.ys > build/$TAG.const.ys; echo 'dump t:$assert' >> build/$TAG.const.ys
"$Y" -q -l build/$TAG.const.log build/$TAG.const.ys >/dev/null
NCONST=$(grep -c "connect .A 1'1" build/$TAG.const.log || true)
if [ "$NCONST" != 0 ]; then echo "ERROR: $NCONST asserts are constant true (vacuous)"; exit 1; fi
grep -E '\$(assert|assume)$' build/$TAG.stat || true
"$B" -s yices --presat --keep-going -t "$DEPTH" build/$TAG.smt2 > build/$TAG.bmc.log 2>&1 || true
grep -E "Assert failed|Checking assertions in step" build/$TAG.bmc.log | grep -B1 "Assert failed" | grep -v '^--' | grep -v 'failed before' \
  | sed -e 's/.*Checking assertions in step \([0-9]*\).*/step \1/' -e 's/.*Assert failed in deb_fvip_top: /  FAIL /'
grep -E "Status|PASSED|FAILED" build/$TAG.bmc.log | tail -1
