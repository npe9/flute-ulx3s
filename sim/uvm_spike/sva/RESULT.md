# sva — result: WORKS (full subset probed, incl. temporal ## — a surprise)

Probe: three tiers, all with `--assert` on the verilation command line.

- **tier 1** `a_imm.sv`: immediate `assert ... else ...` under
  `--binary --no-timing`. PASS — else-branch executes on failure,
  no timing needed.
- **tier 2** `a_conc_simple.sv`: clocked concurrent assertions —
  pure boolean (`!$isunknown(...)`), overlap implication
  (`req |-> gnt_ok`), plus a deliberately-failing copy. Under
  `--no-timing` with a C++ clock main. PASS.
- **tier 3** `a_conc_seq.sv`: temporal sequences `|-> ##[1:3]`,
  `|=>`, `[*1]` — **compiled and ran under `--no-timing`** (no
  `--timing` needed; property `##` is handled by the assertion
  engine, not the timing engine). Verified identical behavior with
  `--timing` for contrast.

Failure behavior (evidence: `run_conc.log`, `run_seq_nt.log`):

```
[10] %Error: a_conc_simple.sv:32: Assertion failed in TOP.tb_top.a_fail: FAIL property violated at cycle 4 (expected once)
%Error: a_conc_simple.sv:32: Verilog $stop
Aborting...            (process exit code 1)
```

- A failed assertion prints `%Error: Assertion failed`, calls
  `$stop`, aborts the run with **exit code 1** — exactly what the
  J4 make-gate wants (and the opposite of the Bluesim
  `$finish(1)`-still-exits-0 trap in AGENTS.md rule 1).
- `--no-stop-fail` did NOT prevent the abort with an explicit
  `else $error(...)` action in this build — the run still stopped.
  Consequence for J1/J3: SVA = fatal protocol checks. Census-style
  monitors (e.g. the strict-BRAM hazard count, which must aggregate
  and keep running) belong in procedural class code (plain
  `if (!ok) n_viol++`), not SVA.
- `--assert` is NOT in the F1 harness's flag set today — J4 must add
  it (and decide per-check fatal vs procedural).
