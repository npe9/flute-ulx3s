# ULX3S Flute SoC — working notes for agents

## Bluesim vs hardware: what Bluesim cannot see (READ FIRST)

Bluesim passes are **necessary, not sufficient**. Three designs in this
project (pipe2, pipe3, the 2026-10-09 fetch request queue) passed Bluesim
cleanly and failed **deterministically** on hardware. Understand why before
trusting any sim result.

### Verified root cause class: the Bluesim BRAM model is idealized

Sources checked (bsc install + Yosys 0.51):

- Bluesim's BRAM is a C++ behavioral model:
  `bsc/src/bluesim/bs_prim_mod_bram.h` (`MOD_BRAM::clkA/clkB`).
  - `put` is deferred to the clock edge and committed once per edge per port.
  - Schedule: `a_put C a_put`, `a_read CF a_put`. Two puts to the same port
    **can never execute in the same simulated cycle** — the compiler
    serializes them into consecutive cycles.
  - Read-during-write (same port, or cross-port same address): deterministic
    *write-first* semantics; the reader always gets clean old data
    (`upd_b_prev`).
  - Consequence: **a pending read is never lost**, and reads never return
    garbage. The model structurally cannot express the failure we hit.
- Real ECP5 DP16KD (confirmed empirically, pipe2/pipe3): a **write launched
  on a port while a read is pending on the same port destroys the pending
  read data**. Cross-port read/write to the same address in the same cycle
  is undefined per Lattice. Neither behavior exists in the Bluesim model.
- There is no faithful post-synthesis simulation path either: Yosys's
  `ecp5/cells_sim.v` `DP16KD` is an **empty stub** (no behavior at all).
  Only Lattice Diamond's proprietary simlib contains a real DP16KD model.
- BSC's Bluesim<->synthesis equivalence covers the **logic** (per-cycle
  I/O semantics are preserved by construction). Divergence enters only via
  library-primitive models (BRAM above, also FIFO/SizedFIFO corner cases)
  and undetermined values: Bluesim tracks `mkRegU` contents as explicit
  undet; silicon powers up with real-but-arbitrary per-chip state, and a
  Yosys-synthesized `mkRegU` is an uninitialized FF.
- Corollary found building the F4 guards: you CANNOT add a same-cycle
  observation channel (RWire read/write, PulseWire send) inside
  MMU_Cache's `req` — BSC then computes an Enable(imem_req) ->
  ReturnValue(imem_instr) edge and every CPU rule becomes self-dependent
  (G0033). Bluesim-level BRAM guards must be pure per-put-site literal
  checks; anything needing cross-port same-cycle visibility belongs in
  the F1 strict-Verilator model, not here.

### Incident map

- F-plan status: F4 (Bluesim-level direction checks, `BRAM_HAZARD_ASSERT`
  in MMU_Cache.bsv), F1 (Verilator strict-BRAM sim) and F2 (seeded
  X-sweep, `run_sweep.sh`) are DONE.
  F1 lives in `sim/strict_bram/` — it replaces the lib BRAM2.v with a
  strict DP16KD model (same-port lost-read warn/corrupt/error via
  +STRICT_BRAM, cross-port same-address counted with
  direction-specific severity) and replays the boot scenario against
  build/verilog_all.v + src/Top.v: `./sim/strict_bram/run.sh
  [--strict=warn|corrupt|error]`. Known-good boot: 0 lost-reads,
  0 cache cross-port, 5611 benign BTB cross-port hits (bp_train vs
  predict — self-correcting, counted non-fatal). Icarus unit test
  `tb_bram2_unit.v` proves the lost-read trap fires on the pipe2
  pattern; the design-level repro (alternating port-A read/write in the
  refill loop) fatal-errord in 4 s with "port A LOST READ", and the
  reverted design re-passed — see HANDOFF.md "F1 DONE". F2: 8 seeds,
  byte-identical output, strict census clean every seed. Side finding
  (FIXED, Track A3): the Makefile $display-strip was a GNU-sed `\|`
  recipe — a no-op in BSD sed — so verilog_all.v carried every
  verbosity $display; the recipe is now a string-aware perl slurp (21
  format strings contain `;` inside literals, so naive line deletion
  orphaned calls; `$write_`-style ids need the open-paren anchor).
  Result: 0 $display lines, lint OK. See HANDOFF.md "sed-recipe saga".
- **pipe2/pipe3** (confirmed): refill loop read a word on port A while its
  own fill writes went to port A; Bluesim serialized the two puts into
  different cycles and returned clean data; hardware lost the read -> stale
  line -> crash. Fix: CACHE_SNAPSHOT refill (snapshot the victim line's
  other-way words with relaxed reads *before* any write; never mix reads
  and writes on one port). This is the template for all future refill work.
- **fetch request queue (2026-10-09, reverted; ROOT-CAUSED 2026-10-13)**:
  Bluesim boot + REPL sims PASS; hardware crashed to PC 0 early in boot
  (trap loop, dpc=0 via DMI).  Root cause PROVEN 2026-10-13 when the
  variant was rebuilt on the step7 base and BOTH strict engines flagged
  the same event: the reqq request-launcher rule was guarded by bare
  `(! req_q_empty)`, so it fired during MODULE_RESETTING (and
  refill/snapshot/store/PTW), issuing tag-RAM port-B reads that collided
  CROSS-PORT SAME-ADDRESS with the reset/refill port-A writes (dcache
  tag RAM set 0x3a, t=0..60920 at first boot).  Cross-port same-address
  same-cycle is UNDEFINED on ECP5 DP16KD (Lattice) — the read returns
  garbage -> corrupted tag/hit test -> early-boot trap loop to pc 0.
  Invisible to stock Bluesim (idealized BRAM model cannot express
  cross-port), which is why 2026-10-09 forensics dead-ended.
  FIX (retry, landed same day): launcher guard became
  `!req_q_empty && (rg_age_seen==rg_req_seq) && (READY||RUNNING)` — launch
  only when the cache can accept a request (reset done / idle, previous
  response settled); rl_age_ram_rsp extended to also settle age in
  MODULE_READY (tlb_flush can enter READY with a stale in-flight read).
  Deadlock-free argument: during refills/PTW/ST-AMO the CPU is stalled so
  the queue is empty; launcher and probe are complementary on queue-empty
  in RUNNING; boot-time enqueues wait in the depth-4 buffer and drain
  once READY.  Retried design then passed Bluesim strict (boot+repl) and
  the F1 strict-Verilator gate — see reqq-STATUS.md / HANDOFF.md.
  FINAL OUTCOME (2026-10-13, retry CLOSED): five integration fixes made
  the queue functionally sound (boot+load+readback clean in J1
  strict=error, 0 BRAM events) but s3 P&R closed at 28.01 MHz vs the
  step7 base's 28.90 -- the queue cuts the fetch-ADDRESS cone, which is
  no longer the critical path (step5/7 shim + capture regs broke it);
  the current critical path is the SHIM's imem presentation logic
  (icache.rg_addr -> reshow_pend -> imem_instr), which the queue cannot
  help. Ship bar (>=12% margin AND real gain over 28.90) failed on gain.
  DO NOT resurrect the fetch-request queue; the 50 MHz lever must attack
  the presentation path (register the shim output earlier / cut
  reshow_pend depth / pipeline the CPU-facing imem mux) or go exec-side.
  LESSON: any future rule that issues cache-RAM port accesses outside the
  stock req/probe/rereq/refill FSM cycle MUST state-guard its port-B
  reads against port-A-writing states; "queue then launch" patterns need
  the launcher's FSM-window guard, not just a not-empty guard.
