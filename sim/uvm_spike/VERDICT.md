# J0 verdict — UVM feasibility on Verilator 5.052 (F1 strict-BRAM harness)

> **SUPERSEDED (2026-10-10):** the "Full UVM 1.2 FAILS" row below reflects
> only the Homebrew bottle, which doesn't install the vendored UVM tree.
> A side-by-side source build at `~/src/verilator-uvm` has FULL UVM
> WORKING (no `--uvm` flag exists in any 5.0xx — the recipe is compiling
> the vendored UVM sources; all features below probe green).  See
> `uvm_full/RESULT.md` and HANDOFF.md "UVM-capable Verilator AVAILABLE".
> The rest of this matrix (classes/mailbox/randomize/coverage/SVA/vif)
> stands as the option-B capability record.

Date: 2026-10-10. Spike: `sim/uvm_spike/`. Every row below is backed by a
self-contained probe with its own `run.sh` and `RESULT.md`; re-run any of
them to reproduce the evidence.

## Feasibility matrix

| Feature | Verdict | Evidence |
|---|---|---|
| Full UVM 1.2 (`--uvm`, bundled uvm_pkg) | **FAILS** | no `--uvm` switch (`Invalid option`), no uvm-1.2 lib anywhere in the Cellar, macros undefined → `uvm_full/` |
| SV classes: inheritance, virtual dispatch, `$cast`, parameterized classes | **WORKS** | `CLASSES: PASS` → `classes/` |
| `mailbox #(T)` + `try_put/try_get/peek/num`, bounded backpressure | **WORKS** (try_* only) | `MAILBOX: PASS` → `mailbox/` |
| blocking mailbox put/get, semaphore put | **FAILS under --no-timing** | `%Error-NOTIMING: mailbox::put() requires --timing` → `mailbox/RESULT.md` |
| class-handle queues | **WORKS** | `mailbox/` |
| `randomize()` ranges/inside/dist/if-else/implication/chains/foreach-per-element/unique/inline-with/soft/constraint_mode/unsat-rc0 | **WORKS** | 15k checked solves, 0 violations → `randomize/` |
| `randcase`, `randsequence` | **WORKS** | weighted histograms correct → `randomize/` |
| array-reduction constraints (`.sum()` etc.) | **SILENTLY IGNORED** | compiles clean, `max_sum=45435` vs `< 20` → `randomize/RESULT.md` |
| SV covergroup/coverpoint/bins/auto-cross under --no-timing | **WORKS** | bin counts in coverage.dat, empty-violation-bin gate enforced → `coverage/` |
| explicit cross bins via `binsof` | **FAILS** | COVERIGN "Unsupported: 'binsof'" → `coverage/` |
| `--coverage` line/toggle/fsm/expr | **WORKS** (independent of covergroups) | coverage.dat contains line entries → `coverage/RESULT.md` |
| immediate assertions | **WORKS** (needs `--assert`) | `sva/` tier 1 |
| concurrent boolean + `|->` | **WORKS under --no-timing** | `sva/` tier 2, intended failure fired |
| temporal `##[1:3]`, `\|=>`, `[*n]` | **WORKS under --no-timing** (surprise: no --timing needed) | `sva/` tier 3a/3b |
| assertion failure → gate | **WORKS**: `%Error` + `$stop` + **exit 1** | `sva/run_conc.log` (contrast: Bluesim `$finish(1)` exits 0) |
| assertion failure census (continue running) | **NOT with explicit else $error** (`--no-stop-fail` didn't help) | `sva/RESULT.md` — census checks go in procedural class code |
| virtual interfaces into class agents, ticked per clock | **WORKS** | `VIF+DPI: PASS` → `vif/` |
| NBA to interface from class function | **FAILS under --no-timing** | NOTIMING — use blocking assigns in tick() → `vif/RESULT.md` |
| DPI-C export bridge C++↔SV | **WORKS** (needs `svSetScope` once) | `vif/` |

## Recommendation: **(B) UVM-style SV framework, no uvm_pkg** — with the
existing C++ bench reduced to a thin main (clock, args, coverage dump),
i.e. "B, wrapping rather than replacing" tb_top.cpp's proven plumbing.

Rationale: (A) is simply absent from this build. The B-building-blocks
all probe green *in the F1 harness mode* (`--no-timing`): the class
substrate for agents/sequences/scoreboards, queue/mailbox communication,
and — decisively for J2 — a **real constrained-random solver** covering
every stimulus shape the roadmap names (chunk boundaries via `inside`,
corruption injection via `dist`/if-else, cache-hammer address streams
via alignment + range chains), with reproducible `+verilator+seed`
streams compatible with the F2 sweep. J3's functional coverage exists
natively (covergroups + bins + crosses + coverage.dat greppable by the
gate). J4 gets real exit-code gating for free (failed assertions exit 1,
unlike Bluesim). (C) Python-driven stimulus would add a runtime
dependency to the gate and buy nothing: the one solver gap (aggregate
constraints) is smaller than the C++/Python-side re-implementation of
dist/if-else/unique it would take to replace it — the honest fix is
procedural aggregate bookkeeping in the sequence body, plus a standing
rule to *procedurally verify every constraint class once in its unit
test* (the silent `.sum()` drop is exactly the kind of thing that bites
otherwise). (D) hybrid elements are absorbed into B: the C++ main keeps
clock/reset/plusargs/coverage-file duties, and DPI exports remain the
escape hatch for anything awkward.

## J1 sketch against the existing sim_board harness

All new files live under `sim/uvm_spike/tb/uvm/` (J1 may promote them to
`sim/uvm/`). The DUT file list, `BRAM2.v` strict model, `sdram_model.v`,
and `run.sh` lib-filter are untouched.

Components (all patterns probe-verified):

- `board_if.sv` — `interface board_pins_if; logic clk, ftdi_txd, ftdi_rxd, btn1, jtag_tck/tms/tdi; endinterface`
- `component_base.sv` — name/parent/`children[$]`/`step_all(cycle)`
  (from `classes/tb_classes.sv`)
- `uart_agent.sv` — driver (class holding `virtual board_pins_if`,
  bit-queue per byte, 40-cycle bit cells, ticked once per clock;
  reuses tb_top.cpp's exact RX timing) + monitor (mid-bit TX sampling
  like `tx_sample()`, assembling bytes, pushing to a mailbox `try_put`)
- `uart_seq.sv` — sequence items with constraints: `chunk_len
  inside {[1:256]}`, `corrupt dist {0:=90, 1:=10}`, retry budgets
  bookkept procedurally (the `.sum()` rule)
- `scoreboard.sv` — golden TX compare: banner wait, ACK/NAK accounting,
  hello/tick markers; mailbox `try_get` from monitor (patterns from
  `mailbox/`)
- `coverage.sv` — loader covergroups (chunk position × NAK count cross)
  + strict-hazard bins that must stay EMPTY (from `coverage/`);
  `cg.sample()` called from the monitor/scoreboard per event
- `sv_tb_top.sv` — **new verilation top**: instantiates `sim_board`
  (already in the file list) + `board_pins_if`, connects
  `assign sim_board.ftdi_txd = pins.ftdi_txd;` etc., constructs agents
  in `initial`, ticks them from `always @(negedge clk)` (driving on the
  opposite edge avoids the NBA-vs-sampling race the vif probe
  documented), and exposes the DPI export API (`sv_inject_byte` etc.)
- `run.sh` change: same FILES array, `--top-module sv_tb_top`, add
  `--assert --coverage --coverage-user` to COMMON_FLAGS, keep
  `-Wno-lint -Wno-style -Wno-NOTREDOP -Wno-STMTDLY`

Coexistence with tb_top.cpp: **wrap, then shrink**. Phase 1 keeps the
existing C++ scenario FSM but replaces its `send_byte`/TX-sampling code
with calls through the DPI bridge into the SV agents (the exact
mechanism `vif/` proves); both tops stay buildable. Phase 2 (J2) moves
the scenario FSM into SV sequences and the C++ main shrinks to the
20-line `probe_main.cpp` shape (clock + args + final coverage write).

SVA placement: fatal protocol checks only (e.g. "loader ACK arrives
only after a full framed chunk", "ftdi_txd never X after reset") as
`assert property` in `sv_tb_top` with `--assert` — they exit 1 on
failure, which IS the gate. The strict-BRAM hazard census stays
procedural (as today) because a firing SVA aborts the run and
`--no-stop-fail` did not change that with explicit else-actions.

## Surprises

1. **No UVM at all** — not even the flag (`--uvm` invalid), let alone a
   bundled library; the question was answered in 30 seconds.
2. **The constrained-random solver is real** — weighted `dist` actually
   tracks weights (60/30/10 → 3628/1772/600), `unique`, `randcase`,
   `randsequence`, inline `with`, unsat→rc=0 all work. Historically
   Verilator's randomize was a stub; this build is past that.
3. **The solver's hole is silent** — `.sum()` in a constraint compiles
   warning-free and is simply not enforced (can void its whole
   constraint block). Rule: procedural aggregate checks, always.
4. **Temporal SVA (`##`, `|=>`, `[*n]`) works under `--no-timing`** —
   property ## lives in the assertion engine, not the timing engine.
   The F1 harness needs no `--timing` for J1 protocol monitors.
5. **Blocking mailboxes/semaphores are the timing-gated ones**, not
   classes or assertions: `mailbox::put()` requires `--timing`;
   `try_*` is fully sufficient for a ticked-agent architecture.
6. **Failed assertions exit 1** — the exact opposite of the Bluesim
   `$finish(1)`-exits-0 trap; Verilator-side gates can use exit codes
   directly.
7. Verilator parses the string "verilator" inside ANY comment as a
   metacomment (`BADVLTPRAGMA`), and `small`/`expect`/`down` are
   reserved words — three probe failures came from these, not from
   missing features. J1 coding style: avoid them.
8. Wall-clock anomaly: probe binaries show ~20× wall/CPU divergence on
   this machine (CPU 7.2 s vs wall 154 s for 15k solves). Investigate
   before J4 sets gate timeouts; CPU-time costs are the real ones.

## Timebox

Spike completed within budget (~60 min of probe work). All seven probes
self-contained under `sim/uvm_spike/`; nothing outside it was modified.
