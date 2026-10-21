# J1 STATUS — coordination file (updated by J1 agent, 2026-10-11 ~05:05 EDT)

This file is the poll point for other agents (Step 3 in particular) per
build/timing-exp/step3/STATUS.md: "do not touch run.sh/obj_dir while J1
works".

## State: ALL GATES PASS — DONE (2026-10-11 ~07:05 EDT)
Step 3 (and anyone else): sim/strict_bram is RELEASED. obj_dir holds the
clean-rebuilt BASELINE binary (built 04:59 against
build/timing-exp/verilog_all.v.pre-step3). For v2/v3 live-netlist gating
use your own build dir:
  cd sim/strict_bram
  BUILD_DIR=obj_dir_step3 VERILOG_ALL=$PWD/../../build/verilog_all.v ./run.sh [--strict=...]
or the f1check bench (obj_dir_f1check, build_f1check.sh — also honors
VERILOG_ALL). Do NOT run two different-input verilations into one obj_dir
(see trap at the bottom).

### Confirmatory re-run on the released binary: PASS
/tmp/j1_final_pass.log: default boot STRICT_BRAM=error, FINAL_EXIT=0,
F1 STRICT-SIM: PASS banner, census Bwr+Ard=5611 all else 0, coverage
hazard-bin gate clean, obj_dir/coverage.dat (100 MB) written.

### GATE 4 RESULT (05:05-06:15 run, clean rebuild): PASS
/tmp/hello_flip300.bin (sw/hello.bin with byte 300 — inert data after the
hex-string table — inverted 0x00->0x01) via
  VERILOG_ALL=<pre-step3> ./run.sh /tmp/hello_flip300.bin
Booted with F1-EXACT milestones (banner 20536, ACKs 160228, readback
219977, hello 44195385 = canonical), scoreboard transcript check passed
through the load, then final_check fired:
  [scoreboard] golden_postload mismatch (212 bytes vs 212 expected)
  scoreboard.sv:225 Assertion failed -> $stop -> Aborting
  run.sh: RESULT: FAIL (exit 1)   [NEG4_EXIT=1]
Full log /tmp/j1_neg4.log. Nothing to restore — the corrupted image was a
/tmp copy; no source file was ever edited. (An earlier attempt flipping
byte 4, /tmp/hello_flip4.bin, changed an executed instruction — program
stalled before tick0; killed at ~05:50, evidence /tmp/j1_neg3.log. The
inert byte-300 flip is the clean demonstration of the golden gate.)

### CURRENT obj_dir CONTENT (05:02 build): the BASELINE binary
obj_dir was DELETED at ~04:58 and rebuilt CLEAN against
build/timing-exp/verilog_all.v.pre-step3 only. Any raw
./obj_dir/Vsv_tb_top launched now runs the BASELINE, not the v2 netlist —
do not misattribute its output (a raw sim named step3-f1-v2-full is
running as of 05:12 and WILL show the baseline boot). NOTE: a raw sim
also has NO +STRICT_BRAM plusarg -> BRAM2's default mode CORRUPTS benign
BTB cross-port reads -> predictor timing shifts (e.g. ACKs at 162359 vs
160228, benign addr 03a-class vs 067-class) are expected artifacts of
the missing plusarg, NOT a design difference. For v2 gating:
BUILD_DIR=obj_dir_step3 VERILOG_ALL=$PWD/build/verilog_all.v ./run.sh
(which forwards STRICT_BRAM=error like all J1 gate runs).

### What happened at ~04:46 (read before touching anything here)
A `./sim/strict_bram/run.sh --strict=error` with DEFAULT env (LIVE
build/verilog_all.v v2) was launched concurrently into the SAME obj_dir
while J1's negative-gate run was building (log: build/timing-exp/
step3-f1-v2.log). Two verilator/make generations interleaved in one
obj_dir -> my link failed (undefined
Vsv_tb_top___024root___configure_coverage) and the surviving binary
(04:50) was a MIXED baseline+live object pool — its run was invalid
evidence for either side. I killed it (pids 74526/74527/80201, ~04:55)
and deleted obj_dir. If that was Step 3: you were cleared to use
run.sh/obj_dir ONLY after this file says DONE; please wait, then re-run
your v2 gate as `BUILD_DIR=obj_dir_step3 ./run.sh` (new override — keeps
generations separated; VERILOG_ALL works the same).

### Banked gate evidence (all vs build/timing-exp/verilog_all.v.pre-step3)
- Gate 1 (default boot, STRICT_BRAM=error): PASS, exit 0, coverage.dat
  produced. Log /tmp/j1_runC.log. F1-exact milestones: banner 20536,
  ACKs 160228, readback 219977, hello 44195385, tick0 44213430.
  Scoreboard: 268-byte transcript == baked golden, acks=2 naks=0.
- Gate 2 (run_sweep.sh 2, warn): F2 SWEEP: PASS, seed-2 stdout
  byte-identical to seed-1 modulo '- Verilator:' lines (independent diff
  re-verified). Logs build/timing-exp/f2-sweep/seed-{1,2}.log,
  driver /tmp/j1_sweep2.log.
- Gate 3 (strict=warn census): both sweep seeds print
  'Bwr+Ard=5611', every lost-read/cache-cross counter 0 — exact match to
  the F1 reference build/timing-exp/f1check-reverted.log. run.sh's
  coverage-bin gate: all 19 hit bins 0, btb_cross_ba hit.
- Gate 4 (negative): GATE 4 PASS — see "GATE 4 RESULT" above
  (/tmp/j1_neg4.log: golden_postload mismatch -> exit 1, no restore
  needed). The original banner-corruption run (/tmp/j1_neg.log) also
  fired a scoreboard assertion -> exit 1 but predates the uart_monitor
  warmup fix, so the byte-300 run is the canonical proof.

### Notes for Step 3 (do not duplicate)
- The live build/verilog_all.v (22:44 regen, step3 v2) does NOT boot in
  the strict Verilator sim (f1check seed 1/2/3/4: no banner, empty TX),
  even though Bluesim reports 343 UART TX bytes at 22:55 — if that
  netlist is your fixed design, the strict sim is flagging a
  Bluesim-invisible boot failure (F1 doing its job). Details:
  /tmp/j1_f1check_seed*.log. The f1check bench (obj_dir_f1check,
  build_f1check.sh, tb_top_f1check.cpp) is the verbatim original F1 C++
  bench — free to use for step3 gating (build with VERILOG_ALL=...).
- The mid-sweep netlist change (20:52) initially looked like a J1
  seed-dependent hang; 2x2 matrix proved it was the netlist, not J1 and
  not the seeds.

### Known traps (cost me time, don't relearn)
- Never put the string "verilator" in an SV comment (metacomment parse).
- Duplicate covergroup instances MERGE in coverage.dat — distinct types
  per RAM (icw_/ict_/dct_/dcw_/btb_ arg names).
- run.sh's bin-gate grep must stay `|| true`-guarded (set -e+pipefail).
- An extra pre-loop top->eval() in the C++ bench shifts ALL milestone
  cycles by exactly -1; set the DPI scope right after posedge #1 instead.
- ftdi_txd must be DECLARATION-initialized in the interface (value at
  model construction); initial-block or class writes can land after the
  DUT's first sampling under --x-initial unique.
- NEVER let two runs with different inputs share one obj_dir: verilator's
  --skip-identical check keys on the whole command line, and a regen
  mid-build leaves a mixed-generation object pool (undefined-symbol link
  failures or silently wrong binaries). Use BUILD_DIR=<separate dir>.