- **step8 (2026-10-13, CLOSED, reverted to step7)**: the 50 MHz campaign
  spent its two iterations on the dmem side. (1) A naive shim deposit
  register repeated the reqq mistake (bare-pend launcher fired mid-refill
  because dmem loads are SCOREBOARDED, multiple in flight -- the
  "one-outstanding, stage-2-blocking" model is wrong; the symptom was
  r0=0xaaaaaaaa, Verilator's mkRegU power-up pattern, response never
  driven). Fixed by porting the proven reqq-v6 queue into MMU_Cache:
  functionally clean (J1 byte-exact v6 golden, Bluesim strict PASS) but
  s3 = 28.01 MHz vs step7 28.90 -- no gain; clean-netlist path0 is the
  imem presentation path, byte-identical to the reqq-v6 critical path.
  (2) Store-hit cword write + fabric write-through pipelined into
  rl_ST_AMO_RSP: 27.36 MHz (cone re-formation), reverted. MEASUREMENT
  LANDMINE: the v6 queue first measured 29.10 MHz on a netlist with
  SIM_TRACE $displayb baked in (BSC resolves `ifdef at COMPILE time, so
  a verilator -D is a no-op) -- the trace perturbed Yosys/ABC and
  inflated Fmax 1.1 MHz. MEASURE THE NETLIST YOU SHIP. Useful sim-trace
  recipe preserved in step8-STATUS.md ($displayb slips the Makefile
  strip; BSC silently drops $strobe). Net: the imem presentation path
  (~35.7 ns, 78% routing) has capped three designs; dmem cuts cannot
  move Fmax past it.
- **step9 (2026-10-13, WAS the promoted base at 32.44 MHz; superseded
  2026-10-15 by rld1pp-34mhz — kept as rollback bit)**: the
  presentation-path campaign. Root-mapped the 35.7 ns wall first: it is
  the WHOLE fetch->predict->ask loop in one comb cloud (icache.rg_addr
  -> shim dw_* presentation mux -> CPU d_instr -> branch-predictor
  predict_rsp (BTB read + RAS decode + fall-through add) ->
  imem_req_addr -> ask-queue rg_q0.D; 7.9 ns logic / 27.8 ns routing;
  confirmed imem_req_addr is comb-derived from predict_rsp).
  CUT: registered the shim's CPU-facing presentation output
  (rg_out_valid/pc/instr/exc/code/tval written by the unconditional
  rl_shim_step; the dw_* DWire discipline RETAINED -- CPU rules call
  imem value-methods and imem.req in the same rule, and direct register
  reads in the interface re-trigger the G0004 method conflict). +1 cycle
  uniform presentation latency; internal launch/arrival/reshow timing
  unchanged (arrival-paced; not the failed decoupling class -- no queue
  insertion). s3 32.44 MHz (+12.3% over 28.90; margin 29.8% over 25
  MHz). J1 strict=error PASS (banner 20553, ACKs 162831, readback
  222580, hello 50198125 -- the +1/fetch latency shift, content-exact);
  Bluesim strict PASS; hw suite 70/0/2; cache test PASS. FIRST I-side
  change to pass the bench (3/3 prior failures were all ask-stream
  decoupling). New step9 J1 goldens: banner 20553, ACKs 162831,
  readback 222580, hello 50198125. Rollback bit:
  build/ulx3s_top.bit.step7-25mhz (also bits/). Next lever: new path0
  is intDiv/regfile -> stage1/2 -> dcache.EN_req/ADDRB (30.8 ns); the
  v6 dmem queue (step8b, preserved) cuts exactly that tail -- variant B
  = step8b MMU_Cache + step9 shim is a ~38 MHz candidate. VARIANT B TRIED
  2026-10-14: s3 = 31.97 MHz -- WORSE than A's 32.44 (queue cone
  re-formation eats the tail cut). CLOSED, reverted to A. F2 X-sweep
  (step9-A, pinned to the frozen netlist): all 8 seeds PASS with
  byte-identical functional output (reset-clean); the sweep's FAIL
  verdict was a judge artifact -- seed 1's log carries the obj_dir c++
  build lines, seeds 2-8 do not, and the old filt() only stripped
  '- Verilator:'. filt() hardened in run_sweep.sh; when a batch verdict
  and the per-seed logs disagree, eyeball the seeds (rule 8 epilogue).
  SECOND OCCURRENCE (Step 3 v2 fetch buffer, 2026-10-11): a CPU-side
  ask-queue buffer passed the strict-Bluesim gate with a functionally
  alive boot, then wedged DETERMINISTICALLY IN BOTH engines post-load
  (CPU spins in a ~6-instr ROM mtime-vs-UART poll loop; loader phase
  fully healthy). Root cause never isolated (FETCH_DEBUG traces +
  RX-FSM decoding; protocol verified sound analytically and unit-tb-
  clean over 161 streams). Rolled back bit-identical. CONCLUSION:
  CPU-side fetch decoupling on the STOCK near-mem interface has failed
  twice (reqq early crash, v2 late wedge) — the next attempt changes
  the interface boundary (near-mem-side queue, reqq lessons applied:
  launcher stays a pure action, ftn attributes intact on
  rl_fetch_next_32b). See HANDOFF "2026-10-11 morning — FINAL VERDICTS".
  THIRD OCCURRENCE (Step 4 shim, 2026-10-11): near-mem-side queue +
  registered bp training; BOTH engines functionally green through
  hello+tick0, strict BRAM census clean, and a TIMING-CLEAN 25.44 MHz
  bit STILL failed the hardware suite (seed-3 24.24 failed too; mean
  ~24.8 MHz, worse than the 28.93 baseline — replacement logic re-forms
  cones). Rolled back verified. The step-4 sim showed hello +2M cycles
  late (stall, not retries) — suspect: real-latency interaction class
  (UART/SDRAM windows) that instant-host sims never exercise.
  CONCLUSION: 3/3 I-side decoupling attempts sim-green/hw-red; the
  class needs BENCH forensics (DMI-dump the wedge) before any further
  attempt, and the 50 MHz lever family must change (exec-side
  pipelining or leaner shim per step4/DESIGN.md). See HANDOFF
  "2026-10-11 evening — STEP 4 VERDICT".

- **rld1pp PROMOTED (2026-10-15): new base 34.48 MHz s3.** Bench on
  the md5-verified bit (e1db0d31c2ae94a140b69205183e042f, re-packed
  from the committed tree's rld1pp-s3.config, chain: Flute b88680d ->
  verilog_all.v 73c6901e -> s3 config -> bit): hw suite 70/0/2 (the 2
  known I64 hi-half P1 warns), cache test PASS. F2 X-sweep 8/8 PASS
  byte-identical. Promotion artifacts: bits/ulx3s_top.bit.rld1pp-34mhz,
  build/timing-exp/verilog_all.v.rld1pp, logs
  build/timing-exp/bench-rld1pp.log + f2-sweep-rld1pp-waived.log.
  Rollback bit: bits/ulx3s_top.bit.step9-32mhz (supersedes step9 as
  the promoted base). Path0 on the shipped netlist: stage1 input reg
  -> GPR regfile LUT-RAM read -> data_to_stage2_addr -> dcache tag-RAM
  ADDRB -> DOB_R (29.0 ns; logic 6.1 / routing 22.4); all other paths
  <=15.6 ns. SWEEP INVOCATION LANDMINE (cost 5.3h): run_sweep.sh on a
  train-FIFO-era netlist needs J1_WAIVE_BTB_CENSUS=1 EXPORTED (the
  census bin is zero by construction; without it all 8 seeds fail the
  hazard-bin gate AFTER ~22 min of sim each, with functional PASS in
  every log), and SWEEP_OUT is resolved AFTER the cd to sim/strict_bram
  — pass an absolute path. Eyeball seed logs before believing a batch
  FAIL (rule 8).
- **RLD-3 (2026-10-15/16, CLOSED — REVERTED, no shippable gain)**: deferred
  dmem request launch (stage2-internal `FIFOF#(DReq_Sample)`;
  `dcache.req` issued one cycle after stage2 enqueue, from registered
  state — intended to cut the 29 ns stage1-output/regfile -> dcache
  tag-RAM cone; raw variant measured s3 36.69 and the cut WORKED as
  designed, wall migrated to the fetch-predict/BTB cone). Three J1
  failures, three root causes, all variants rejected:
  (1) rld3: `Taaaaaaaa` — memory-store fabric writes vanished. ROOT
  CAUSE: `rl_ST_AMO_response` (MMU_Cache) drives dw_valid but never
  exits CACHE_ST_AMO_RSP; stock relies on the NEXT REQ (fired at
  stage2-enqueue time, the very next cycle) clobbering the state, so
  the store response is exactly 1 cycle. The deferred launch opens a
  2nd valid cycle: the store still in stage2 falsely completes, the
  pipeline advances, and the next op's req clobbers the store's
  in-flight probe (2nd tag-RAM read overwrites its address before the
  probe runs) -> write never posted -> refill reads unwritten SDRAM.
  FIX (landed, then reverted with the rest): `rg_state <= MODULE_READY`
  in rl_ST_AMO_response (netlist write-mux verified: EN_req wins the
  coincident write, response still 1 cycle).
  (2) rld3b (+ST_AMO fix): memory test PASSES (`T12345678`) but boot
  wedges at the 10th putc — TX stops after r0's hex; loader never
  starts. `rl_maintain_io_read_rsp` (IO_READ_RSP) and
  `rl_drive_exception_rsp` (MODULE_EXCEPTION_RSP) have the SAME linger
  contract (comments say so verbatim: "stays until the CPU's next
  request puts it back into RUNNING"). Same false-completion cascade.
  (3) rld3c (single-cycle exits in all three states): Bluesim boots
  CLEAN through the exact wedge point (FSM verbosity-2 trace: r0/r1
  loads complete, all 9 putc ops flow) — the remaining J1 wedge is
  VERILATOR-SPECIFIC: two different netlists wedge at the identical
  byte (not X-luck, unresolved; a seed sweep was not run — see
  lessons). s3 = 35.26 MHz (CORRECTED 2026-10-16: an earlier reading
  of 27.18 was a mid-run placement-stage line, not the post-route
  fmax; the final report/config confirm 35.26 — the three state-exit
  fixes cost ~1.4 MHz total across iterations, no collapse).
  REVERTED to b88680d (rld1pp base; netlist re-emit diff vs the rld1pp
  snapshot is documented BSC naming/factoring churn only — git state
  is the identity guarantee, and the date define moves daily).
  LESSONS: (a) stock near-mem FSM has THREE states holding dw_valid
  until the next req's clobber — "request arrives the cycle after
  stage2 enqueue" is an IMPLICIT FSM CONTRACT; any request-timing
  change must fix all three or fail exactly like above. (b)
  Bluesim-vs-Verilator divergence is diagnosable: CPU-side probes
  (enq/launch pairs) were correct in both engines; Bluesim FSM trace
  clean at the wedge point => sim-specific; record and revert rather
  than burn gate-hours. (c) FSM-state micro-fixes can cost 8 MHz of
  placement — s3 every increment. (d) The dmem request-launch family
  is CLOSED (4th occurrence overall: v6-dreq, RLD-2, RLD-3 x3): the
  single-cycle-response contract is too fragile for request-timing
  moves without a protocol redesign (explicit response-consumed
  handshake). Next 50 MHz lever: the fetch-predict/BTB cone
  (rld3 forensics: speculative BTB read address comb-derived from the
  ask stream — `predict_req_pc` mux, 27 ns routing-dominated) or the
  stage1-output/bypass cone (28 ns, rld1pp-era) — both documented in
  HANDOFF 2026-10-15.
- **E12 (2026-10-19, PROMOTED — new base 44.18 MHz s3, seeds 44.2-45.8): E11
  decode-free return prediction + E12 dcache AMO split, on E8d + the mepc fix.**
  E11: the ISA_C timing cost was the branch predictor decoding the realigned
  16/32-bit instruction in the fetch cycle to spot returns.  Returns are now
  classified when JALR resolves (CF_Info.is_ret: rs1 in {x1,x5} and not
  rd==rs1 link) and stored as a BTB bit; a flagged BTB hit predicts from the RAS
  top.  Fetch census 22.9 -> 18.0 levels (= ISA_C off) with ISA_C kept.
  mepc fix (found by riscv-formal c.beqz): mepc reads with bit 0 cleared and
  MRET masks bit 0, so an unwritten (unreset) mepc can no longer send MRET to an
  odd PC.  E12: the AMO ALU ran in the dcache probe cycle (tag compare -> AMO
  add/compare chains -> cword merge -> BRAM DIA, 24.5 levels, deepest in the
  SoC).  An AMO hit now captures cword_set/way/word64 and goes to
  CACHE_AMO_EXEC (rl_amo_exec: AMO op, cache write, write-through), then
  CACHE_ST_AMO_RSP as before; +1 cycle per AMO.  Census max 24.5 -> 18.9; the
  critical path left the core (soc_info slave rd_addr -> rd_data).  Seeds
  45.72/45.83/44.18/44.52 MHz (clean E8e baseline 34.3-34.9).  Gates: formal
  smoke 10/10 (E11: 16/16 incl. the jump and C-branch checks); J1 strict PASS
  hello 52,198,124; cache test sim T..D + hw PASS x2; NEW AMO test
  (test/amo_test.S, rule 15) sim + hw PASS; bench 70/0/2; F2 8/8.  Custody:
  bit md5 caaa8e8c25acb7ff2c0674ec477e8996 = ecppack of e12-s3.config (seed 3,
  verilog_all.v.e12 md5 95694054a65b0c124451c2177b1de1e2);
  bits/ulx3s_top.bit.e12-44mhz.  Rollback: bits/ulx3s_top.bit.e8d-37mhz.
  Flute commit 75815cd.
  Records: build/timing-exp/50mhz-SURVEY.md (E10, E11, E12), ../HANDOFF.md
  2026-10-19.
- **E8d (2026-10-17, PROMOTED — new base 37.20 MHz s3): abandoned-refill fix +
  C HINT decode fixes on top of RLD-4 + E1..E5.**  RLD-4 shipped with a hazard:
  MMU_Cache.req has no flow control, so a request issued while a refill's AXI
  burst was in flight (wrong-path miss, then a redirect) left the burst queued
  and every later fill consumed the wrong data (E5 cache-test wedge; survey
  "ROOT CAUSE", VCD-proven).  Fix in three iterations, each caught by the
  cache test in sim and on hardware: E8 busy gate (mv_busy ConfigReg mirror) on
  both launch sites; E8b busy excludes the hold-the-response states
  CACHE_ST_AMO_RSP/IO_READ_RSP (else deadlock after the first store); E8c the
  icache shim HOLDS an uncovered head while busy instead of popping it (else the
  ask is lost; proven with the TB_STALL_WATCH snapshot).  E8d adds the C HINT
  decode fixes riscv-formal found (rd=x0; C.ADDI nzimm=0; C shifts shamt=0).
  The E1..E5 pipeline rework underneath gained no timing (35.1-36.3 band) and is
  kept because E8 was built and verified on it; IPC = RLD-4.  Gates: J1 strict
  PASS content-exact (hello 52,198,127 vs rld4 52,198,124); cache test T..D in
  sim, PASS on hardware x2; bench 70/0/2 (same two I64 warns); F2 8/8; formal
  smoke 10/10 + c.slli/srli/srai; s3 37.20 MHz.  Promotion custody: bit md5
  89c95c82b6d86cb965f29c2ebbba996a = ecppack of e8d-s3.config (seed 3, from
  verilog_all.v.e8d md5 efa849428a6a99447a1c5dc0f79dd1cc); bits/ulx3s_top.bit.e8d-37mhz.
  Rollback bit: bits/ulx3s_top.bit.rld4-36mhz (md5 93a431d9...).  Still open on
  E8d: the deep formal checks (reg, pc_fwd; build/formal/run-deep-e8d.log).
  Flute commit d1385bf.  Records: build/timing-exp/50mhz-SURVEY.md rows e4..e8d,
  ../HANDOFF.md 2026-10-17.
- **RLD-4 (2026-10-16, PROMOTED — new base 35.94 MHz s3): deferred dmem
  req launch + response-echo kill.**  The documented handshake unlock,
  implemented G0033-SAFE AS A REGISTER: `rg_kill_echo` in MMU_Cache, set
  by `ma_kill_echo` (CPU_Stage2.fa_enq on EVERY Stage2 enqueue), cleared
  by the next `req`.  While set (exactly the one cycle between an op
  entering Stage2 and its deferred request launch) the four dw_valid
  drivers are silenced (probe guard += !rg_kill_echo; the three linger
  states gate their drives) and the linger states exit to MODULE_READY.
  First attempt used a PulseWire rsp_consumed; BSC rejected it with the
  exact G0033 from the F4 lesson (Enable(dmem_rsp_consumed) ->
  ReturnValue(dmem_valid), via stage2.enq losing always_ready).  LESSON:
  same-cycle observation channels into MMU_Cache are the G0033 class even
  OUTSIDE req; a method-written REGISTER read by rule guards is the safe
  form.  Deferred launch (RLD-3 pattern + orphan guard on rg_stage2
  holding a dmem op; dead tokens deq'd without launching).  Root analysis
  BEFORE coding: stock safety = "next req fires at Stage2-enqueue time";
  deferral breaks it via TWO echo classes RLD-3 never fixed (MODULE_RUNNING
  probe re-drive every cycle until next req; orphan echoes from killed
  ops) — both plausibly the rld3b/c putc#10 Verilator wedge.  Gates:
  compile 0 err (no G0021/G0033); netlist verified (EN_req first in
  rg_state mux — method wins linger exits; probe guard !rg_kill_echo);
  J1 strict=error PASS content-exact (census clean, btb bin waived);
  s3 35.94 MHz — the rld1pp-era 29.0 ns dcache cone is CUT, wall migrated
  to the fetch-predict/enable cone (rg_pc -> fall-through add ->
  predict_rsp -> rl_pipe enable cloud incl. perf taps + RLD FIFO fulls ->
  csr rg_dpc, 27.82 ns); bench 70/0/2; cache test PASS; F2 8/8 (record
  result in HANDOFF).  Promotion custody: bit md5
  93a431d936c9d14f6c5a138d2af42fd3 = fresh ecppack from rld4-s3.config
  (seed 3, from verilog_all.v.rld4 md5 281fd2090a760c9342ea3d17521ea8a6).
  Rollback bit: bits/ulx3s_top.bit.rld1pp-34mhz (supersedes rld1pp as
  promoted base).  Next 50 MHz lever: the 27.82 ns fetch-predict cone —
  mapped in rld3-s3-report.json and rld4-s3-report.json path0; its mid-cone
  runs through rl_pipe's ENABLE cloud (rg_step_count perf taps,
  f_dreq_pending/f_bp_train full_regs), so the next cut likely slims the
  enable cloud (endpoint cuts on the perf taps / FIFO full fan-in) before
  or alongside registering the BTB read address.  Full design record:
  build/timing-exp/rld4-PLAN.md.
- **RLD campaign (2026-10-14/15, CLOSED — +4.2 MHz, short of 50 MHz)**:
  the scoped rl_pipe decomposition follow-up. (1) 3-rule rl_pipe split
  (moves in rl_pipe_feed + rl_pipe_commit with pulse-commit): CLOSED —
  BSC made the new rules mutually exclusive with the every-cycle
  rl_pipe (`WILL_FIRE = CAN_FIRE && !WILL_FIRE_rl_pipe`), starved
  silently; the tell is warning G0021 "rule can never fire" — GREP
  ELABORATION WARNINGS, not errors. Fixed one real bug en route
  (commit must HOLD fulls on blocked cycles, not just fire/no-fire —
  stage3 evaporation), still starved. (2) WINNER pattern: MODULE-
  INTERNAL cuts only. RLD-1' train FIFO in CPU_StageF (bp_train enqs,
  local drain) s3 30.25->33.25; RLD-1'' perf-tap bridge (minstret-delta
  for retire, tick reg for redirect; a PulseWire read carries the
  sender's WILL_FIRE cone) s3 ->34.48. J1 strict PASS BYTE-EXACT both.
  Train-FIFO zeroes the stock btb_cross_ba census by construction —
  waive with J1_WAIVE_BTB_CENSUS=1 (loud, in run.sh). (3) RLD-2
  deferred dcache req: s3 35.44 but J1 FAIL — the ROM's tight volatile
  store->load sequence races the shifted write-through (SECOND
  v6-dreq load-toxic occurrence; first was step10a). dreq-side timing
  cuts are CLOSED unless same-core store ordering is preserved
  (write-drain-on-miss). (4) Bluesim Repl_Boot_Tb functional verdict
  REVOKED — pure stock also gets repl_responded=0 (prompt-detector
  artifact of the bit-rate-mismatched decoder). J1/hw suite are the
  only functional gates; DUT-internal Bluesim probes remain valid.
  New binding cone: stage1 output fn/bypass -> GPR regfile (28.2 ns).
  Committed: Flute b88680d, wrapper 6b2de18. Details:
  build/timing-exp/rld-PLAN.md.
- **step10-13 50 MHz campaign (2026-10-14, CLOSED — verdict recorded)**:
  attempted the architectural push from the step9 base (32.99 s3) to
  50 MHz.  Ladder: +v6-dreq queue +perf-tap regs (33.89); +elastic
  CPU_Stage1 (34.91, J1 DEADLOCK — reverted); +registered bp-training
  on the step10a base (34.88, J1 FAIL at the load phase); step9+perf+
  bpFIFO without the v6 queue (32.03, below baseline).  Tree reverted
  to shipped step9 (Flute 4f90b8b).  LESSONS: (1) the v6-dreq queue on
  the step9 base STALLS THE ROM LOADER in J1 (banner byte-exact, then
  loader silence; a >2h J1 run on this family = this stall, not
  slowness) — the v6 queue stays closed on the step9 generation.
  (2) Elastic-stage designs must clear SYNCHRONOUSLY with the
  protocol that drains the upstream stage; a delayed clear wiped live
  entries (step11 passed Bluesim on timing luck, deadlocked
  Verilator).  (3) The live branch predictor is Branch_Predictor.bsv
  (mkBranch_Predictor at ~line 193); Branch_Predictor_NORMAL/NULL are
  ORPHANS — an edit to them produced a byte-identical timing report
  (caught by grepping the netlist; always verify a timing-relevant
  edit landed via grep on build/verilog_all.v).  (4) The ~28-30 ns
  rl_pipe mega-cone (stage1/stageF comb read combinationally by
  rl_pipe's feed/train/redirect/dcache-req blocks) is a structural
  family: endpoint cuts move the wall between siblings for ~1 MHz
  each and asymptote ~35-38 MHz.  50 MHz needs wholesale rl_pipe
  decomposition (decoupled sequencers) as a scoped separate project.
  Full analysis: build/timing-exp/step12-STATUS.md.

### Working rules (hard-won, do not relearn)

0. DESIGN POLICY (user-set, standing): timing closure and performance
   come from ARCHITECTURE — pipeline stages, fetch/data decoupling, cache
   organization — never from floorplanning/placement tricks, and never
   from weasel-clock PLL choices.  PLL use is legitimate only to multiply
   the 25 MHz board oscillator up to the architectural target (50 MHz).
   Floorplan constraints and nextpnr seed sweeps are for final margin
   recovery on an architecturally-closed design, not a closure strategy.
   Consequence: Step 3 = fetch-side decoupling, gated on the reqq
   root-cause (Track B).
1. Any change that alters **BRAM port scheduling** — new readers/writers,
   moved `put`s, `rl_*_ram_*` rules, rule-attribute changes on
   imem/dmem-adjacent rules — is suspect until the **hardware gate** passes
   (sims + bitstream + `scripts/hw_test_suite.py`). Treat "sims pass" as
   "not obviously broken".  Sim builds define `BRAM_HAZARD_ASSERT`, which
   arms pure direction checks at every cache-RAM put site in MMU_Cache.bsv
   (port A write-only / port B read-only; the pipe2/pipe3 killer class).
   If one fires, the edit broke BRAM discipline — fix it before any
   hardware run.  NB: an assert prints + `$finish`es but Bluesim still
   exits 0 — the gate is `grep -c "ASSERT FAIL" <log>` == 0, never make's
   exit code alone.  Cross-port same-cycle access is FSM-unreachable today
   and is deliberately NOT Bluesim-checked (any observation channel out
   of `req` trips BSC G0033); that corner is F1's strict-Verilator job.
2. Keep BRAM discipline: port A = write-only, port B = read-only; never
   read and write the same port in overlapping cycles; make no cross-port
   same-address assumptions.
3. Extended cache test (`test/cache_test.S`, run with
   `test/run_cache_test.py`) is the fastest I/D-cache gate; the suite is the
   full gate. A nested-far-call I-cache hang repro is kept at
   `test/cache_test_dbg.S` (see HANDOFF.md).
4. When a build crash-loops early, the UART drowns in trap-handler spam and
   the normal DMI client desyncs. Use `scripts/dmi_rescue.py` (resyncing
   MAGIC, garbage-tolerant parser) then `scripts/dmi_dump.py` to halt the
   hart and read state. DMI register reads work even when the CPU is wedged;
   abstract GPR/CSR reads may be unsupported (cmderr 2) depending on hart
   state.
5. Sim pass criteria are weak (run-to-completion, no golden compare).
   If raising the bar: add REPL-output golden compare and cache-protocol
   assertions — but remember rule 1: that still cannot catch BRAM-model
   gaps. REMEDY LANDED (J1, DONE 2026-10-11): sim/strict_bram/run.sh is
   the canonical functional gate — golden milestone cycles, scoreboard
   golden-compare, coverage bins, negative-gate capable. Any
   fetch/cache/BRAM-scheduling change must pass it (plus run_sweep.sh)
   BEFORE hardware, with per-netlist builds via
   `BUILD_DIR=<dir> VERILOG_ALL=<netlist> ./run.sh [--strict=...]`
   (never share one obj_dir across different inputs; J1_STATUS.md is
   the coordination poll point).
   TB DECODE CAVEAT (2026-10-13, reqq retry): the Bluesim boot tb's TX
   decoder is BIT-RATE MISMATCHED to the DUT — test/SoC_Boot_Tb.bsv
   samples at cycles_per_bit=20 (12.5 MHz-era 625 k setting) while the
   DUT UART model src/Uart_Pins.bsv clocks TX at clk_per_bit=217
   (25 MHz/115200). Its "TX: %c" chars are garbage for ANY design,
   healthy or not — never judge boot output by them. J1's C++ tb is the
   TX-functional gate of record (decoded step7's banner at cycle 20542).
6. The Bluesim boot tb (`test/SoC_Boot_Tb.bsv`) spoke a STALE loader
   protocol (raw header+payload streaming) until Track D0 (2026-10-10)
   rewrote it to the CHUNKED protocol the ROM actually speaks (seq +
   <=256B + xor + 0x55, ACK 0x06 / NAK 0x15, ACK-paced — see
   `scripts/hw_test_suite.py: load_blob` and `boot/boot_loader.c`).
   `scripts/loader.py` was fixed the same way; `scripts/bin2hello_bsvi.py`
   regenerates `test/fn_hello_bytes.bsvi` (bytes + fn_hello_len) from
   sw/hello.bin via a Makefile dependency, so the tb header can never
   desync from the image again. Pre-D0 sim-boot "passes" exercised no
   loader at all; if you ever resurrect an old tb, check this first.
7. MARGIN RULE (Step 5, 2026-10-11): nextpnr "PASS at <constraint>"
   with <5% margin is NOT hardware margin — spec double-digit margin
   before any bench (step4: 1.8% best -> corrupted-fetch-word trap to
   pc 0 on silicon; step5 lean shim at +20.6% -> suite 70/0/2). The
   post-route fmax line is authoritative; post-placement estimates
   (the ~21-23 MHz "FAIL" lines in nextpnr logs) are not. Two fresh
   BSC/Bluesim traps from the shim work: (a) Bluesim regs have
   immediate cross-rule write visibility — BSC preserves semantics by
   INHIBITING same-tick reader rules, so a registered presentation
   read by the same rule that writes it silently defers +1 per fetch
   (drive CPU-visible state from DWires, stock dw_valid discipline;
   synthesis-identical comb logic). (b) A 0-cycle inline launch
   inside a req METHOD is unschedulable (G0010) — launches belong in
   rules; moving one costs idle first fetches +1 cycle, cycle-locked.
8. RESET-CLEANLINESS + POWER-UP FACTS (Step 5 X-init saga,
   2026-10-12): ECP5 FFs without explicit init power up GLOBAL-ZERO
   via GSR — not per-bit random. Verilator's --x-initial=unique (the
   F2 sweep) is therefore a STRICTER bar than this FPGA's real
   power-up: a sweep-RED design can still be silicon-safe (the step5
   shim benched 70/0/2 twice on the all-zero draw), but treat F2-sweep
   green as the project's reset-cleanliness standard and CLASSIFY
   sweep-red designs before discarding. Unbounded speculation chains
   amplify X-fragility (spec-off passed a seed that spec-on wedged);
   prefer consume-paced run-ahead with a hard bound. And: preserve
   as-built experimental sources IMMEDIATELY after validation — the
   step5 v1 shim source was lost to in-place edits and only its
   bitstream survived (snapshot post-edit too, not only pre-edit).
   2026-10-12 EPILOGUE: the step5d (spec-off) shim was EXONERATED —
   the "8/8 wedged" verdicts were three stacked watcher artifacts
   (growth-kill orphaning; stdout block-buffering; and a judge grep
   for "RESULT: PASS" when the harness prints "F1 STRICT-SIM: PASS").
   With the sound watcher + fixed grep: F2 8/8 byte-identical PASS,
   full ladder green, bench 70/0/2 + cache test PASS. 5d is the
   promoted 25 MHz base (build/timing-exp/ulx3s_top.bit.step5d-25mhz,
   +13.6% margin @ s3; rollback = build/timing-exp/revert-s3.bit).
   LESSON: sweep/runner judges must match the harness's actual PASS
   string; eyeball a failing seed's log tail before believing any
   batch verdict.

9. BSC `-u` REBUILD KEYS ON SOURCE TIMESTAMPS, NOT ON `-D` DEFINES
   (2026-10-16): changing DEFINES in the Makefile without `rm -rf
   build/bsc` silently reuses .bo files compiled with the old defines
   (an ISA_A removal "compiled clean" in 1 minute and left all 109
   amo_funct7 references in the netlist).  Verify a define change by
   grepping the netlist, and start define experiments from a clean bsc
   dir.  Same class as the patched-Bluesim-header rule above.
   ALSO (2026-10-17): `make compile` keys on SOURCE timestamps too -- the
   $(VERILOG) target (build/verilog/mkULX3S_Top.v) is only remade when a
   .bsv is newer, so a Makefile-only change prints "Nothing to be done"
   even after `rm -rf build/bsc` (E6 first attempt produced the E5
   netlist byte-for-byte).  For a define change do
   `rm -rf build/bsc build/verilog/mkULX3S_Top.v` (or touch
   src/ULX3S_Top.bsv), then check the netlist md5 actually changed.
10. Timing structure without P&R: `scripts/depth_census.py <yosys json>`
   (seconds) prints a LUT-depth histogram, a per-module deep-endpoint
   table, and `--trace PATTERN` the deepest path into an endpoint.  Use
   it to confirm a cone class is GONE (not moved) before spending 45 min
   on nextpnr; single-seed s3 noise is ~±2 MHz between BSC re-emits.
   New bridge registers read by rule guards must be mkConfigReg or they
   join the G0021 class (E1 lesson, rl_stage1_xRET starved).  Campaign
   record: build/timing-exp/50mhz-SURVEY.md.

11. J1 "PASS" is content-exact only; it does NOT check IPC.  Always compare the
    milestone cycle counts ("hello banner at cycle N") against the previous
    netlist's J1 log: the loader's repair window is a fixed 2M-iteration poll
    loop, so N is a direct IPC gate (rld4: 52,198,124).  E4 (2026-10-16) passed
    J1 with N = 80,199,614 because a one-shot stage2 cf_info was consumed only
    when the fetch-feed block happened to run; the BTB never learned a loop
    jump.  For redirect counts without a re-run:
    `verilator_coverage --annotate DIR --annotate-all --annotate-min 0 obj_dir_X/coverage.dat`
    and read the toggle count on `reg rg_perf_redirect_tick;` (2 toggles per
    redirect).  The .dat records the netlist path used at run time; sed the
    path if that file has since been overwritten.
    Also: bash reads a script incrementally, so NEVER edit run.sh /
    run_sweep.sh while a run is in flight -- the E6/E7 J1 runs (2026-10-17)
    passed the sim but died in run.sh's post-processing with a syntax error
    because run.sh was edited mid-run (hazard bins were then re-read by hand
    from obj_dir_X/coverage.dat).  Long Verilator builds launched from a
    foreground tool call can be SIGTERMed when the call returns; launch them
    as tracked background tasks.
    CACHE-TEST IN SIM (the gate for this bug class, ~70 min):
    `cd sim/strict_bram && TB_TX_TRACE=1 TB_HELLO_DEADLINE=70000000 BUILD_DIR=obj_dir_X
     VERILOG_ALL=.../verilog_all.v.X ./run.sh --strict=warn .../test/cache_test.bin`
    and expect `[tb] tx 0x44` ('D') after `tx 0x54` ('T'); `tx 0x4d` ('M') or no
    'D' = fail (the scoreboard's hello FAIL is expected for this image).
    TB_TRACE=<file.vcd> TB_TRACE_FROM/TO=<cycle> with VERILATOR_TRACE=1 on EVERY
    run of that BUILD_DIR dumps a window; build/timing-exp/vcd_probe.py reads it.
12. ABANDONED-REFILL HAZARD (2026-10-17, E5 cache-test wedge; survey "ROOT
    CAUSE"): MMU_Cache.req has no flow control; a req while a refill's AXI
    burst is in flight leaves that burst queued and the NEXT refill consumes it
    (every fill one response behind).  The RLD-4 icache shim did this after a
    flush (rg_inflight_valid cleared) and Stage2's rl_launch_dmem_req could too.
    Fix (E8): MMU_Cache.mv_busy (ConfigReg mirror) gates both launch sites.
    busy = not in {READY, RUNNING, EXCEPTION_RSP, CACHE_ST_AMO_RSP, IO_READ_RSP}:
    the last two are hold-the-response states that only leave on the next req,
    so counting them as busy deadlocks after the first store (E8a: T then hang).
    The shim must HOLD an uncovered head while the inner is busy (E8c); popping it
    (the pre-E8c "every head pops" rule) loses the ask and fetch hangs (E8b).
    E8c (2026-10-17 13:52) = first E-series netlist to pass the hardware cache test
    (J1 PASS, hello 52,198,127, 37.20 MHz s3); snapshots: MMU_Cache.bsv.e8a (bad busy
    set), Near_Mem_Caches.bsv.e8b (popping shim).  E8d PROMOTED 2026-10-17 (user's call).
    Locating a sim hang: TB_STALL_WATCH=<cycles> (needs a VERILATOR_TRACE=1 build dir;
    no TB_TRACE needed) fails with a cpu/dcache/icache/shim register snapshot when
    minstret stops advancing after the loader jump, and prints a progress line every
    2M cycles.  The cache test's T comes ~52M cycles after the jump, so
    TB_HELLO_DEADLINE must be > 52M for any cache-test sim.
    Reliable BTB training (E5) is what made the wrong-path-miss-then-redirect
    sequence common; E1-E4 passed by luck, not by design.
    Branch_Predictor.bsv is the package CPU_StageF compiles; Branch_Predictor_NORMAL.bsv
    and _NULL.bsv are unused copies (the first E7 edited _NORMAL and measured nothing).
    SOC_BUILD_DATE changes the netlist md5 across days, so an md5 change alone does not
    prove an edit landed -- grep the generated module for the feature.
    Conversely an md5 change does not prove the LOGIC changed: an incremental `bsc -u`
    build and a clean build of the same sources differ in MUX/CSE wire naming (seen
    2026-10-17: E8d incremental vs clean, 6 modules differ, all proven equivalent).
    Use build/timing-exp/equiv_modules.sh A.v B.v (yosys equiv per module).

13. RISCV-FORMAL GATE (2026-10-17): `bash formal/run.sh` (~4 min, 10 checks: insn
    add/addi/lw/sw/beq/jal/c.addi/c.j, causal, unique at the depths baked into
    run.sh) MUST pass before any P&R or J1 run of a CPU change.  It checks the
    real mkCPU (1KB caches, 16-entry BTB, all-memory SoC_Map, RVFI record at every
    retirement site, see formal/README.md).  `formal/run.sh deep` = reg + pc_fwd
    (hours).  Found so far: C.ADDI/LI/LUI/SLLI/MV/ADD rd=x0 HINTs, C.ADDI nzimm=0
    and C.SLLI/SRLI/SRAI shamt=0 HINTs all trapped as illegal (fixed in
    CPU_Decode_C.bsv; snapshots .pre-hint / .e8c).  Counterexamples:
    ~/src/riscv-formal/cores/flute/checks/<check>/engine_0/trace.vcd; read them with
    build/timing-exp/vcd_probe.py (rvfi_* vs spec_* under checker_inst, mcause/mtval
    under wrapper.uut.csr_regfile).  A trap record must carry rs1/rs2 values: the
    checker derives expected traps (misaligned address) from rvfi_rs1_rdata.

14. CLOCK BUILDS (2026-10-18): `make SYS_PLL=1` = 32.142857 MHz system clock from an
    EHXPLLL in src/Top.v (needs a clean bsc build); sim it with UART_CPB=51 run.sh;
    bench it with EXPECT_HZ=32142857.  e4-bench.sh now refuses a bitstream whose last
    post-route fmax is < 10% over its clock (rule 7; BENCH_FORCE_LOW_MARGIN=1 overrides).
    E8d at 32.14 MHz: seeds 35.2-38.7 MHz, seed 1 passed bench + cache test on
    hardware; not promoted (rule 0 + seed pick = user decision).  ISA_C off (E9):
    40.5-41.1 MHz at 25, 44.2-46.2 at the 32.14 constraint (survey, 2026-10-17/18).

15. AMO GATE (2026-10-19): riscv-formal has no RV32A checks (commented out
    upstream), so any change to the LR/SC/AMO path (MMU_Cache probe, rl_amo_exec,
    Stage2 AMO launch) must pass test/amo_test.S in sim
    (`run.sh --strict=warn $PWD/test/amo_test.bin`, expect tx 0x54 then 0x44, no
    0x4d) and on hardware (`python3 test/run_cache_test.py <bit> test/amo_test.bin`,
    raw "TD").  Boot-loader images must have a word-multiple length (pad the .bin)
    or the loader falls back to its byte path and the sim scoreboard aborts on
    '.'.  For test images the scoreboard's final "hello banner missing from
    postload" FAIL is expected; judge by the T/M/D bytes.

## Repository map

- `Flute/` — Bluespec Flute RISC-V core (git repo; ALL our work is
  uncommitted on 9b2b056 — before any risky edit, snapshot the files you
  will touch, e.g. `cp x build/timing-exp/x.mine`).
- `src/` (top level) — ULX3S integration: Top.v (25 MHz native clock),
  ULX3S_Top.bsv, Sdram_Controller.bsv, Uart_Pins.bsv, Uart_DMI_Bridge.bsv,
  SoC_Info.bsv (perf counters), JtagTap.bsv.
- `scripts/hw_test_suite.py` — the 70-check hardware gate (programs the
  FPGA itself, hardcodes `build/ulx3s_top.bit`, port
  `/dev/cu.usbserial-120001`).
- `test/` — SoC_Boot_Tb / Repl_Boot_Tb (Bluesim testbenches),
  `cache_test.S`, `run_cache_test.py`.
- `build/timing-exp/` — experiment logs/reports; `reqq-*.bsv.queue` =
  preserved fetch-queue implementation; `ulx3s_top.bit.perf2.bak` = valid
  known-good perf2 bitstream.
- `../HANDOFF.md` — the full project log (read the 2026-10-09 sections).

## Build/test quick reference

- BSV compile check: `make compile`
- Bluesim gates: `make sim-boot`, `make sim-repl` (GB-sized logs in
  build/timing-exp/ are normal; "TIMEOUT after 70000001 cycles" is the
  normal end of the boot tb, NOT a failure — make's exit code is the gate)
- Strict-BRAM Verilator gate: `./sim/strict_bram/run.sh` (boot +
  UART-load + hello against the synth-bound RTL; PASS line + exit 0;
  J1 SV agents/scoreboard/coverage under sv_tb_top, golden-transcript
  scoreboard + hazard-bin gate; coverage in obj_dir/coverage.dat).
  F2 X-sweep: `./sim/strict_bram/run_sweep.sh [N]` (N seeded runs, all
  PASS + byte-identical output; logs in build/timing-exp/f2-sweep/).
  ACCEPTANCE RUNS (when the live build/verilog_all.v carries Step-3 or
  other experimental work): prefix VERILOG_ALL=build/timing-exp/
  verilog_all.v.pre-step3 (frozen baseline) to run.sh/run_sweep.sh —
  the default stays the live netlist so Step-3's own gates keep working.
  J1/J2 status: sim/strict_bram/J1_STATUS.md. Per-netlist parallel
  builds: `BUILD_DIR=obj_dir_<name> ./run.sh` — never share one obj_dir
  across different netlists/inputs.
- Strict-Bluesim gate: `BSV_BRAM_STRICT=error make sim-gate` (patched
  bsc C++ BRAM model: ~/src/bsc branch ulx3s-strict-bram, commit
  4b7264f6; scripts/apply_bluesim_bram_patch.sh applies/restores).
  CAVEAT: bsc -u does not track the patched Bluesim header — after
  applying or restoring the patch, `rm -rf build/bsc-sim-boot
  build/bsc-sim-repl build/sim-boot build/sim-repl build/soc_boot_tb
  build/repl_boot_tb` before gating, or stale objects silently defeat
  strict mode. Same rebuild rule after ANY change to the installed
  bs_prim_mod_bram.h.
- UVM-capable Verilator: `~/src/verilator-uvm` (side-by-side v5.052;
  vendored UVM 2020-3.2 verified working — factory/phases/config_db/
  objections/sequences; compile recipe in sim/uvm_spike/uvm_full/RESULT.md).
  The Homebrew verilator stays the strict-BRAM gate binary; the J1
  harness is uvm_pkg-independent by design (option B).
- Synthesis: `make build/ulx3s_top.json` (~2 min)
- P&R: nextpnr seed sweep, then `ecppack` (see build/timing-exp/run-*.sh
  for canned commands; Makefile ships `SEED ?= 3`)
- Hardware gate: `python3 scripts/hw_test_suite.py`
- Kill the user's picocom/screen before any suite run:
  `pkill -f "picocom.*usbserial"; pkill -f "screen.*usbserial"`
