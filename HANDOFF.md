# ULX3S Bluespec work: chat summary, current state, and plans

Date of handoff: 2026-10-02 (updated 2026-10-13: reqq retry CLOSED -- see below)

## 2026-10-13 — reqq-class retry CLOSED: wedge root-caused, variant rejected on timing

The 2026-10-09 fetch-request-queue (reqq) wedge — never root-caused — was
rebuilt on the step7 base (which now ships the early-boot trap recorder)
and taken through the full strict-gate ladder. Results:

- ROOT CAUSE PROVEN: the reqq launcher fired during MODULE_RESETTING (and
  other port-A-writing states), issuing tag-RAM port-B reads that collided
  CROSS-PORT SAME-ADDRESS with reset/refill port-A writes (dcache tag set
  0x3a, t=0..60920 at boot) -- undefined on ECP5 DP16KD, invisible to
  stock Bluesim. BOTH strict engines (F1 Verilator + Track-B patched
  Bluesim) flagged the identical event deterministically. Matches the
  2026-10-09 hardware signature (dpc=0 early-boot trap loop) exactly.
- Five integration fixes followed (launcher state guard; ST_AMO/EXCEPTION
  response-state exits; queue depth 4->16; IO-read response passthrough;
  posted-store vs response-consumption race analysis), each found by a
  gate. v6 then booted + loaded + read back CLEANLY in J1 strict=error
  (0 retries, 0 BRAM events).
- CLOSED on timing: s3 P&R = 28.01 MHz vs step7 base 28.90 MHz. The queue
  cuts the fetch-ADDRESS cone, but the current critical path is the 5d
  SHIM's imem presentation logic (icache.rg_addr -> reshow_pend ->
  imem_instr) -- the queue cannot help it. Ship bar (>=12% margin AND real
  gain over 28.90) failed on gain.
- Also documented: the Bluesim boot tb's TX decode is bit-rate-mismatched
  to the DUT (20 vs 217 clk/bit) -- garbage for ANY design; J1 is the
  TX-functional gate of record.
- Tree reverted to the step7 promoted base (sources byte-identical;
  netlist regenerated; installed bit == step7 snapshot, board untouched).
  Full detail: flute-ulx3s/build/timing-exp/reqq-STATUS.md.
- NEXT 50 MHz direction: attack the shim presentation path (register the
  shim output earlier / cut reshow_pend depth / pipeline the CPU-facing
  imem mux) or go exec-side. NOT the fetch-request path.

## Bluesim vs hardware: the verification gap (2026-10-09, documented)

Three designs (pipe2, pipe3, fetch request queue) passed Bluesim and failed
deterministically on hardware. Root cause of the gap, verified against
sources:

- Bluesim's BRAM primitive (bsc/src/bluesim/bs_prim_mod_bram.h) defers puts
  to the clock edge, serializes same-port puts into different cycles
  (schedule `a_put C a_put`), and implements deterministic write-first
  read-during-write (reader always gets clean old data). A pending read can
  NEVER be lost in the model.
- Real ECP5 DP16KD: a write launched on a port while a read is pending on
  the SAME port destroys the pending read (confirmed in pipe2/pipe3); the
  model cannot express this. Yosys's DP16KD sim model (ecp5/cells_sim.v)
  is an empty stub -- no faithful post-synth sim path exists in the open
  toolchain (only Lattice Diamond simlib has one).
- BSC's Bluesim<->synthesis equivalence covers logic only; divergence
  enters via primitive models + undetermined values (mkRegU: Bluesim tracks
  undet explicitly, silicon/Yosys = arbitrary per-chip power-up state).

Incident map + working rules (BRAM port discipline, hardware-gate mandate,
DMI rescue procedure) are documented in flute-ulx3s/AGENTS.md. The DMI
rescue tools are preserved at scripts/dmi_rescue.py + scripts/dmi_dump.py
(they work even when the UART is drowned in trap spam and the normal DMI
client desyncs; note abstract GPR/CSR reads can return cmderr 2 depending on
hart state -- DMI register reads always work).

### Bluesim fix plan (2026-10-09, approved)

Gap -> fix mapping (BRAM users in our build: the 4 cache RAMs in
MMU_Cache.bsv + the BTB in Branch_Predictor_NORMAL.bsv; nothing else):

- F4 IN-DESIGN HAZARD ASSERTIONS (do first, cheap): sim-only BSV guards in
  MMU_Cache + Branch_Predictor_NORMAL, guarded by a define the synth flow
  already strips ($display/$finish are removed by the Makefile sed). Track
  per-port "read pending" (put issued, data not yet consumed) and flag any
  write put while a read is pending on the same port; flag cross-port
  same-address same-cycle. Converts the pipe2/pipe3 hazard class into a
  sim-time $finish with a message. Also add cache protocol assertions
  (queue overflow, age/seq monotonicity, snapshot invariant). Runs in every
  Bluesim sim from now on = regression guard for all future cache edits.
- F1 VERILATOR STRICT-SIM (the faithful path): harness that verilates
  build/verilog_all.v (the actual synth-bound RTL) with a strict BRAM2
  replacement model implementing the DP16KD lost-read (same-port read
  pending + write put -> pending read data corrupted, env: warn/corrupt/
  error) + cross-port same-address detection. Bench replicates SoC_Boot_Tb:
  clock/reset, UART TX banner check, blob load, jump. Catches what Bluesim
  structurally cannot, against the real RTL.
- F2 X-SWEEP on F1: Verilator --x-initial=random with a seed loop (Bluesim
  hardcodes undet to 0xAAAAAAAA per write_undet() in wide_data.cxx -- never
  explores power-up state; silicon is arbitrary per chip). N seeded runs in
  the gate.
- F3 (REJECTED, documented): patching the Bluesim C++ BRAM model
  (bs_prim_mod_bram.h) directly. Unnecessary given F4 covers the whole BRAM
  surface at the BSV level; keeping the C++ stock avoids toolchain drift.
- F5 process: hardware gate stays the final authority for BRAM-scheduling
  changes; update AGENTS.md as items land.

Validation plan for F1/F2: (a) reintroduce the pipe2 same-port read pattern
in a scratch branch -> strict sim must fire; (b) known-good design -> no
false positives on boot + REPL runs.

#### F4 DONE (2026-10-10) — landed narrower than planned, with two hard
findings from the attempt:

What shipped: `BRAM_HAZARD_ASSERT` (added to `SIM_DEFINES` in the Makefile,
sim builds only; `compile`/verilog never define it) arms PURE DIRECTION
CHECKS at all 8 BRAM put sites in MMU_Cache.bsv (fa_haz_A_write /
fa_haz_B_read helpers): port A must get bram_cmd_write, port B
bram_cmd_read, else `$display` "ASSERT FAIL" + `$finish(1)`. Zero wires,
zero shared state. Validated: sim-boot PASS (f4-sim-boot.log), sim-repl
PASS (f4-sim-repl.log), 0 ASSERT FAIL in both. Negative test (flipped
rl_reset guard arg to bram_cmd_read) fired at cycle 7 with the expected
message (f4-negtest.log) — guard works end to end; reverted and
re-validated (f4-sim-boot-final.log).

Finding 1 (BSC scheduling): ANY same-cycle observation channel added
inside MMU_Cache's `req` — bidirectional RWire reads, even a one-way
PulseWire send — makes BSC compute an Enable(imem_req) ->
ReturnValue(imem_instr) edge; every CPU rule then fails elaboration with
G0033 self-dependence (CPU_Fetch_C.rl_fetch_next_32b, rl_trap_fetch,
rl_WFI_resume, rl_debug_run, rl_finish_FENCE, ...). Tried RWire
(same-address cross-port detection) and PulseWire (any-cross-port flag);
both dead ends. Consequence: Bluesim-level guards are limited to pure
per-put-site literal checks. Also G0004: a PulseWire may be sent only
once per cycle, so two sends from one fa_req_ram_B call conflicted.

Finding 2 (gating hole): Bluesim `$finish(1)` still exits 0, so a firing
assert does NOT fail `make sim-boot`'s exit code. The gate is
`grep -c "ASSERT FAIL" <log> == 0`. Recorded in AGENTS.md rule 1.

Deliberately NOT shipped from the original F4 scope: pending-read
tracking, cross-port same-address detection, and the cache-protocol
assertions (queue overflow, age/seq monotonicity, snapshot invariant).
Rationale: (a) cross-port same-cycle is FSM-unreachable today
(A-writing rules live in reset/store/refill states, B-read issuers in
READY/REREQ/SNAPSHOT states) and Bluesim structurally cannot model its
EFFECT anyway (that is F1's job, where the strict BRAM2 model can
corrupt the data); (b) the direction checks alone catch the only
CONFIRMED fatal class (pipe2/pipe3 = read put on port A); (c) anything
stronger at Bluesim level fights the G0033 wall. BTB: still no
assertions, per the earlier review (predict_req read gated by
!rg_resetting; residual cross-port risk self-corrects via
mispredict->redirect).

#### F1 DONE (2026-10-10) — strict-BRAM Verilator sim: boot->load->hello
PASS in all three strict modes.

Lives in `sim/strict_bram/`: strict `BRAM2.v` (drop-in for the bsc lib
module; same-port lost-read = the confirmed pipe2/pipe3 DP16KD behavior,
warn|corrupt|error via +STRICT_BRAM, default error; cross-port
same-address detection split by orientation — see the BTB note below),
`sdram_model.v` (W9825G6: 4 banks, DQM masking, MRS parse, read beat
timing matched to the controller + Top.v IOB pipeline),
`ecp5_cells.v` (ODDRX1F is the ONLY ECP5 cell in Top.v), `tb_board.v`
wrapper, `tb_top.cpp` (25 MHz, BTN1=0 + 256-cycle power-on reset, real
UART RX/TX timing, scenario FSM with deadlines, seed-aware),
`run.sh` (replicates the Makefile's 100-file lib filter with lib
BRAM2.v swapped). Run: `./sim/strict_bram/run.sh` (~3 min; ~175 s is the
ROM's post-load repair window). Bench unit test: `tb_bram2_unit.v`.

Validation: PASS in warn/corrupt/error, deterministic across seeds
(banner @ 20,536; chunks ACKed @ 160,228; hello @ 44.2M cycles). Warn
census on known-good: 0 lost-reads, 0 cache-RAM cross-port hits, 5611
BENIGN BTB cross-port hits (btb_bramcore2, B-write + A-read = bp_train
vs predict, all addr 0x067, a hot hello.bin loop). Documented deviation:
BTB opposite-orientation cross-port is counted + throttled-$display,
never fatal — fatal there would kill the known-good design on benign
predictor churn (rationale + data in BRAM2.v header). $fatal verified
exit-nonzero (this build's --x-initial modes are 0|fast|unique; `unique`
= per-seed random — F2 uses it).

THREE SIDE FINDINGS (actioned below):
1. THE BLUESIM BOOT TB SPEAKS A STALE LOADER PROTOCOL. The real ROM
   (generated from boot/boot_loader.c) speaks the CHUNKED protocol
   (seq + <=255B + xor + 0x55, ACK 0x06/NAK 0x15) — but
   test/SoC_Boot_Tb.bsv streams header+payload RAW, and scripts/loader.py
   is stale the same way. sim-boot "passes" only because its criteria
   are run-to-completion — its loader coverage is VOID. F1's bench is
   currently the ONLY correct loader simulation. (Track D item.)
2. The Makefile's $display-stripping sed used GNU BRE alternation `\|`,
   which BSD sed treats literally -> matched nothing; verilog_all.v
   retained every $display (Yosys tolerated). FIXED 2026-10-10 with
   portable separate -e expressions (Track A item).
3. Same-cycle read+write on one BRAM2 port is structurally impossible
   (single WE per port) — the lost-read hazard is strictly
   "write the cycle AFTER the read put". Narrows Track B's C++ patch
   accordingly (no same-cycle collision case to model).

F1 acceptance per the original plan: (b) known-good no-false-positives
DONE for boot (REPL strict run not implemented — future; the bench
loads hello.bin only). (a) design-level pipe2 repro: DONE 2026-10-10 —
scratch MMU_Cache edit alternating port-A read/write puts across odd/even
refill cwords (snapshot: build/timing-exp/MMU_Cache.bsv.f1check; repro
log: build/timing-exp/f1check-pipe2repro.log) FATALED in 4 s with
"icache.ram_cword_set port A LOST READ: write put while read pending —
real DP16KD destroys the pending read data", exit 1. Reverted +
regenerated + re-validated: known-good PASS under strict=error on the
regenerated netlist (f1check-reverted.log). The guard demonstrably
converts the pipe2/pipe3 hazard class into a fast, precise sim failure.

#### F2 DONE (2026-10-10) — X-sweep on the strict sim: 8 seeds PASS.

`sim/strict_bram/run_sweep.sh [N]` (SWEEP_STRICT env; logs in
build/timing-exp/f2-sweep/): N runs at +verilator+seed+N under
--x-initial=unique (this build's random-per-seed mode), each must exit 0
PASS and produce output byte-identical to seed 1 modulo Verilator's own
compile-time stats (filtered). Result: 8/8 identical, strict census
clean in every seed (0 lost-reads, 0 cache-RAM cross-port, only the
known benign BTB predictor hits). The known-good design is reset-clean:
uninitialized state never leaks into observable behavior. Future gate:
run_sweep.sh after any RTL/regeneration; the identical-output
requirement catches reset-domain leaks and X-dependence that Bluesim
cannot even express.

Sed-recipe saga (why the Makefile changed twice today): the original
$display-strip used GNU BRE alternation `\|` (no-op on BSD sed, silently
retaining 656 $display lines — Yosys tolerated them, Verilator too).
First fix (separate sed -e deletes) was WRONG: $display calls span
multiple lines (orphaned continuation lines broke the netlist; Verilator
%Error). Second fix: perl -0 slurp replacing each call statement with
`;`, string-aware because 21 format strings contain `;` inside literals
((?:"[^"]*"|[ ^";])* — note the $write_ identifier trap, avoided by
requiring the open-paren). Final recipe: perl slurp, 0 $display, lint
clean, both sims pass. LESSON: any line-deleting transform on generated
Verilog is suspect; BSC emits multi-line statements.

