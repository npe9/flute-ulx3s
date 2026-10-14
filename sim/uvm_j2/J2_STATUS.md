# J2 STATUS — PARKED 2026-10-14 (user redirect: 50 MHz campaign)

**Verdict: harness complete and lint-clean, but the UVM acceptance is
runtime-infeasible on this machine and the user redirected to the
50 MHz push.  Resume J2 when sequence-level verification is wanted.**

Blocker: the --timing build costs ~45 ms/cycle (20.5k-cycle smoke did
not finish in 15 CPU-min; a `sample` shows ~84% of CPU in per-eval
trigger re-evaluation with the UVM phase machinery in the
dynamic-trigger set).  At that speed: smoke ≈ 15 min, readback-ending
scenarios ≈ 2.5 h, any NAK scenario (ROM drain ≈ 12M sim cycles) ≈ 6
days, the 50M golden ≈ 26 days.  J1's --no-timing bench (~20-100
us/cycle) remains the only feasible full-transcript gate.

## Architecture

- `uvm_j2_base_pkg.sv` — `uart_frame_item` (framed chunk + fault knobs:
  corrupt_xor / junk_prefix / delay_cycles), `nak_diag_filter` (swallows
  the boot ROM's 25-byte ASCII NAK diagnostic `N h8 h8 sgx\r\n` between
  the J1 monitor and the J1 scoreboard; shape-checked; `freeze` flag),
  `cycle_counter`, `j2_ctrl`.
- `uvm_j2_agent_pkg.sv` — `flute_seqr` (handle carrier), `flute_uart_driver`
  (pumps bytes into the J1 bit-cadence engine, notes one scoreboard txn
  per framed chunk), `flute_env` (config_db wiring).
- `uvm_j2_test_pkg.sv` — `flute_boot_base_seq` (banner→header→ACK/NAK
  chunks→readback→hello/tick0 scenario with retry) + knob-derived
  sequences: boot_hello, corrupt_xor, double_corrupt, garbage_seq,
  chunk_delay. Tests raise the objection, run the sequence, drop.
- `uvm_tb_top.sv` — clock/reset, sim_board (instance `board`, so the J1
  hierarchical BRAM-census paths hold), J1 agents ticked on the negedge
  exactly as in sv_tb_top, UVM run_test, then the end-of-run gate
  (scoreboard verdict + coverage sampling incl. census).
- `run.sh` — same file-list discipline as J1 (BSC lib filter, strict
  BRAM2, frozen-netlist VERILOG_ALL override, per-test BUILD_DIR) plus
  the vendored UVM pkg (2020-3.2 nodpi) and image→hex conversion.

## Key design facts (hard-won, do not relearn)

- **--timing runtime is the J2 budget driver.** A sample of the smoke
  run shows ~84% of CPU in per-eval trigger re-evaluation
  (`eval_triggers_vec__act`), with the UVM phase machinery (objection
  `wait_for`, phase-hopper forks) living in the dynamic-trigger set that
  is rescanned every eval. The J1 --no-timing bench runs ~20-100 us/cycle;
  the UVM --timing build measured ~45 ms/cycle (20.5k-cycle smoke ≈ 15+
  min). Consequence: any scenario must fit its cycle budget (NAK drains
  are ~12M sim cycles = days at this speed; the 50M golden = weeks).
  Mitigations in run.sh: ASSERT=0 / COV=0 env knobs (instrumentation is
  a per-eval cost under --timing) — measure before scheduling long runs.
  HANDOFF anticipated this ("nightly if runtime grows"): full-transcript
  golden stays on J1's fast gate; J2/UVM owns the sequence layer.

- **NAK diagnostic**: the boot ROM prints `0x15` then a 25-byte ASCII
  line (`N <seq-hex8> <xor-hex8> <s/g/x flags>\r\n`) after every NAK.
  The J1 scoreboard counts every non-ACK load-phase byte as a NAK, so
  the filter is MANDATORY for any NAK scenario. The `\r` would also
  flip its phase machine early.
- **Golden end freeze**: the ROM sends `\r\n` right after
  `tick 00000000`, but the golden postload ends exactly at tick0. Any
  sim-time between the marker and final_check (UVM phase teardown!)
  would append them. The sequence sets `filt.freeze = 1` at tick0.
- **post_body knob application**: the base pre_body runs BEFORE derived
  pre_body overrides, so per-scenario knobs (max_naks) must be applied
  to the scoreboard in body(), not pre_body().
- **SV port direction sticking**: after a `ref` task arg, directionless
  args inherit `ref`. Give every task port an explicit direction.
- **Literal typing**: this toolchain type-checks task args strictly;
  pass `1'b0`/`int'(...)` at call sites.
- **uvm_fatal exits 0 on this port** (via $finish): config mistakes must
  be caught by a later real check (the smoke gate's banner check does).

## Runs

| Scenario | TEST | STRICT | Result | Evidence |
|---|---|---|---|---|
| lint | — | — | LINT OK 109 files (post-edit, incl. freeze+filt) | 12 s verilation |
| smoke | boot_hello_test +SMOKE=1 | error | DID NOT COMPLETE in 15 CPU-min (~45 ms/cyc); killed on redirect | sample: 84% eval_triggers_vec__act |
| golden / faults / negative | — | — | NOT RUN (runtime-infeasible, see verdict) | |

Resume checklist when resuming: (1) rerun smoke with COV=0 ASSERT=0 to
re-measure per-cycle cost; (2) if still slow, strip the UVM env to the
minimum component set and/or drive sequences from blocking mailbox gets
(verdict: J0-blocking-gets are legal under --timing) instead of
per-posedge polls; (3) if still slow, gate NAK-retry on J1's C++ bench
(it already implements NAK+resend in ST_CHUNKS) and keep J2/UVM for
short protocol scenarios only.  The nak_diag_filter + freeze design and
the FORCE-budget negative-gate idea remain valid.

Milestone parity vs the step9 J1 goldens: banner 20553, ACKs 162831,
readback 222580, hello 50198125 (tick0 also recorded by J1; the J2 run
prints all five for comparison).
