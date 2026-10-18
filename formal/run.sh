#!/bin/bash
# Flute riscv-formal smoke gate.
#   formal/run.sh                 -> build RVFI Verilog, generate checks, run the smoke set
#   formal/run.sh cover           -> only the cover check (find the first-retire depth)
#   formal/run.sh deep            -> the slow checks (pc_fwd, reg); hours, not a smoke gate
#   formal/run.sh insn_addi_ch0 reg_ch0 ...   -> specific checks
# Env: INSN_DEPTH REG_DEPTH PC_DEPTH COVER_DEPTH LIVE_START LIVE_DEPTH JOBS RISCV_FORMAL
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RF=${RISCV_FORMAL:-$HOME/src/riscv-formal}
BSCLIB=${BSC_LIB:-$HOME/src/bsc/inst/lib/Verilog}
# Gate depths (2026-10-17, 1KB caches + 16-entry BTB: first retirement at BMC step 52, 4th at 58):
# the smoke set finishes in ~4 min with these; raise them only after a geometry change (run `cover` first).
: "${INSN_DEPTH:=62}" "${REG_DEPTH:=75}" "${PC_DEPTH:=75}" "${COVER_DEPTH:=60}" "${LIVE_START:=55}" "${LIVE_DEPTH:=75}" "${JOBS:=4}"
# smoke = the checks that finish in minutes at the gate depths; reg_ch0 / pc_fwd_ch0 take hours at
# depth 75 (pc_fwd 2.3 h, reg > 3 h unfinished on 2026-10-17) and run as `formal/run.sh deep`.
SMOKE="insn_addi_ch0 insn_add_ch0 insn_lw_ch0 insn_sw_ch0 insn_beq_ch0 insn_jal_ch0 insn_c_addi_ch0 insn_c_j_ch0 causal_ch0 unique_ch0"
DEEP="pc_fwd_ch0 reg_ch0"
cd "$ROOT"
echo "[formal] bsc -D RVFI -> build/formal/verilog_cpu.v"
make formal-verilog > build/formal/make.log 2>&1 || { tail -5 build/formal/make.log; grep -m5 -A8 "^Error" build/formal/elaboration.log; exit 1; }
python3 formal/gen_wrapper.py build/formal/verilog/mkCPU.v > formal/wrapper.sv
cp build/formal/verilog_cpu.v formal/verilog_cpu.v
# BSC library modules the CPU can instantiate (clock/reset/probe/sync helpers excluded: not synthesizable in formal)
LIBS=$(ls $BSCLIB/*.v | grep -vE "main.v|Probe|InoutConnect|TriState|Clock|Reset|Sync|Crossing|Inout|ConvertToZ|ConvertFromZ|ResolveZ|ConstrainedRandom|ScanIn|Fork|Empty|DualPortRam|RegAligned|Load.v|ASSIGN|SampleReg|McpRegUN|RevertReg|InitialReset|LatchCrossing")
python3 - "$ROOT" "$INSN_DEPTH" "$REG_DEPTH" "$PC_DEPTH" "$COVER_DEPTH" "$LIVE_START" "$LIVE_DEPTH" $LIBS <<'PY'
import sys
root, insn, reg, pc, cover, lstart, ldepth = sys.argv[1:8]; libs = sys.argv[8:]
s = open(f"{root}/formal/checks.cfg.in").read()
for k, v in (("@INSN_DEPTH@", insn), ("@REG_DEPTH@", reg), ("@PC_DEPTH@", pc), ("@COVER_DEPTH@", cover), ("@LIVE_START@", lstart), ("@LIVE_DEPTH@", ldepth), ("@LIBS@", "\n".join(libs))):
    s = s.replace(k, v)
open(f"{root}/formal/checks.cfg", "w").write(s)
PY
# genchecks.py derives basedir/core name from the PHYSICAL cwd, so the core dir must live
# inside riscv-formal; it holds symlinks to our files and the generated checks/ output.
CORE="$RF/cores/flute"
[ -L "$CORE" ] && rm "$CORE"      # never a symlink to our dir (ln -sf would then clobber our own files)
mkdir -p "$CORE"
for f in wrapper.sv axi_formal_slave.sv verilog_cpu.v checks.cfg; do ln -sf "$ROOT/formal/$f" "$CORE/$f"; done
cd -P "$CORE"
rm -rf checks; python3 ../../checks/genchecks.py > genchecks.log 2>&1 || { cat genchecks.log; exit 1; }
targets="${*:-$SMOKE}"
[[ "$targets" == "cover" ]] && targets="cover"
[[ "$targets" == "deep" ]] && targets="$DEEP"
echo "[formal] running: $targets (depths insn=$INSN_DEPTH reg=$REG_DEPTH pc=$PC_DEPTH cover=$COVER_DEPTH, -j$JOBS)"
start=$(date +%s)
make -C checks -j"$JOBS" $targets > checks/run.log 2>&1
rc=$?
echo "[formal] done in $(( $(date +%s) - start )) s (make rc=$rc)"
for t in $targets; do
  st=$(cat checks/$t/status 2>/dev/null || echo MISSING)
  printf '  %-22s %s\n' "$t" "$st"
done
grep -lE "^FAIL" checks/*/status 2>/dev/null | sed "s#checks/\(.*\)/status#  counterexample: $CORE/checks/\1/engine_0/trace.vcd#"
echo "[formal] results under $CORE/checks/<check>/ (logfile.txt, status)"
exit $rc