### Bluesim remediation roadmap (2026-10-10, plan — not yet started)

F4 landed narrower than planned (pure direction checks only), which
reopens the space the earlier F3 rejection assumed covered: F4 catches
*direction* violations at the BSV level but structurally cannot model
their *effects*, nor cross-port hazards (G0033 wall). This roadmap fixes
Bluesim itself, complementing F1/F2 (Verilator strict sim = highest-
fidelity release gate, in flight as its own track).

Problem inventory (numbered for reference):
- P1: BRAM prim model idealized — serializes same-port puts, deterministic
  write-first read-during-write, pending read never lost. Root cause of
  pipe2/pipe3; prime suspect in the reqq crash (hypothesis (a): port-B
  reads issued during REFILL/SNAPSHOT collide with refill port-A writes).
- P2: no faithful post-synth sim (Yosys DP16KD stub; Diamond simlib
  proprietary). Covered by F1 instead — NOT addressed here.
- P3: undet hardcoded 0xAAAAAAAA (wide_data.cxx write_undet) — zero
  power-up-state exploration; silicon is arbitrary per chip.
- P4: G0033 wall — in-design observation inside `req` impossible; BSV
  guards limited to pure literal checks.
- P5: $finish exits 0 — assert firings never fail make's exit code.
- P6: weak pass criteria — run-to-completion, no goldens ("TIMEOUT =
  pass").
- P7: ergonomics — GB logs, compile-time verbosity, ~16 min sim-boot.

Tracks, in execution order:

- **Track A — assertion infrastructure (days, no bsc rebuild).**
  A1: probe $fatal/$error in this bsc build; if exit-nonzero works, switch
  the F4 guards (and all future asserts) to $fatal; else keep $finish.
  A2: `make sim-gate` = sim-boot + sim-repl + `grep -c "ASSERT FAIL"` hard
  fail + PASS/FAIL summary; becomes THE checked gate (replaces raw make
  exit-code reliance; see P5). Update AGENTS.md rule 1/5.

- **Track B — strict BRAM mode in the Bluesim C++ model (the F3 revival;
  ~1 week; no bsc binary rebuild needed).** F3 was rejected when F4 was
  expected to cover the surface; it doesn't, so this is back on, scoped:
  B1: verify the mechanism — generated Bluesim C++ includes
  inst/lib/Bluesim/bs_prim_mod_bram.h at sim build time, so patching the
  installed header + sim rebuild picks it up; bsc binary untouched.
  Prove with a deliberate behavior flip before writing real logic.
  B2: env-gated strict semantics in MOD_BRAM (BSV_BRAM_STRICT=
  warn|corrupt|error; default OFF = stock, so other bsc users on this
  machine are unaffected): (i) same-port write commit while a read is
  pending (launched previous cycle, DO not yet consumed) = the confirmed
  pipe2/pipe3 hardware behavior: warn prints, corrupt drives DO with RNG
  garbage, error aborts; (ii) cross-port same-address same cycle = same
  treatment. Pending window = one cycle (our BRAM2 use has
  config_output_register=False; expose as a knob if the header supports
  it). Multiple-puts-same-port-same-cycle stays unfixable (BSC scheduler
  serializes by construction — also true in generated Verilog, so not a
  divergence source).
  B3: validation: (a) known-good design at strict=error: both sims pass
  clean (zero false positives mandatory); (b) SYNTHETIC repro (scratch
  edit issuing a port-B read during CACHE_REFILL) must fire; (c) the
  preserved fetch-queue sources (build/timing-exp/reqq-*.bsv.queue) run
  under strict — expected to fire, which would ROOT-CAUSE the reqq
  incident in simulation. B3(c) is the single highest-value milestone in
  this roadmap: it converts our biggest unexplained hardware failure into
  either a fix-and-reland performance win or a documented silicon corner.
  B4: drift control: patch lives on a git branch in ~/src/bsc (the local
  bsc source tree) + scripts/apply_bluesim_patches.sh; AGENTS.md records
  the divergence; default-off env gating.

- **Track C — X exploration in Bluesim (days, parallel with B after
  B1).** C1: patch wide_data.cxx write_undet: seeded RNG fill
  (BSV_UNDET_SEED; default = stock 0xAAAA...). C2: `make sim-sweep` =
  N=8 seeds x sim-boot in the gate; requirement: identical PASS + identical
  end-of-run checksum (needs D1's checksum printout). C3: once B2 lands,
  sweep with BSV_BRAM_STRICT=corrupt to shake out latent collision
  windows. (F2's Verilator seed loop covers the same ground from the
  other engine — both are wanted: independent models catch each other's
  bugs.)

- **Track D — self-checking goldens (days).** D1: boot tb golden-compares
  its TX transcript (banner + loader handshake + hello output) and prints
  an end-of-run SDRAM checksum; divergence = $fatal. Retires the
  "TIMEOUT = pass" reading of P6 for the boot tb. D2: REPL tb golden
  transcript (known-good logs exist in build/timing-exp/). D3: fold both
  into sim-gate.

- **Track E — tandem verification (1-2 weeks, research-y).** Enable
  Flute's Tandem_Verifier in sim builds: every retired instruction diffed
  against the golden ISA model — the strongest end-to-end correctness
  check available, independent of all BRAM concerns. First measure sim
  slowdown; if >2x, run it in a weekly/nightly gate instead of every
  sim-boot.

- **Track F — engine policy (process, after B3/F1 both exist).** Write
  into AGENTS.md which engine is authoritative for which change class:
  BSV-logic edits -> Bluesim strict; BRAM-scheduling edits -> strict
  Verilator (F1) + hardware gate; release -> F1 + suite. Dev loop stays
  in Bluesim (16 min) with F1 as the pre-hardware checkpoint.

- **Track G — upstream (months, opportunistic).** Contribute strict-BRAM
  + undet-seed (both default-off) to B-Lang-org/bsc, eliminating B4's
  drift permanently. Also keep an eye on the Project Trellis ecosystem
  for an open DP16KD sim model (true post-synth path); currently
  deprioritized since F1 covers the gap adequately at the pre-synth
  level.

- **Track H — RISC-V formal hooks: RVFI from the core (1-2 weeks, pairs
  with E).** Add an RVFI observation interface to the Flute retirement
  point: rvfi_valid/insn/pc_rdata/pc_wdata/rs1_addr+rs1_rdata/
  rs2_addr+rs2_rdata/rd_addr+rd_wdata/mem_addr+mem_rmask+mem_wmask+
  mem_wdata + trap/exception signals. Define RVFI_HOOKS (sim/formal-only
  define, stripped from synthesis exactly like BRAM_HAZARD_ASSERT — pure
  observation, zero design impact). This is the industry-standard
  interface riscv-formal consumes (Track I2), gives us waveform/GDB-grade
  retirement visibility that the tandem encoder's compressed TV stream
  lacks, and is independently useful for every future CPU change.
  Relationship to E: tandem = dynamic golden-model diff (Bluesim);
  RVFI = static-checkable retirement record (formal + any sim). Land
  both at the retirement point in one editing session to avoid two
  passes over CPU_Globals/CPU.bsv. Scope caveat: Flute's retirement is
  complicated by delayed/split responses and flushes — the hook must
  follow Flute's own tv_xxx signals, not re-derive retirement; where a
  clean RVFI signal is impossible (e.g. killed speculative ops), use
  rvfi_trap/rvfi_halt semantics per the riscv-formal spec.

- **Track I — formal verification program (ongoing, staged by
  achievability).**
  I1 (protocol/interface formal — start here, weeks): SymbiYosys
  (yosys-smtbmc) on the GENERATED Verilog (build/verilog_all.v) plus bind
  files: AXI4 fabric checks (every accepted request eventually
  responds/DECERR — no hangs, no X, ordering rules), FIFO/FIFOF safety,
  UART framing, the loader handshake FSM, and BRAM discipline as pure SVA
  (port A never reads, port B never writes — the F4 checks re-expressed
  as proofs, so they constrain ALL reachable states, not just sim
  runs). Synergy: generate fabric address-range SVA from the SoC_Map
  memory-map manifest (already messageM-emitting) so the checks track the
  hardware automatically.
  I2 (core ISA formal — the stretch goal, gated on H): riscv-formal
  proof cores (insn specs, regfile integrity, pc tracking) over the RVFI
  hooks. Honest scoping: a core with WT caches + debug module + external
  SDRAM fabric needs assumptions on the memory interface; start with
  RV32I(+M) proofs under fabric fairness assumptions and bounded depths,
  expand toward A/C only if proof times stay sane. A full unbounded
  rv32imc proof is likely out of reach of open-source tooling on this
  core — record what depth/assumptions each proven check carries, and
  treat the assumptions themselves as reviewed artifacts.
  I3 (cache invariants — research, after I1): prove the properties that
  would have caught pipe2/reqq STATICALLY: snapshot-refill correctness
  (refill writes only snapshot-preserved other-way data), clean-line
  invariant (WT: cached lines match memory), no-lost-update. Requires
  tag-abstraction (data words as uninterpreted) to keep state space
  tractable. Even bounded versions of these are valuable.

- **Track J — UVM verification environment on the F1 strict sim
  (staged, gated by a feasibility spike).**
  J0 (spike, days): evaluate Verilator 5.052's UVM 1.2 subset on this
  codebase (uvm_pkg compile + a trivial agent against the strict sim).
  Decide: full UVM vs UVM-style SV (classes/sequences/scoreboards/
  coverage without uvm_pkg) — the latter captures most of the value and
  Verilator's class support is solid. Document the decision; either way
  the architecture (agents/sequences/scoreboards/coverage) is identical.
  J1 (components, 1-2 weeks): UART agent (driver/monitor/sequencer with
  real baud timing), MMIO register agent (driven from the memory-map
  manifest), TX golden scoreboard, SDRAM/DDR functional checks folded
  into the strict harness.
  J2 (sequences — the payoff): constrained-random UART loader protocol
  (random chunk boundaries, injected corrupt-xor chunks expecting
  NAK+retry, drop/delay responses), cache-hammer sequences (directed-
  random refill/snapshot-boundary traffic, LR/SC contention, misaligned
  access mixes — the exact stimulus class that killed pipe2/pipe3/reqq,
  now generated rather than hand-written), interrupt-driven MMIO
  sequences.
  J3 (functional coverage + closure): bins for cache state transitions,
  hazard windows (strict-model violation bins must stay EMPTY — a
  non-empty bin IS the failure), privilege modes, loader retry paths;
  coverage holes feed new sequences; define the coverage level required
  for the release gate (with Track F).
  J4 (integration): `sim-uvm` gate wired into the engine policy; nightly
  if runtime grows.

Sequencing: A immediately; B (B1->B2->B3, subagent-able) next; C and D
parallel once B1 proves the patch mechanism; E+H together when cache work
resumes (one retirement-point editing session); I1 after E+H (needs the
manifest SVA hookup) with I2/I3 as labeled stretch/research; J0 as soon
as F1 lands (J builds on the strict harness), J1-J3 after; F (engine
policy) after B3 + F1 + J0 all exist; G opportunistic. Status lives
here; update AGENTS.md only when a track ships (per F5).

#### Track J status (2026-10-10): J0 DONE — verdict B (UVM-style SV).
##### J1 DONE (2026-10-11) — verification components landed, acceptance PASS.

Spike under sim/uvm_spike/ (7 probes, VERDICT.md): full UVM 1.2 is
ABSENT from Verilator 5.052 (no --uvm flag, no uvm_pkg — option A dead).
Option B blocks all green in F1 harness mode (--no-timing): SV classes +
virtual dispatch + $cast, mailboxes via try_put/try_get/peek (blocking
put/get need --timing — ticked agents use try_*), covergroups incl.
crosses (binsof explicit crosses unsupported), temporal SVA (##[1:3],
|=>, [*n] — no --timing needed), assertions as GATE (failed assert =
exit 1, the opposite of the Bluesim $finish-exits-0 trap; needs --assert
on the harness). Constrained randomize() is a REAL solver on this build
(ranges/inside/dist/implication/if-else/unique/foreach/randsequence all
verified, +verilator+seed reproducible) — J2's stimulus shapes are
covered. ONE SILENT HOLE, standing rule for J2+: array-reduction
constraints (arr.sum() < N) compile clean and are IGNORED (can void the
whole block) — aggregate bookkeeping must be procedural, and each
constraint class gets a one-time procedural verification. Tooling traps:
the string "verilator" in comments is a metacomment (BADVLTPRAGMA);
`small`/`expect`/`down` are reserved words; ~20x wall/CPU divergence
observed (check before J4 sets gate timeouts). J1 sketch lives in
VERDICT.md (sv_tb_top + board_pins_if, uart_agent/uart_seq/scoreboard/
coverage, agents ticked on negedge, DPI exports keep the C++ FSM during
phase 1, run.sh gains --assert --coverage --coverage-user).

J1 (2026-10-11, acceptance PASS): sim/strict_bram/ gained board_pins_if.sv
(ftdi_txd DECLARATION-initialized — an initial-block write can land after
the DUT's first sampling under --x-initial unique and phantom-start the
ROM), uart_agent.sv (driver = tb_top.cpp's exact bit cadence; monitor =
tx_sample() port + 300-tick warmup vs random power-up on the DUT TX pin;
mailbox try_put), scoreboard.sv (golden TX transcript: banner prefix +
opportunistic banner tail + per-chunk ACK accounting incl. "ACK only
after a full framed chunk" via a DPI txn counter + baked 212-byte
golden_postload; immediate assertions = exit-1 gate), coverage.sv
(cg_loader / per-RAM hazard census as DISTINCT covergroup types —
instances of one type merge in coverage.dat / cg_milestones, sampled
once at end of run), sv_tb_top.sv (wraps sim_board untouched, agents
ticked on negedge, 2 pin-knowledge SVAs, DPI exports; sv_final_checks
reads BRAM2's counters hierarchically so the bins cannot disagree with
the printed census). C++ main keeps the scenario FSM and talks to the
agents via DPI (scope set right AFTER posedge #1 — an extra pre-loop
eval shifts every milestone cycle by exactly -1). run.sh: --top-module
sv_tb_top, --assert --coverage --coverage-user, coverage.dat to
obj_dir via +verilator+coverage+file+ (never stdout), --scenario= plug
point (non-boot = exit 2, J2), VERILOG_ALL env selects the netlist,
post-run hazard-bin gate (19 hit-bins must be 0, btb_cross_ba must be
>0 — makes --strict=warn census violations fatal). Acceptance (against
the frozen baseline build/timing-exp/verilog_all.v.pre-step3 via
VERILOG_ALL): default run PASS with F1-EXACT milestones (20536/160228/
219977/44195385/44213430) and full golden match; run_sweep.sh 2 PASS
byte-identical; census == F1 known-good both seeds (0 lost-reads, 0
cache cross-port, 5611 benign BTB); negative gate (wrong golden banner)
exits 1; lint clean with the unchanged -Wno set. J1_STATUS.md in
sim/strict_bram/ is the coordination point for Step 3 (the live
build/verilog_all.v, Step 3 v2 @22:44, does NOT boot in strict sim —
f1check seeds 1-4 all hang with empty TX — while Bluesim sees 343 TX
bytes: a Bluesim-invisible boot failure for Step 3 to root-cause;
build_f1check.sh + tb_top_f1check.cpp = verbatim original F1 bench for
that gating). J2 next: sequences on the --scenario= hook, constrained-
random loader (corrupt-xor/NAK-retry bins already stubbed), then the
UVM-migration evaluation per the note below.

#### UVM-capable Verilator AVAILABLE (2026-10-10, supersedes part of J0).

User directive: get a Verilator that works with UVM. Result: a
side-by-side source build at `~/src/verilator-uvm` (tag v5.052, same
feature set as the Homebrew binary + working UVM; Homebrew binary
untouched and still the F1/F2 gate binary).  KEY CORRECTION: no
Verilator 5.0xx has a `--uvm` flag (J0's premise) — upstream's path is
compiling the VENDORED UVM sources, which the Homebrew formula simply
doesn't install; 5.052's headline feature is UVM 2020-3.2 support.
Checklist ALL GREEN: uvm_pkg (6 vendored variants), factory, phases,
run_test, config_db, objections, sequence/sequencer/driver handshake,
sequence_item.randomize(), UVM 1.2 + 2020-3.2 DPI, --timing in phases.
Working probe preserved at sim/uvm_spike/uvm_full/ (RESULT.md has the
exact compile recipe; was /tmp/uvm_check). Drop-in verified:
run.sh --lint-only LINT OK under the new binary.
MIGRATION DECISION (pending J1 completion): keep J1's option-B
components (in flight; scoreboard/coverage are uvm_pkg-independent and
carry over as-is), then evaluate moving J2 (sequences/sequencers — the
part UVM actually replaces) onto full UVM with the new binary; user's
directive favors UVM where it pays.

#### Track B status (2026-10-10): B1-B4 DONE — strict-BRAM mode in the Bluesim C++ model.

Patched bsc's Bluesim BRAM model (`src/bluesim/bs_prim_mod_bram.h`) with an
env-gated STRICT mode (`BSV_BRAM_STRICT=warn|corrupt|error`; unset = stock,
bit-identical). Committed on the ~/src/bsc git branch `ulx3s-strict-bram`
(4b7264f6; inst/ is git-ignored — `flute-ulx3s/scripts/apply_bluesim_bram_patch.sh`
idempotently copies the committed header into `inst/lib/Bluesim/`, `restore`
reverts it). B1 mechanism, verified empirically: generated sim C++
instantiates the MOD_BRAM template from the installed header; no bsc
binary/lib rebuild needed (`libbsprim.a`'s `prim_mod_bram.o` is an empty
stub). Modeled classes mirror F1's strict `BRAM2.v`: (a) same-port LOST
READ (write put while a read is pending = the pipe2/pipe3 DP16KD behavior;
warn=count+throttled msg, corrupt=+RNG-poison the pending read's output
register, error=msg+abort — abort() finally makes this class fail make's
exit code, closing the P5 gap); (b) cross-port same-address same cycle,
ORIENTATION-AWARE per the F1 census: A-write+B-read is fatal-able in error
mode, B-write+A-read (BTB-benign) is counted + throttled-$displayed and
NEVER fatal. Strict semantics note discovered while validating: Bluesim
captures value-method reads at rule entry and commits BRAM puts at the
same bk_now right after the rule, so the pending-read window is exactly
"committed last edge, consumed by rules this cycle".

Validation (all at BSV_BRAM_STRICT=error): B3(a) known-good — sim-boot
(b3a-sim-boot.log) and sim-repl (b3a-sim-repl.log) both PASS clean to
their normal ends, 0 ASSERT FAIL, 0 hazard events (5 arming lines only).
One engine divergence: F1's Verilator census saw 5611 benign BTB b2 hits
on the same boot; Bluesim saw 0 — the engines disagree on when the two
BTB puts land in the same cycle (Bluesim is the more conservative);
lost-read/b1 classes are cycle-order properties and engine-independent.
B3(b) pipe2 repro (alternating port-A read/write in
rl_cache_refill_rsps_loop, snapshot MMU_Cache.bsv.b3repro): ABORTED at
cycle 5090 with `icache.ram_cword_set port A LOST READ` (b3b-repro-boot.log),
make exit 2; file restored + hash-verified. B3(c) reqq root-cause attempt:
the preserved queue sources (reqq-*.bsv.queue; only MMU_Cache.bsv +
CPU_Fetch_C.bsv differ from the tree, Near_Mem_IFC already identical)
replayed for the full 70M-cycle boot with ZERO strict events
(b3c-reqq-boot.log) — the reqq hardware crash is NOT in either modeled
class: no same-port lost read (port A stays write-only, port B never
written) and no cross-port same-address collision (the queue drains to
empty during refills, so the launcher never co-fires with refill port-A
writes). Ruled out / surviving hypotheses recorded in AGENTS.md incident
map: (a) is dead as a BRAM-collision story; leading (b) the RVC
odd-16b fetch-path timing, BTB/predictor interaction, or a non-BRAM
timing corner. Post-restore clean re-verify: b3-restore-verify-boot.log
PASS. Stock-mode spot check (env unset): no strict output, normal run.

#### Track A status (2026-10-10): A1 done, A2 done, A3 done (the sed fix).

A1: probed this bsc build — Bluesim `$fatal(1, ...)` prints the message
and STILL exits 0, same as `$finish`. There is no Bluesim-side nonzero
exit for assertion failure on this toolchain; the grep gate is the only
option until Track B/G changes the C++ side. Recorded as the design
constraint for all future Bluesim assertions.

A2: `make sim-gate` — runs sim-boot + sim-repl (logs ->
build/timing-exp/sim-gate-{boot,repl}.log), fails on any make error, any
"ASSERT FAIL" line (grep -c, exit-1-safe), or missing build; prints
"sim-gate: PASS". This is now THE checked Bluesim gate; raw make
sim-boot/sim-repl remain for interactive use.

A3: the verilog_all.v $display-strip was broken and then mangling (see
"F1 DONE" sed-recipe saga); final recipe is the perl slurp, string-aware.

#### Track D0 done (2026-10-10): stale loader stimulus fixed.

- `test/SoC_Boot_Tb.bsv`: RX host rewritten to the CHUNKED protocol the
  ROM actually speaks (per-chunk seq + <=256B + xor + 0x55, ACK-paced on
  the TX stream, NAK -> resend), length taken from a new
  `fn_hello_len()` instead of hardcoded bytes.
- `scripts/bin2hello_bsvi.py` (new): regenerates test/fn_hello_bytes.bsvi
  (bytes + length) from sw/hello.bin; wired into the Makefile
  ($(HELLO_BSVI) depends on sw/hello.bin) so the tb can never desync
  from the image again.
- `scripts/loader.py`: raw-stream load path replaced with the same
  chunked ACK/NAK protocol as hw_test_suite.load_blob (the -a addr flag
  is honored; the removed --pace option only mattered for the old
  RX-FIFO-less raw path).
- Snapshots of both edited files: build/timing-exp/{SoC_Boot_Tb.bsv.d0,
  loader.py.d0}.
- Validation: `make sim-gate` (A2's inaugural run) — sim-gate-run.log:
  "RX: all chunks ACKed; image loaded" in the boot log (the chunked
  stimulus now exercises the real loader), ASSERT FAIL counts boot=0
  repl=0, sim-gate: PASS. Took one compile iteration: two rule-blocks in
  rl_rx each writing rx_bit/rx_timer tripped BSC G0004 under
  -aggressive-conditions (same-register writes must live in ONE if-else
  chain per rule, not separate top-level ifs). Subsequent Bluesim loader
  regressions will now actually exercise the loader.
- NOT changed: Repl_Boot_Tb.bsv (preloads the REPL via BDPI; no UART
  loader involved).

## Flute SoC clock state (2026-10-09)

`flute-ulx3s/` now runs **natively at 25 MHz** (previously 12.5 MHz via div-2).
**Update same day:** the registered-cache pipeline (step 2) is now complete
and hardware-verified: pipelined I/D-cache netlist ("pipe4", CACHE_SNAPSHOT
refill) at seed 3 = **29.20 MHz solo PASS**, on-board suite **65 PASS / 0
FAIL / 2 WARN**, bare-metal cache test PASS, sims PASS. Makefile `SEED ?= 3`.
Verified on hardware: bitstream 26.37 MHz PASS at 25 MHz (Makefile `SEED ?= 16`,
best of a 16-seed sweep; seeds 6,7,8,11,12,14,15,16 also pass). On-board
`scripts/hw_test_suite.py`: 65 PASS / 0 FAIL / 2 WARN at 25 MHz.

Changes that produced this, in order:
1. `Flute/src_Core/CPU/CPU_Stage2.bsv` GPR bypass switched to "Option 2"
   (`BYPASS_RD`, no `bypass.rd_val`) — kills the 43 ns load-bypass→redirect→
   icache-refill critical path at its root. +1 cycle on load-use pairs.
2. `src/Top.v` div-2 removed: `wire sys_clk = CLK;` — this makes nextpnr
   ENFORCE the 25 MHz LPF constraint (before, sys_clk was derived and only
   "passed" against an auto-derived 12 MHz).
3. `src/ULX3S_Top.bsv` `sys_clk_hz = 25_000_000` (single knob: UART divisor,
   SDRAM power-up, SoC_Info CPU_HZ, BOARD manifest line all follow).
4. `src/Uart_DMI_Bridge.bsv` timeout 50M cycles, counter widened to Bit#(26).

Key facts: all placement-only levers plateau at ~23.5 MHz (HeAP seeds, retime,
SA placer fails to legalise, router2 crashes); the path is ~70% routing.
Next milestone (step 2): 50 MHz via EHXPLLL PLL + registered I/D-cache RAM
responses (explicit capture regs + MODULE_PROBE state in MMU_Cache.bsv, per
edit plan from 2026-10-09) + SDRAM ns-derived timings. Policy: keep 8KB 2-way
caches; buy speed with pipeline stages.

### Fetch request path registered: MMU_Cache request queue (2026-10-09, later)

Post-pipe2 worst path (36.0 ns, ~85% routing, perf2 seed 3): icache.rg_addr
FF -> predictor rsp / d_instr cones (merged by ABC) -> req_addr -> tag-RAM
ADDRB pin -> DOB_R FF. Functional cause: stageF.enq(pred_pc) launched the
tag/data RAM read combinationally in the SAME cycle the response was consumed,
so the next-fetch address (branch-predictor output of the current instruction)
sat combinationally on the BRAM address pin.

Fix (all inside MMU_Cache.bsv + small CPU_Fetch_C/Near_Mem_IFC edits):
- `req` is now a PURE enqueue into a depth-4 circular buffer (v_req_q,
  single-writer enq/deq counters; occupancy = enq-deq mod 8). It MUST stay
  always_ready: CPU rules call req in the same cycle they read the response
  (imem_pc etc.); a blocking enqueue gives G0004 parallel-conflicts at CPU
  level, and any FIFO (mkFIFOF/mkPipelineFIFOF) blocks => hand-rolled buffer.
- New rule rl_req_launch retires one entry per cycle: writes rg_op/f3/addr/...
  /rg_pa, does the misaligned check (MODULE_EXCEPTION_RSP), re-enters
  MODULE_RUNNING, toggles rg_req_seq, fires fa_req_ram_B. The BRAM address
  now comes from a register (queue output), cutting the cone.
- Probe guard gains `req_q_empty` (else it re-fires with stale data during
  the launch-pending window). rl_rereq unchanged (rg_addr already registered).
- +1 cycle request latency both caches; absorbed by OSTATUS_BUSY (misses cost
  ~30 cy anyway). Sequential fetch loop goes 2->3 cycles; net win if Fmax
  gain > 1.5x.
- BSV traps hit (do not relearn): (1) a boundary method with an implicit
  condition whose CAN-FIRE depends on rules => G0095 scheduling cycle
  req->...->probe->req; keep req a pure queue write and move ALL state
  transitions into the launcher rule. (2) CPU_Fetch_C.rl_fetch_next_32b lost
  its (* no_implicit_conditions, fire_when_enabled *) pair (composed conflicts
  changed; postpones are harmless -- stopped instr refetches from dpc).
  (3) bsc needs rules DEFINED before naming them in descending_urgency --
  attribute lives on rl_rereq (last in file): "rl_start_reset,
  rl_probe_and_immed_rsp, rl_cache_refill_rsps_loop, rl_rereq, rl_req_launch,
  req". Launcher lowest => queued redirect supersedes stale FSM work.
- Gate status: BSC + Yosys + Bluesim sims PASS. Hardware FAILED: CPU
  crash-loops to PC 0 within the first boot-ROM instructions (dpc=0 via DMI;
  UART drowned in trap-handler spam; boot load protocol unresponsive).
  Hardware-only failure (Bluesim clean) -- never root-caused; REVERTED the
  same day. Queue sources preserved at build/timing-exp/reqq-*.bsv.queue.
  Likely suspects if resumed: (a) launcher firing a B-port RAM read during
  CACHE_SNAPSHOT/CACHE_REFILL colliding with snapshot reads (same port,
  two puts same cycle -- bsc serializes, but the *postponed* reader then
  samples the winner's captured data); (b) `req` no longer updating
  rg_addr at req time -- any consumer of imem.pc in the req cycle sees a
  1-cycle-staler value than stock. A cleaner retry would register the
  request at the stageF boundary instead (plan C below).

Why reverted instead of debugged: measured value was only +2.5 MHz Fmax
(30.3 vs 27.8) -- the board still runs at 25 MHz, so the queue bought
margin, not speed, and its +1-cycle fetch loop (2->3 cycles/sequential
word) costs ~33% fetch bandwidth at equal clock (breakeven needs ~42 MHz).
The 50 MHz PLL step needs >=45 MHz Fmax; neither build reaches it.

REVERT COMPLETE (2026-10-09 evening): sources hand-reverted to pipe4+perf;
fresh bitstream `build/ulx3s_top.bit` (revert-s3, 28.93 MHz seed 3 PASS,
15.7% margin); suite 70 PASS / 0 FAIL / 2 WARN; extended cache test PASS.
Board confirmed healthy throughout (control: the 1204962-byte
build/timing-exp/ulx3s_top.bit.perf2.bak = valid perf2, suite 70/70).

NEW PRE-EXISTING BUG FOUND by the extended cache test (present in pipe4):
nested far calls with zero padding between functions HANG the SoC.
Repro: jal chain0..15 at 1KB stride, each callee ends in `ret` and padding
is .space zeros; depth >= 2 hangs (depth-1 flat calls at any stride work;
2.0s PASS). Likely mechanism: predictor fall-through speculation after
each jal fetches the zero padding (illegal, c.unimp), and the abort of
that refill by the real redirect wedges the blocking I-cache FSM. Cheap
repro kept at test/cache_test_dbg.S (markers T123456 then hang). The REPL
never hits this (no zero-filled gaps after calls), which is why 70/70
suite + hours of REPL missed it. Fix is future work; consider it the top
candidate if anything else I-side looks flaky.

Extended cache test (test/cache_test.S, PASS on restored build):
phases 1-4 = original D-cache store/evict/readback sweeps; phase 5 =
2KB dense unrolled block x4 reps (8KB > cache, sequential I-refill);
phase 6 = 16 flat calls at 1KB stride x8 reps (redirect+refill storm,
NO nesting -- see bug above); phase 7 = jalr through a 16-target table
at 512B stride x4 laps. Entry 'T', mismatches 'M', done 'D'.


Post-launcher sweep (25 MHz LPF constraint, PASS line at 25):

  build                seed  Fmax      worst path
  reqq (baseline ABC)  1     30.30     rg_addr -> stageF/CPU ctl -> v_req_q D (33.0 ns, 6.7 logic / 26.3 route)
  reqq                 2     27.87
  reqq                 3     28.97
  reqq                 4     28.84
  reqq                 5     29.56
  reqq                 6     29.05
  reqq                 7     30.28
  reqq                 8     27.90
  reqq -abc9           1-4   IDENTICAL to baseline (abc9 a no-op on this design; never
                       improves mapping here)

The cone moved, not shortened: previously ended at tag-RAM ADDRB; now ends
at the request-queue data D-input (same fetch loop, one register later).
Logic is only 6.7 ns of 33 -- the path is ~80% die-crossing routing across
icache -> stageF -> CPU control -> icache queue.

PLATEAU CONCLUSION (2026-10-09): ~30 MHz is the wall for this architecture
+ Yosys/nextpnr toolchain. The fetch loop (consume response -> predictor ->
next request -> RAM -> probe) is a 2-cycle loop whose combinational cloud
re-forms around every register we insert. Next meaningful steps, in order
of expected value:
  1. FETCH BUFFER / PREFETCH: on a hit, also launch pc+4's read into a
     1-2 entry side buffer; sequential consumption then no longer round-trips
     the loop (breaks BOTH the throughput 2-cycle dependency and shrinks the
     cone feeding the queue/predictor). Real design work; touches stageF.
  2. Floorplanning: path is ~80% routing; nextpnr-ecp5 lacks soft regions,
     so this means bel-attribute experiments in Yosys (laborious).
  3. PLL at 27.78 MHz (VCO 500/18): only valid on a >=30 MHz build with
     >=8% margin + SDRAM ns-timing re-derivation; the reverted queue build
     was the only candidate -- pipe4 (27.76 Fmax) has zero margin.
  4. Accept 25 MHz; move to the peripheral roadmap (HDMI/sound/USB).

STEP 3 DECISION (2026-10-10, user policy): Option 1 is the path. Standing
rule: performance comes from ARCHITECTURE, never floorplan tricks (option 2
demoted to final-margin complement on an architecturally-closed design) and
never weasel-clock PLL choices (option 3 REJECTED — the PLL is legitimate
only to multiply 25 MHz up to the architectural target, i.e. 50 MHz).
Step 3 = fetch-side decoupling (buffer/prefetch, possibly rethinking the
reqq design with its crash understood). Start is GATED on the Track B reqq
root-cause (subagent-20): the fetch queue was the first attempt at exactly
this decoupling and it crashed hardware with sims green, so its failure
mechanism must be understood (or strict-sim-protected) before re-attempting.
Target: 50 MHz (PLL 25x2) with the architectural change closing timing,
suite + cache test + F1/F2 gates all green at the new frequency.

STEP 3 GATE VERDICT (2026-10-10, after Track B): the "understood" branch
did NOT land — reqq is RULED OUT of every modeled BRAM class (Track B
B3(c): full 70M-cycle boot at BSV_BRAM_STRICT=error, zero strict events,
zero F4 asserts, trustworthy negative since the same build aborted on the
pipe2 repro at cycle 5090). Surviving hypotheses for the reqq crash, in
order: (1) the RVC odd-16b fetch-path timing (rl_fetch_next_32b lost its
no_implicit_conditions/fire_when_enabled pair in the queue build); (2)
BTB/predictor interaction with the queued request stream; (3) a non-BRAM
timing corner. BUT the "or strict-sim-protected" branch IS satisfied:
BSV_BRAM_STRICT=error in Bluesim (abort() on violation) + F1 strict
Verilator now guard exactly the classes that killed pipe2/pipe3, so a
Step 3 fetch-buffer attempt runs with both guards armed from the first
sim. GATE OPEN with conditions: any Step 3 fetch-side design must (a)
keep rl_fetch_next_32b's rule attributes intact (reqq lesson #2), (b)
keep req a pure queue write — no FSM state transitions in the method
(reqq lesson #1, G0095), (c) sim at BSV_BRAM_STRICT=error + F1
strict=error before any hardware, (d) treat surviving hypothesis (1) as
a design constraint: the odd-16b path's timing relative to any new
fetch buffering must be reviewed line-by-line.



### Step 2 progress + the DP16KD read-during-write trap (2026-10-09, later)

Cache-pipeline change applied and sim-green, but the FIRST version failed on
hardware deterministically: REPL store-misaligned fault, mcause=6,
mepc=0x8001c5a8, mtval=0x8027b15b, identical across reprograms (Bluesim
passed!). Root cause: the refill loop read word 1's old value on **port A**
at refill start, while the loop's fill **writes** also go to port A. On real
ECP5 DP16KD, a write on a port destroys that port's pending read output
(READ_FIRST shows the write address's old data); Bluesim's BRAM model instead
returns the pending read data. Sim-perfect, hardware-corrupt — word 1's
other-way word64 got clobbered, later surfacing as a garbage pointer.

**Lesson: never mix reads and writes on one BRAM port in this design.**
Bluesim will not save you; only the board suite will.

Fix attempt 2 (read-ahead +1 on port B, port A write-only): also failed
hardware-only, same deterministic way (REPL load-access-fault in VtInit,
mtval=0x82000000). DMI system-bus scan of all 2 MB of SDRAM after the
crash: **byte-perfect vs the blob** — corruption exists only in the
cache read path, not in memory. Two refill schedules, both correct under
Bluesim's BRAM model, both wrong on DP16KD: the read/write interleave
window around the refill RMW is not modelable reliably.

Fix v4 (`CACHE_SNAPSHOT` state in MMU_Cache.bsv): before the refill loop
writes anything, snapshot the victim line's OTHER-way word64s into a
register vector (8 relaxed port-B reads, port A idle, ~10 cycles per
refill). The refill loop then builds each CWord_Set purely from
{new_word64, snapshot} — zero RAM reads during the write phase, so no
read/write scheduling constraint can diverge between Bluesim and DP16KD.
Applies to both I- and D-cache (same module). See
`build/timing-exp/perf-counter-plan.md` sibling notes and
`test/cache_test.S` (bare-metal refill/hit test, loadable like the REPL
blob, prints T/D or M<addr><exp><got> per mismatch).

**Verified on hardware (2026-10-09, pipe4, seed 3):** bare-metal cache
test PASS; full on-board suite 65 PASS / 0 FAIL / 2 WARN; 29.20 MHz solo
(+17% margin at the enforced 25 MHz). Note the fabric is FABRIC64 — a
64-bit data bus — which is why the earlier +1-readahead schedule (valid
only at 2-cycle response spacing) was short by a cycle on hardware even
before any DP16KD collision. The snapshot design has no spacing
dependency at all.

DMI/perf debugging trap worth remembering: two BSV rules writing the
same register (rl_perf_count every-cycle increments vs rl_wr's
select/clear writes) silently STARVES the lower-urgency rule -- SoC_Info
stopped acknowledging writes entirely (reads fine, writes dropped, B
channel wedged). Symptom looked like the known flaky UART DMI bridge.
Fix: one writer per register; cross-rule updates via RWire. Verify
suspicious slaves with a direct "write then readback" probe before
blaming the transport.

**Perf counters VERIFIED on hardware (2026-10-09, perf2, seed 3,
27.76 MHz):** suite 70 PASS / 0 FAIL / 2 WARN. Section G: cycles rate
30.1M/1.2s (~25 MHz exact), retire 3.88M/0.5s from the REPL idle loop,
invalid-select frozen, write-clear + counting. Bitstream ships with the
feature.

Also landed (perf counters, gating same day): performance counters in SoC_Info —
PERF_SELECT_0..3 @ 0x040 (RW), PERF_COUNT_0..3 @ 0x080 (RO, write-
clears), FEATURES bit 7. Event taps: retire + redirect (CPU.bsv rl_pipe,
next to csr_minstret_incr), I/D refill starts (MMU_Cache rl_start_cache_
refill via Core/Near_Mem/CPU interfaces), UART+external IRQ edges and
bus errors (SoC_Top). SoC_Top's clk_hz is now a module parameter fed
from ULX3S_Top's sys_clk_hz (was hardcoded 12_500_000, stale since the
25 MHz move). Suite section G checks: cycles rate ~25 MHz, retire > 0,
invalid select frozen, write-clear.

**2026-10-10 evening — all remediation gates green; Step 3 + J1 in
flight (state for the next resume):**

Done and verified tonight: F4 (Bluesim BRAM direction asserts), F1
(strict-Verilator harness, `flute-ulx3s/sim/strict_bram/`), F2 (8-seed
X-sweep), Track A (`make sim-gate` PHONY gate; verilog_all.v $display-
strip is now a string-aware perl slurp — the old GNU `\|` sed was a BSD
no-op), Track D0 (boot tb + loader.py rewritten to the real ROM chunked
protocol), Track B (BSV_BRAM_STRICT=error strict-Bluesim via patched bsc
at ~/src/bsc, branch ulx3s-strict-bram; fetch-request-queue crash RULED
OUT of every modeled BRAM hazard class), J0 (UVM-capable Verilator at
~/src/verilator-uvm, v5.052, vendored UVM 2020-3.2 verified; Homebrew
binary remains the strict-BRAM gate binary). Working rules updated in
`flute-ulx3s/AGENTS.md` (quick-ref has the strict-Bluesim rebuild caveat
and the UVM path).

In flight — two subagents own these; do not duplicate or revert:

- **Step 3** (fetch buffer/prefetch in CPU_Fetch_C.bsv toward 50 MHz):
  MEASURE.md / DESIGN.md / NOTES.md in `build/timing-exp/step3/`.
  `BSV_BRAM_STRICT=error make sim-gate` PASSED for the first
  implementation (0 ASSERT FAIL, full 70M-cycle boot). A second edit
  (21:48) was mid-re-gate when the session interrupted. The live tree
  INTENTIONALLY carries the modified CPU_Fetch_C.bsv — do not revert;
  re-gate before any hardware run.
- **J1** (verification components on the F1 harness: board_pins_if.sv,
  uart_agent.sv, scoreboard.sv, coverage.sv, sv_tb_top.sv, reworked
  run.sh): code on disk in `sim/strict_bram/`, acceptance not yet
  passed. Acceptance MUST run against the frozen baseline netlist
  `build/timing-exp/verilog_all.v.pre-step3` (Step 3 changed the live
  tree) via a VERILOG_ALL env var in the scripts (default stays the live
  build/verilog_all.v so Step 3's gates keep working).

**2026-10-11 early morning — overnight subagent runs (quota-killed
tasks kept executing detached for hours; both loops' work landed on
disk before dying ~04:00):**

- **Step 3 root-caused a real bug** — the fetch buffer's first version
  hung the boot in BOTH engines (Bluesim weak-pass trap, rule 5). Unit
  tb (`test/Fetch_C_Unit_Tb.bsv`, ~3 s iteration) reproduced it in 24
  consumes: (1) back-to-back ask deposits cancel the toggle handshake,
  (2) launcher misfires on odd-16b span asks whose word already left
  the buffer — **the reqq surviving-hypothesis-#1 neighborhood, now
  confirmed as a real bug class in fetch machinery.** Fixes: 2-slot ask
  queue, case-b2 cached-half span detection, CPU.bsv urgency strings
  (launcher not starved by co-firing consumes). Unit-verified
  bit-identical vs stock wrapper; 22:55 strict-Bluesim re-gate PASS
  (343 UART TX bytes, census clean). Live tree intentionally carries
  the fixed design — do not revert.
- **Step 3 seed sweep s1-s8 done** (report JSONs in build/timing-exp/):
  s1 30.62, s3 29.03, s8 30.25 MHz vs baseline 28.93 @ s3. s3 barely
  moved → the EXEC/bp_train cone (34.56 ns at baseline) is likely
  critical now; next-lever analysis owed in its report.
- **OPEN — v2 strict-Verilator boot**: J1's old-bench f1check shows v2
  NOT booting in strict Verilator (no banner, empty TX, seeds 1-4)
  despite the Bluesim pass — either a real Bluesim-invisible bug or a
  bench artifact (old bench lacks the ftdi_txd declaration-init fix;
  v2's first-fetch timing shifted). Discriminative test (new sv_tb_top
  harness) was queued behind J1's obj_dir use. Hardware phase (seed-3
  bitstream, 70-check suite, cache test, saved step3 bit) NOT done —
  gated on that verdict.
- **J1 harness COMPLETE**: default run PASS with F1-EXACT milestone
  cycles on the baseline netlist, coverage bins correct (19 hazard
  bins, BTB cross-port hit; loader bins; 6 milestones), negative gate
  proven. Remaining when interrupted: one fresh default run +
  run_sweep.sh 2 post-ftdi_txd-fix. J1_STATUS.md is the coordination
  poll point; Step 3 may use sim/strict_bram only after it says DONE.
- J1 traps worth keeping: "verilator" string in SV comments breaks
  compiles; duplicate covergroup instances MERGE in coverage.dat
  (distinct types per RAM); an extra pre-loop top->eval() shifts all
  milestone cycles by exactly -1; ftdi_txd needs DECLARATION-init in
  the interface under --x-initial unique.

**2026-10-11 morning — FINAL VERDICTS: J1 DONE; Step 3 v2 wedged
post-load in both engines, rolled back; Step 4 = near-mem-side
decoupling; J2 migration call made:**

- **J1: ALL 4 GATES PASS** (~07:05, clean-rebuilt baseline binary in
  obj_dir): boot PASS with F1-exact milestone cycles; 2-seed sweep
  byte-identical; --strict=warn census cross-checked; negative gate
  proven cleanly (inert byte-300 flip -> golden_postload mismatch ->
  exit 1, nothing to restore). sim/strict_bram RELEASED;
  J1_STATUS.md is the coordination point. Pattern for per-netlist
  builds: `BUILD_DIR=obj_dir_step3 VERILOG_ALL=<netlist> ./run.sh` —
  never share one obj_dir across different inputs.
- **Step 3 v2 verdict**: loader phase HEALTHY (banner @20548, chunks
  @162359, readback @222108 — all +small deltas vs baseline) then
  WEDGE in the hello window: CPU spins in a ~6-instruction ROM
  mtime-vs-UART timeout poll, in BOTH engines (deterministic — NOT
  Bluesim-invisible this time). Root cause NOT isolated after
  FETCH_DEBUG traces + RX-FSM-level decoding: ask-queue protocol
  verified sound analytically and unit-tb-clean over 161 instruction
  streams; residual suspicion = loader post-chunk timeout/repair-
  window interaction under v2's shifted fetch timing. Second failure
  of CPU-side fetch decoupling on the STOCK near-mem interface (reqq
  crashed early, v2 wedged late — same class).
- **ROLLBACK VERIFIED independently (07:55)**: CPU_Fetch_C.bsv +
  CPU.bsv bit-identical to .step3 snapshots (urgency strings gone),
  15-file git diff stat identical to pre-Step-3, build/ulx3s_top.bit
  == revert-s3.bit (Oct 9 known-good, 70/70). Board never programmed
  with v2. Debug artifacts kept: test/Fetch_C_Unit_Tb.bsv,
  step3-s{1..8} sweep data, step3-f1-v2*.log. The regenerated
  verilog_all.v differs from baseline by internal name-mangling only
  (MUX/__SEL names — recompilation artifact, functionally equivalent).
- **Timing insight (v2 sweep)**: the fetch buffer DOES break the
  pin-address cone, but the exec/redirect cone re-formed THROUGH the
  launcher's enable logic (s3 34.45 ns, ~76% die-crossing routing) —
  net +0.1 MHz at s3, mean 29.95 across 8 seeds. The 50 MHz path must
  attack the exec/bp_train cone AND decouple at the near-mem boundary;
  CPU-side buffering alone cannot close it.
- **DECISION (Step 4)**: the next fetch-decoupling attempt changes the
  INTERFACE BOUNDARY — near-mem-side queue with the reqq lessons
  (G0095-safe launcher as pure action, ftn attributes intact on
  rl_fetch_next_32b) — NOT another CPU-side buffer retry. Design
  sketch belongs in build/timing-exp/step3/DESIGN.md.
  SKETCH LANDED (2026-10-11 ~08:00, "## STEP 4 DESIGN SKETCH" in
  DESIGN.md, 434 lines): near-mem-side queue inside the FSM's domain;
  invariant I3 = CPU-visible hit timing EXACTLY stock (baseline
  milestone cycles are the acceptance test that would have caught both
  prior failures); five numbered invariants from the v2 forensics;
  verification runs the J1 harness gates FIRST (BUILD_DIR isolation),
  then BSV_BRAM_STRICT=error sim-gate, then bitstream. Timing honest
  answer: near-mem-side decoupling ALONE will not reach 50 MHz — pair
  with a redirect-path pipeline fix (register fa_stageF_redirect's enq
  args so the stage1-redirect -> RAM-enable leg is register-fed;
  secondary: register the bp_train/BTB-FSM write).

**2026-10-11 evening — STEP 4 VERDICT: third sim-green/hw-red
occurrence; rollback verified; 50 MHz NOT reachable via I-side
decoupling. Forensics queued.**

- Executed per sketch: shim `mkNear_Mem_Imem_Decoup` (Near_Mem_Caches.bsv)
  + bp_train depth-2 FIFO (Branch_Predictor.bsv) + StageF always_ready
  fix. J1-first gate order caught a real boot bug en route (covered-case
  popped the ask without launching covering speculation — reqq-wedge
  class; fixed, unit-clean). Sim results: J1 strict-Verilator ALL SIX
  MILESTONES PASS with clean BRAM census (0/0/0/0 every RAM) — BUT
  hello at +2,036,714 cycles vs golden (banner +4, readback +1692 both
  fine; acks=2 naks=0 retries=0 — the +2M is stall time, not retries),
  so run.sh's timing gate marked RESULT: FAIL. Bluesim functionally
  alive, byte-identical early TX.
- Hardware: sweep mean ~24.8 MHz (WORSE than 28.93 baseline — the
  replacement logic re-formed cones). seed-3 bit 24.24 (fails timing)
  and seed-2 bit 25.44 (timing-CLEAN at 25) both FAILED the suite
  identically ("REPL never reached a prompt"); revert-s3 passed 70/0/2
  immediately after. THIRD sim-green/hw-red occurrence; this time both
  engines green + strict census clean + timing-clean bit still fails
  on the bench — leading suspect is a real-latency interaction class
  (UART/SDRAM window behavior the instant-host sims never exercise;
  cf. the +2M-cycle stall locus).
- ROLLBACK VERIFIED (17:15): 7 files restored cmp-identical from
  .step4 snapshots; git diff back to the exact 15-file baseline; build
  bit == revert-s3.bit; board on known-good (suite 70/0/2 at 17:05).
- PRESERVED for resurrection: complete spec in step3/DESIGN.md ("STEP
  4 FULL DESIGN" + "AS-BUILT REVISIONS"), executable contract
  test/Imem_Decoup_Unit_Tb.bsv, step4-s{1,2,4..8}.config (ecppack can
  rebuild failing bits WITHOUT the RTL), step4-f1-verdict.log,
  step4-hw-*.log. NB: as-built shim source was not separately
  snapshotted; a resurrection reimplements from DESIGN.md (~half day).
- FORENSICS QUEUED (scoped, before any Step 5): (1) DMI-dump the
  seed-2 failing boot (dmi_rescue/dmi_dump; config preserved) to find
  the wedge locus; (2) explain the +2M-cycle hello stall from the
  verdict log; (3) btb_cross_ba census=0 mechanism under registered
  training.
- STRATEGIC VERDICT: 3/3 I-side decoupling attempts (reqq, v2, step4)
  sim-green/hw-red. The 50 MHz path needs a different lever family —
  exec-side pipelining (stage1/stage2 boundary), leaner shim per Step
  4's own candidates, or accepting ~29 MHz and pivoting to the SoC
  feature roadmap (bus-error monitor, trace, SPI, DMA, HDMI/sound).

**2026-10-11 18:05 — STEP 4 FORENSICS (board restored, suite 70/0/2
re-verified after): the hw failure is classified and the class
changes:**

- Wedge locus (DMI over UART bridge, step4-dmi-s2-*.log): dpc=0, hart
  cannot halt (stalled mid-FETCH), system-bus peek 0x0 -> unmapped
  (frozen in SoC_Info BUSERR_ADDR=0), ROM intact. Early trap before
  mtvec init -> fetch at 0 -> frozen hang. THIS IS THE REQQ SIGNATURE
  (2026-10-09, never root-caused) — reqq and step4 likely share a
  cause: one corrupted/garbage fetch word -> illegal-instruction trap
  -> mtvec still 0 -> unmapped fetch. (v2 remains a separate,
  both-engines-functional wedge class.)
- The +2M-cycle hello delta is BENIGN: +4.66% over compiled C at CPI~2
  = one paid event per ~21 instructions = taken-branch/miss density,
  the shim's documented +1-per-divergent-fetch cost; zero delta in the
  no-fetch tick0 window confirms it. run.sh's RESULT:FAIL came from
  its hazard-bin census gate (all-zero incl. the benign btb bin), not
  milestone timing.
- btb_cross_ba=0 under registered training: expected-benign phase
  shift (regression-signal counter, no action).
- Margin hypothesis now leads: best step4 seed 1.8% margin vs baseline
  15.7%; nextpnr "PASS at 25" on 1.8% is not hardware margin. A single
  early setup violation in the shim's new fetch logic latching one
  wrong response word produces exactly the observed signature.
- STEP 5 = shim-lean (margin-first): register the CPU-visible response
  mux + shim-internal cones the s2/s3 reports flag; bp FIFO stays OUT
  (innocent per bypass bisect; fewer cones + census-gate hygiene);
  spec adds MARGIN: >=12% at seed 3, >=10% min across the sweep, bench
  probe with the first timing-clean bit before the full sweep. If a
  comfortable-margin shim-lean STILL fails the bench, hypothesis (a)
  (real DP16KD corner in the spec-launch port-B pattern) gains the
  weight and the I-side direction closes for good.

**2026-10-11 late — STEP 5 COMPLETE: BENCH-PASSED. Margin hypothesis
confirmed; shim-lean is the new best base.**

- Verdict: seed-3 bit **30.14 MHz (+20.6% margin) passed the full
  hardware suite 70/0/2**; all 8 seeds >= +11.9% (min s5 27.98), mean
  29.25 — margin spec met on RTL iteration 1. Control: baseline netlist
  at s5 = 28.11 (shim within 0.5%, no seed sensitivity).
- I3 fully achieved: **all six F1 milestones BIT-EXACT vs baseline
  golden** (step4 was +4/+1692/+1692/+2.0M off).
- **Hypothesis (b) CONFIRMED**: same port-B-read-only launch discipline
  through the stock icache.req, comfortable margin, silicon clean ->
  the DP16KD-corner hypothesis (a) loses its weight. Step4's hw failure
  is attributed to thin-margin setup violations in its unregistered
  4-slot response-mux/seen-logic cone (39.31 ns loop).
- Critical path is now the STOCK retire/perf cone (33.18 ns
  rg_epoch->stage2->stage1->soc_info) — the fetch-loop cone is gone.
  Above ~30 MHz the stock exec/bp cone limits again: 50 MHz still
  needs the exec-side attack.
- Hard-won lessons: (1) Bluesim regs have immediate cross-rule write
  visibility — BSC preserves semantics by INHIBITING same-tick reader
  rules; a registered presentation + same-rule queue read silently
  deferred +1 per fetch; FIX = drive CPU-visible presentation from
  DWires (stock dw_valid discipline; synthesis-identical comb logic,
  wire dependencies order shim-before-consumer). (2) A 0-cycle inline
  launch in the req method is unschedulable (G0010) — launch moves to
  the rule; idle first fetches +1, cycle-locked. (3) Functional
  hardening beyond step4: wait-selector, re-show ownership, and an
  exc-forwarding rg_await guard (un-asked faulting spec words can
  never trap the CPU).
- Tree state: live = 15-file baseline + Near_Mem_Caches.bsv lean shim
  (git diff 1602 insertions incl. it) + test/Imem_Decoup_Unit_Tb.bsv
  delta terms. Bit saved build/timing-exp/ulx3s_top.bit.step5-25mhz;
  board restored to revert-s3 and re-verified (70/0/2). **step5 bit is
  the new best-known — promote it next session (cp to
  build/ulx3s_top.bit, program, suite).** Gate ladder all PASS incl.
  BSV_BRAM_STRICT=error sim-gate (patch applied and restored);
  run_sweep.sh 2 determinism check was finishing at report time
  (build/timing-exp/step5/j1-sweep.log).
- Reframe of the "3/3 I-side failures" verdict: the I-side direction
  is vindicated when MARGIN is the spec — 4/4 functional gates plus
  silicon, on a design that also beats the baseline mean (29.25 vs
  28.93).

**2026-10-12 dawn — STEP 5 FINAL VERDICT: margin success confirmed;
open reset-cleanliness defect; trusted base stays baseline.**

- The seeded sweep failures (seeds 1/2, no banner) were chased for
  ~6h of systematic bisection (agent-27): shim-only register init
  (27 mkRegU -> safe inits) did NOT fix it; spec-chain-OFF @ seed1
  PASSED (the unbounded spec chain is the X-fragility AMPLIFIER);
  stock-init + spec-ON FAILED => the spec/X interaction needs
  structural bounding, not just inits. Draw tally: v1 shim {default
  PASS, seed1/2 FAIL}; hardened shim {default FAIL, seed1/2 FAIL}.
- HARDWARE NUANCE (decisive for risk): ECP5 FFs without explicit init
  power up GLOBAL-ZERO via GSR — NOT per-bit random. Verilator's
  --x-initial=unique is a STRICTER bar than this FPGA's real power-up.
  The v1 bench passes (twice, 70/0/2) are consistent with all-zero
  being a good draw; the design is likely safe ON THIS BOARD but does
  NOT meet the project's reset-cleanliness standard (F2 sweep red).
- VERDICT (agent-27's): shim-lean v1 is BENCH-VALIDATED but NOT
  recommended as the 25 MHz base until the spec chain is made
  consume-paced with an exactness-preserving 1-2-word run-ahead bound
  (or the early-boot wedge is trace-root-caused). Next attempt = Step
  5c spec-bounding.
- TREE HYGIENE (orchestrator, 05:10): live Flute tree reverted to the
  exact 15-file baseline (matches the trusted revert-s3 bit); the
  hardened-shim source is PRESERVED at build/timing-exp/
  Near_Mem_Caches.bsv.step5x-hardened (the v1 shim source was lost to
  in-place edits — the bit at build/timing-exp/ulx3s_top.bit.step5-
  25mhz is the surviving v1 artifact). Unit tb test/
  Imem_Decoup_Unit_Tb.bsv stays in tree (references the shim; not part
  of synthesis).
- LESSON for the rules: (1) ECP5 GSR global-zero power-up — Verilator
  x-initial-unique sweep is stricter than silicon; treat F2-sweep
  green as the reset-cleanliness standard, but a sweep-RED design can
  still be silicon-safe — classify before discarding. (2) Preserve
  as-built experimental sources IMMEDIATELY (the v1 shim source was
  lost; only the bit survived) — snapshot AFTER validation, not only
  pre-edit.

**2026-10-12 morning — STEPS 5c/5d: the X-fragility chase, corrected
twice, signature sharpened to a zero-time hypothesis.**

- 5c (spec bound 2, consume-paced): unit/compile PASS, but the F2
  bar went MORE red (5/5 draws). Conclusion then: speculation itself
  is the amplifier. 5d (spec-off + honest re-baseline: banner +4 /
  ACKs +2402 / readback +2402 / hello +4,002,439, measured 5x and
  baked into the unit tb as an explicit table) ALSO went 8/8 RED —
  OVERTURNING 5c: the "spec-off passed seed1" was the stock-init
  confound. The X-fragility is in the shim's SHARED structure
  (queue-driven demand launches + DWire presentation + wait-
  selector), not speculation. Margin win confirmed speculation-
  independent: 5d s3 = 28.41 MHz (+13.6%).
- SHARPENED SIGNATURE: wedged seeds hang BEFORE the cycle-0 SDRAM MRS
  print (log frozen at 313 B) — a ZERO-TIME hang = combinatorial
  oscillation under X that Verilator spins on at time 0; only some X
  draws converge (the default draw does). Cheapest discriminator:
  verilator --lint-only -Wall on the shim+wrapper pair for UNOPTFLAT
  (comb-loop) warnings — names the loop directly. That is Step 5e
  (checkpoint-gated: lint first, ladder only if a loop is found,
  STOP-and-report if clean).
- STRATEGIC OBSERVATION (to weigh with the 5e outcome): the shim
  family's critical cone re-forms to the STOCK retire/perf path
  (~33.18 ns) in EVERY variant, and baseline s3 = 28.93 vs shim-best
  30.14 — so a green shim buys ~1-1.2 MHz over baseline, while the
  50 MHz goal needs the exec-side attack on that stock cone
  regardless. The shim's marginal value may belong to the 50 MHz
  work rather than to a 25 MHz base decision.
- STATE: tree = 15-file baseline (5d/5c/hardened as-built sources all
  preserved under build/timing-exp/Near_Mem_Caches.bsv.step5*-asbuilt
  / .step5x-hardened); board on revert-s3 (verified 70/0/2). The
  entire near-mem-side shim family must not ship until root-caused.
- **J2 MIGRATION CALL (made)**: J1 validated the option-B harness;
  J2 (constrained-random sequences + fault injection) leans FULL UVM
  on ~/src/verilator-uvm (5.052) for the sequence/sequencer scope,
  keeping J1's uvm_pkg-independent scoreboard/coverage as-is.

**2026-10-12 midday — F2 SWEEP RE-JUDGED 8/8 GREEN: the "wedges" were a
third watcher artifact; 5d (spec-off shim) EXONERATED, promotion ladder
to bench launched.**

- The 5c/5d "8/8 wedged" verdicts died in layers: (1) growth-watcher
  killed wrapper subshells -> orphaned sims starved later seeds; (2)
  313-byte logs were stdout block-buffering (fixed with `script -q`
  pty); (3) the sound-watcher re-run then "failed" all 8 seeds on a
  JUDGE-PATTERN artifact — step5d-sweep.sh greps `RESULT: PASS` but the
  J1 harness prints `F1 STRICT-SIM: PASS`. All 8 seed logs are complete
  healthy runs: banner 20540 / ACKs 162630 / readback 222379 / hello
  48197824 / tick0 48215869 (exact 5d re-base), strict census clean
  (benign BTB 5593 only), BYTE-IDENTICAL across all 8 seeds. Grep fixed
  to `-E "(RESULT|STRICT-SIM): PASS"`.
- Lint verdict stands: ZERO UNOPTFLAT — no combinatorial loop; the
  zero-time-oscillation hypothesis is dead. The only real X-fragility
  data point remaining is 5x SPEC-ON (full-run wedges on multiple
  draws); spec-off 5d is sweep-clean. Shared-structure hypothesis
  retracted for 5d.
- Ladder on the current tree (shim confirmed present in git diff + its
  rg_* registers confirmed in build/verilog_all.v, re-emitted 08:20
  from the 5d-asbuilt restore): gates 0/1/2a/3/4 all PASS (unit tb
  measured re-base; compile; J1 default-draw strict=error; Bluesim
  strict sim-gate boot=0 repl=0; s3 post-route 28.41 MHz = +13.6%
  margin, line 709 of step5d-s3.log — the 21.69 MHz line 159 is the
  pre-route placement estimate).
- ecppack --compress -> build/ulx3s_top.bit.step5d-25mhz (installed as
  build/ulx3s_top.bit; revert-s3 preserved at build/timing-exp/
  revert-s3.bit). **BENCH: hw suite 70/0/2 PASS + cache test PASS — the
  5d spec-off shim is the promoted 25 MHz base; the near-mem-side shim
  line CLOSES WON.** The 50 MHz attack targets the surviving 35.2 ns
  cone on this base: shim q_rd FF -> imem_exc/imem_pc DWires ->
  bp_train_is_i32 CCU2C -> stage2_full/rg_state/rg_step_count ->
  soc_info.EN_note_retire -> dcache EN_req/rl_rereq -> BRAM ENB (~32 ns
  routing = retire-side + cache-enable control reconvergence; cut it
  with pipeline stages, not floorplanning — rule 0). The 5x spec-ON
  full-run wedges remain the only unroot-caused X-fragility; do not
  re-enable speculation without an F2-green re-run.

**2026-10-12 afternoon — STEP 6 (50 MHz attack) opened on the 5d base;
Cut 1 closed empty; Cut 2 (bp_train RAS registration) applied,
ladder running.**

- Cone trace (explore agent, DESIGN.md + step6/STATUS.md): the 35.2 ns
  path = shim q_rd -> wait-selector (2x32b compares) -> imem_exc/pc
  DWires -> d_instr -> bp_train_is_i32 CCU2C -> rl_pipe gating ->
  [soc_info LUTs are sibling sinks, NOT a dependency] -> dcache EN_req/
  rl_rereq -> port-B read enables. soc_info note_retire delay = ~0 ns
  (rejected as a fix).
- CUT 1 (DWire-driver wait-selector -> registered rg_last_*): all
  functional gates PASS, timing-neutral as argued, but s3 = 27.76 MHz
  (-0.65 vs 28.41): cone re-formed stage1_rg_stage_input -> dcache
  DOB_R (stock read-data path). The shim head was removable but not the
  limiter. Reverted per 2-iteration cap; as-built at
  Near_Mem_Caches.bsv.step6-asbuilt. CLOSED.
- CUT 2 (CPU.bsv feed-F captures (pc,is_i32,instr)+valid; bp_train uses
  the 1-cycle-old bundle; RAS shift gated by bundle_valid; BTB write
  timing UNCHANGED — BRAM port scheduling preserved): applied,
  compile-clean, as-built snapshots *.step6c-asbuilt. Ladder: J1
  strict=error + Bluesim strict sim-gate running; then F2 sweep 8/8,
  s3 P&R (ship bar: >=29.5 MHz AND >=12% margin), bench.
- Strategic read: shim value = architectural (bench-validated health),
  ~cost-neutral at s3; the MHz belong to the stock exec/dcache cone.
  Cut 3 candidate (user-blessed): register dcache RAM read response
  (+1 cycle on hits) against the DOB_R tail.

**2026-10-12 evening — STEP 6 mid-course correction: Cut 3 was already
implemented (pipe4, 2026-10-09); the 50 MHz path now runs through three
specific items.**

- agent-30's brief (step6/DESIGN.md): the capture regs + age-toggle probe
  (MMU_Cache.bsv:660-685) ARE the response registration — 2-cycle hits
  since pipe4, in the benched base. All three s3 reports (5d 28.41, Cut1
  27.76, Cut2 27.78) show the same loop: CPU control reg -> BRAM port-B
  enable/addr -> comb read -> DOB -> capture FF. Data half is spent; the
  ~33 ns remainder is the request/control half (stage1/shim -> EN_req/
  rl_rereq -> ENB). Cut 1/2 were whack-a-mole on that half.
- CORRECTED 50 MHz ITEMS: (1) config_output_register=True measure-only
  experiment (~2-3 ns est., Rule-1 suspect); (2) reqq-class launcher retry
  ONLY after bench forensics on the 2026-10-09 wedge (DMI-dump program —
  the forensics item gates it); (3) exec-side pipeline work on the stock
  retire cone. SDRAM reclock still downstream of architectural closure.
- STEP6D + FORENSICS ADDENDA (same day evening): (a) config_output_
  register=True measured 27.25 MHz — worst of four (base 28.41 / cut1
  27.76 / cut2 27.78 / outreg 27.25), reverted; the ~28 MHz placement
  plateau verdict stands, no more single-segment experiments. (b) The
  gated reqq bench forensics are DONE: the preserved reqq-abc9-s1 bit
  (30.30 MHz) wedges deterministically (pre-UART-init early trap loop;
  non-ASCII trap-handler spam; dpc=0). DMI halt works (UART goes silent),
  but abstract GPR/CSR reads return cmderr=2 in that integration — the
  hart0_gpr/csr tap chain is a reqq-era side-effect casualty, and it
  blocked the state dump. Retry prerequisites are now concrete: verify
  the DM tap chain (Core.bsv:233-284) in any new integration, and land
  the EARLY-BOOT TRAP RECORDER (ROM handler writes mcause/mepc/mtval to
  a magic SDRAM location; host reads via the always-working DMI system
  bus) — it converts any future wedge into a diagnosable event and
  unblocks the 50 MHz request-path elasticization retry. Board restored
  to the promoted 5d bit (banner verified). Full trail:
  build/timing-exp/step6/STATUS.md.
- STEP 7 SHIPPED (same day ~21:20): the early-boot trap recorder is the
  new promoted base — boot_loader.c writes progress (8 milestones) +
  trap records (mcause/mepc/mtval/mstatus/count) to 0x81FFFF80, readable
  via scripts/forensic_read.py over the DMI system bus (works wedged);
  ROM 2137 B fits 4 KB.  Ladder green: sim-gate / J1 (golden banner
  20542, ACKs 161680, readback 221429) / F2 8/8 byte-identical /
  s3 28.90 MHz (+15.6%) / suite 70-0-2 / cache PASS.  Live-validated.
  Base = build/ulx3s_top.bit.step7-25mhz (= 5d + recorder).  Next:
  reqq-class retry (rebuild reqq with this ROM + verify the DM tap
  chain), then J2.

This document records the useful context and conclusions from the Codex session
that brought up a Bluespec design on the attached ULX3S-85F. It is intended to
let a future session continue without access to the original chat.

## Executive summary

The working project is `bluespec-ulx3s/`. It implements:

- an eight-LED walking light advancing once per second;
- a 115200-baud FTDI UART that sends `U` once per second;
- UART receive and byte echo;
- automatic power-on reset plus manual reset with FIRE1; and
- an explicit low level on `wifi_en` to hold the onboard ESP32 in reset.

The last point was the key hardware discovery. If `wifi_en` is not driven low,
the ESP32 interferes with the FTDI UART. The FPGA design, pins, host serial port,
and baud rate were all correct, but no UART data was visible until the ESP32 was
disabled.

The final hardware test succeeded:

```text
periodic= b'UU' reply= b'AU'
```

That means two periodic `U` bytes were received, then an `A` sent by the host was
echoed, followed by another periodic `U`.

The final Bluespec image was loaded into volatile FPGA SRAM at the end of the
successful test. Power cycling will restore whatever is stored in configuration
flash; this work did not write flash.

## Workspace layout

```text
ulx3s-experiments/
├── HANDOFF.md                         # this file
├── known-good-f32c.config             # decoded/reference f32c configuration
├── bluespec-ulx3s/                    # current working Bluespec project
├── verilog-ulx3s/                     # plain-Verilog diagnostic project
└── ulx3s-bitstreams/                  # known-good prebuilt images and flash backup
```

Important known-good images include:

```text
ulx3s-bitstreams/f32c-selftest-85f.bit
ulx3s-bitstreams/debugblink-v2.0-85f.bit
ulx3s-bitstreams/litex-linux-85f.bit
ulx3s-bitstreams/memtest-32MB-190MHz-85f.bit
ulx3s-bitstreams/flash-backups/ulx3s-factory-20261001.bin
```

## Current source files

### `bluespec-ulx3s/src/Blinky.bsv`

`mkBlinky` contains the LED counter and the UART TX/RX state machines. Its
external interface is:

```bsv
interface BlinkyIfc;
   method Bit#(8) led;
   method Bit#(1) serial_tx;
   method Action serial_rx(Bit#(1) value);
endinterface
```

The UART assumes a 25 MHz clock. A bit lasts 217 clocks, which is approximately
115200 baud. The receiver double-synchronizes its asynchronous input.

### `bluespec-ulx3s/src/Top.v`

The Verilog wrapper connects BSC-generated Verilog to board pins. It now has a
short power-on reset counter because BSC-generated registers require reset
before their state is usable. FIRE1 remains a manual active-high reset input.

Most importantly, it contains:

```verilog
assign wifi_en = 1'b0;
```

Do not remove this while using the FTDI UART unless the design deliberately
implements safe ESP32/FTDI passthrough arbitration.

### `bluespec-ulx3s/constraints/ulx3s_85f.lpf`

Relevant board pins are:

```text
CLK       G2    25 MHz
BTN1      R1    FIRE1
ftdi_rxd  L4    FPGA output to FTDI
ftdi_txd  M1    FPGA input from FTDI
wifi_en   F1    ESP32 enable/reset; driven low
LEDs      B2 C2 C1 D2 D1 E2 E1 H3
```

### `bluespec-ulx3s/Makefile`

The default FPGA density is now correctly set to `85k`. The original default
was `12k`, which produced this programming failure:

```text
mismatch between target's idcode and bitstream idcode
bitstream has 0x21111043 hardware requires 0x41113043
```

`openFPGALoader --detect -b ulx3s --verbose` identifies the attached part as:

```text
idcode 0x41113043
family ECP5
model LFE5U-85
```

## Build and test commands

From `bluespec-ulx3s/`:

```sh
make -B bitstream test
make program
```

Expected simulation result:

```text
PASS: echoed 41
```

The last full place-and-route result met timing comfortably:

```text
Max frequency: 164.12 MHz
Required frequency: 25.00 MHz
```

Open the hardware UART with:

```sh
screen /dev/cu.usbserial-120001 115200
```

The terminal should receive `U` approximately once per second. Typed bytes
should be echoed. To leave `screen`, use `Ctrl-A`, then `K`, then confirm.

If scripting the test without `pyserial`, Python's built-in `termios`, `select`,
and `os` modules work. The successful automated test listened for `U`, wrote
`A`, and required both `U` and `A` in the received stream.

## Investigation history and evidence

### 1. Initial simulation and build

The generated BSC Verilog passed the Icarus Verilog UART testbench. Yosys,
nextpnr, timing analysis, and `ecppack` also completed successfully.

### 2. Wrong FPGA density

The first bitstream targeted the 12K ECP5 and could not be loaded into the 85K
device. `DEVICE ?= 85k` fixed this. The README was corrected from ULX3S-12F to
ULX3S-85F.

### 3. Explicit reset requirement

BSC-generated Verilog contains diagnostic initial values and relies on its
active-low reset input. Requiring a physical FIRE1 press after every SRAM load
was fragile, so an eight-bit power-on reset counter was added to `Top.v`.

### 4. UART appeared completely silent

Both the Bluespec design and a separate plain-Verilog transmitter appeared
silent on `/dev/cu.usbserial-120001`. Several hypotheses were tested and ruled
out:

- The host port was correct and could be opened at 115200 baud.
- L4/M1 are the official ULX3S FTDI pins.
- K4/K3 are the ESP32 UART pins and did not solve the issue.
- A clockless combinational M1-to-L4 loopback was initially silent.
- Rebuilding with current, stable, Homebrew, and coherently paired
  nextpnr/Project Trellis combinations did not change the result.
- Patching decoded ECP5 pad configuration fragments did not solve it.

These experiments generated additional toolchain directories under
`bluespec-ulx3s/toolchain/`:

```text
nextpnr-build-homebrew/
nextpnr-build-coherent/
nextpnr-0.11.1/
nextpnr-0.11.1-build/
```

They are diagnostic build artifacts and are not required by the Makefile. The
Makefile still uses `toolchain/nextpnr-build/nextpnr-ecp5` by default.

### 5. Known-good f32c control test

Loading `ulx3s-bitstreams/f32c-selftest-85f.bit` produced readable output on the
same port and with the same host test code:

```text
2001-01-01 00:00:00 FAIL ...
EDID EEPROM:0 CRC=c0 FAIL
...
DAC: L3210 OK R3210 OK V3210 OK
```

This proved the board, FTDI device, USB cable, `/dev/cu.usbserial-120001`, and
115200-baud terminal settings were good. It also showed that the earlier claim
that the physical UART path was faulty was incorrect.

### 6. Root cause: ESP32 interference

Inspection of the f32c top-level design revealed that it explicitly drives
`wifi_en` low in normal mode. The Bluespec and plain-Verilog designs had left
this pin unconstrained, allowing the ESP32 to remain enabled.

A temporary test added `wifi_en` on FPGA pin F1, drove it low, and implemented a
pure combinational M1-to-L4 loopback. The result was immediate:

```text
sent:     WIFI-OFF-PASS\r\n
received: WIFI-OFF-PASS\r\n
```

The temporary loopback was then removed, the real Bluespec UART was restored,
and the hardware test passed with periodic output and echo.

## Important lessons

- Treat a known-good bitstream as a control before blaming cables or board
  hardware.
- On this ULX3S, UART ownership includes the ESP32 enable state, not just L4/M1.
- Hold `wifi_en` low for a simple FPGA-to-FTDI design.
- Always target `--85k` for this attached board.
- Give BSC-generated modules a deterministic reset after FPGA configuration.
- `make program` is SRAM-only and safe for iteration; it does not update flash.

## Recommended immediate engineering plan

The best next project is a reusable ULX3S Bluespec board-support package. It
should capture everything learned here so future designs cannot accidentally
repeat the reset, device-density, or ESP32/UART problems.

Suggested phases:

1. Create a `Board/ULX3S` package with typed interfaces for LEDs, buttons, UART,
   and reset.
2. Move UART timing into a parameterized module accepting clock frequency and
   baud rate rather than embedding 217-cycle constants.
3. Split UART TX and RX into independent modules connected by FIFOs.
4. Add receive framing-error and overflow reporting.
5. Add an explicit board-level policy for ESP32 ownership: disabled, passthrough,
   or FPGA-controlled.
6. Add a synthesizable power-on-reset module and reset-domain documentation.
7. Build a UART command console on top of the package.
8. Add automated full-wrapper simulation so the power-on reset is tested, not
   only `mkBlinky` in isolation.
9. Add a hardware smoke-test script that programs SRAM, waits for periodic `U`,
   sends a random byte sequence, and verifies exact echo.
10. Only after this foundation is stable, add peripherals such as OLED, SPI,
    SD, HDMI, and SDRAM.

## Bluespec project roadmap for ULX3S

### Foundation and instrumentation

1. **Reusable ULX3S board-support package** — Typed interfaces for clock/reset,
   LEDs, buttons, FTDI UART, ESP32 ownership, SPI, HDMI, SDRAM, and safe unused
   pins.
2. **UART command console** — Commands for LEDs, buttons, counters, register
   reads/writes, and system status.
3. **Parameterized UART library** — Independent TX/RX modules, FIFOs, arbitrary
   clock/baud settings, framing errors, and flow control.
4. **UART-controlled logic analyzer** — GPIO sampling into block RAM, edge or
   pattern triggers, circular pre-trigger history, and VCD/CSV download.
5. **Rule-scheduling demonstrator** — LEDs and counters expose which Bluespec
   rules fired and how conflicts affect throughput.
6. **Clock-domain-crossing library** — Gray-pointer asynchronous FIFOs with
   assertions and tests between system, video, and audio clock domains.

### Displays and graphics

7. **OLED system monitor** — Uptime, buttons, UART traffic, counters, and small
   animations on SSD1306/SSD1331 displays.
8. **HDMI text terminal** — Character framebuffer, font ROM, cursor, UART input,
   and an ANSI escape parser.
9. **Tile and sprite graphics engine** — Palettes, scrolling, composition, and a
   UART or memory-mapped command interface.
10. **Conway's Game of Life** — Streaming line buffers with direct HDMI output
    and UART editing controls.
11. **Mandelbrot/Julia renderer** — Parallel fixed-point iteration pipelines
    with HDMI display and UART-controlled zoom.
12. **Oscilloscope/spectrum display** — Sample external signals, buffer them,
    render traces over HDMI, and later add a fixed-point FFT.
13. **SDRAM framebuffer** — Memory-backed video with asynchronous FIFOs and
    underflow monitoring.

### Audio and lighting

14. **WS2812/NeoPixel engine** — FIFO-fed timing engine with gradients,
    animations, and optional audio-reactive modes.
15. **Audio synthesizer** — Numerically controlled oscillators, envelopes,
    filters, mixing, and PWM or sigma-delta output.
16. **Polyphonic tracker** — Add SD-card song loading and an HDMI tracker UI to
    the synthesizer.

### Storage and memory

17. **SPI peripheral laboratory** — Reusable SPI controller exercised against
    flash, SD, OLED, and external sensors.
18. **SD-card block device** — SPI mode, partition parsing, then a read-only
    FAT32 layer for fonts, images, audio, and application data.
19. **SDRAM controller** — Initialization, refresh, bursts, bank scheduling,
    arbitration, and randomized memory tests.
20. **DMA engine** — Memory/stream channels with descriptors, alignment logic,
    arbitration, and performance counters.
21. **Wishbone or AXI-Lite fabric** — Typed address decoding, arbitration,
    pipelining, error responses, and clock crossings.

### Networking

22. **Packet-level Ethernet device** — Ethernet, ARP, IPv4, ICMP, and UDP,
    beginning with ping and a UDP LED-control protocol.
23. **FPGA network terminal** — Combine Ethernet and the HDMI terminal with a
    small remote-console protocol.
24. **Streaming packet parser** — Parse and classify Ethernet/IP/UDP packets,
    calculate checksums, and collect counters without storing whole frames.

### Processors and larger systems

25. **Tiny Bluespec CPU** — Begin with a multicycle 8/16-bit processor, then add
    pipelining, forwarding, caches, and branch handling.
26. **Forth machine** — Compact stack processor with block RAM, UART, GPIO, and
    an interactive interpreter.
27. **RISC-V peripheral subsystem** — Reusable Bluespec UART, GPIO, timers,
    interrupts, SPI, and memory interconnect around an existing core.
28. **Cached RISC-V SoC** — Instruction/data caches, SDRAM, boot ROM, debug UART,
    timers, and DMA, capable of running a monitor or RTOS.
29. **Dynamic dataflow processor** — Tagged tokens flowing through FIFO-connected
    arithmetic nodes for image or signal-processing graphs.
30. **Multi-core message-passing machine** — Several tiny processors/state
    machines connected by typed channels and a router.
31. **ULX3S self-test suite** — Bluespec versions of LED, button, SDRAM, flash,
    SD, audio, HDMI, and UART diagnostics with structured pass/fail output.

## Suggested project order

For maximum reuse and steady difficulty growth:

```text
board-support package
  -> robust UART library
  -> UART command console
  -> logic analyzer
  -> SPI/OLED
  -> HDMI text terminal
  -> SDRAM controller
  -> SDRAM framebuffer
  -> CPU or Ethernet system
```

The strongest standalone showcase ideas are:

- UART logic analyzer;
- HDMI text terminal;
- Mandelbrot renderer;
- polyphonic audio synthesizer;
- SDRAM framebuffer;
- Ethernet/UDP stack;
- Forth or RISC-V SoC; and
- a comprehensive ULX3S Bluespec board-support package.

## Notes for the next Codex session

Start by reading this file and `bluespec-ulx3s/README.md`. Do not repeat the
UART pin or toolchain investigation unless the working `wifi_en = 0` behavior
regresses. The decisive hardware facts are:

```text
FPGA: LFE5U-85, ID 0x41113043
UART: /dev/cu.usbserial-120001, 115200 8N1
FPGA TX -> FTDI: L4 / ftdi_rxd
FTDI TX -> FPGA: M1 / ftdi_txd
ESP32 enable: F1 / wifi_en, must be driven low for this design
```

Before changing the design, establish the baseline with:

```sh
cd /Users/npe/src/ulx3s-experiments/bluespec-ulx3s
make -B bitstream test
make program
```

Then verify that `U` arrives once per second and that transmitted bytes echo.

