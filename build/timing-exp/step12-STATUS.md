# STEP 10-12 — 50 MHz campaign status (2026-10-14)

Goal: architectural push from the step9 base (32.4-33.0 MHz) to 50 MHz
(ship bar: s3 >= 56 MHz, i.e. >=12% margin, plus the full gate stack and
bench).  Policy: pipeline stages only, no floorplan/PLL games.

## Results ladder (all s3, same script/seed)

| State | Fmax | path0 | Verdict |
|---|---|---|---|
| step9 base (variant A) | 32.99 | 30.31 stage1->regfile/adder->dcache RAM | baseline |
| step10a (+v6-dreq queue, +perf-tap regs) | 33.89 | 29.51 stage1->ask-queue deposit | checkpoint |
| step11 (+elastic CPU_Stage1) | 34.91 | 28.65 epoch->bp_train FSM write | **CLOSED: J1 deadlock** |
| step12 on step10a (+registered bp-training) | 34.88 | 28.67 dcache rg_addr->v_req_q (relaunch) | gates running |

## Step 11 closure (the campaign's expensive lesson)

Elastic stage1 (2+2 FIFOs + capture rule) compiled after three BSC
fights (FIFOF `first` implicit condition vs no_implicit_conditions
readers -> hand-rolled output regs; PulseWire clear closed a scheduling
cycle with debug GPR writes -> toggle-register handshake; single-writer
discipline via next-state locals).  Bluesim strict PASSED; **J1 strict
FAILED: no banner, phase=0, acks=0** (hard CPU deadlock in Verilator).
Root cause by analysis: the toggle-clear takes effect one cycle late,
and in the window it can wipe already-enqueued live entries whose
stageD slots were consumed - instruction loss -> hang.  Bluesim passed
only because its timing landed the clear before the first enqueue.
REVERTED (CPU_Stage1.bsv + CPU.bsv back to 7e0af01).  Kept in git at
e63e155 with the analysis.  LESSON: any future elastic-stage design
must clear SYNCHRONOUSLY with the protocol that drains the upstream
stage (rl_pipe's set_full shadow did this in stock; the FIFO version
must gate BOTH the push AND the upstream's consume on the same cycle's
clear visibility).

## Step 12

Registered bp-training: the build's predictor is Branch_Predictor.bsv
(mkBranch_Predictor at line ~193; Branch_Predictor_NORMAL/NULL are
orphans - the first attempt edited the orphan and produced a
byte-identical report, caught by grepping the netlist).  bp_train now
enqueues into a 2-deep BP_Train FIFO; rl_bp_train applies it a cycle
later (provably exclusive with rl_reset on rg_resetting).  Trains are
hints: dropped/deferred trains only cost prediction quality.
+1.0 MHz on the step10a base; wall moved to the dcache-internal
relaunch cone (rg_addr -> v_req_q D).

## Trajectory assessment

Each cut moves the wall to a sibling cone of the same ~28-30 ns family;
each yields ~1 MHz.  The cone family: rl_pipe mega-cone consumers
(ask deposit, perf taps, bp_train, dcache req/relaunch) - all rooted in
the stage1/stageF comb evaluation that rl_pipe reads combinationally.
Reaching 56 MHz needs every one of ~4-5 of these cones under 17.9 ns;
incremental endpoint cuts are asymptoting at ~35-38 MHz.  The known
remaining lever is the wholesale rl_pipe decomposition (decoupled
sequencers), which is the failed step-11 class done right: multi-day,
bench-forensics-first.

## FINAL VERDICT (2026-10-14, campaign closed)

| State | s3 Fmax | J1 | Outcome |
|---|---|---|---|
| step9 base (shipped) | 32.99 | PASS (banked) | **remains the promoted base** |
| step10a (v6-dreq + perf taps) | 33.89 | (2h run = load-phase stall) | closed |
| step11 (+elastic stage1) | 34.91 | FAIL deadlock (no banner) | reverted |
| step10a+step12 (+bp FIFO) | 34.88 | FAIL load phase (banner OK, acks=0) | closed |
| step13 (step9 + perf + bpFIFO, no v6) | 32.03 | — | below baseline, closed |

The v6-dreq queue on the step9 base stalls the ROM loader in the J1
strict sim (banner prefix byte-exact, then loader silence; the earlier
step10a 2-hour J1 "timeout" was this same stall, not slowness).  Each
successful cut moved the wall to a sibling cone of the same ~28-30 ns
rl_pipe mega-cone family for ~1 MHz each.  50 MHz (56 MHz ship bar) is
NOT reachable by incremental endpoint cuts; it requires decomposing
rl_pipe into decoupled sequencers (the failed step-11 class done
right): multi-day, bench-forensics-first, and explicitly scoped as a
separate project before any retry.

Tree reverted to the shipped step9 base (Flute 4f90b8b on
ulx3s-soc-step7; all experiments preserved in history with this
analysis).  The board keeps running the step9 bitstream
(bits/ulx3s_top.bit.step9-32mhz, 32.44-33.0 MHz-capable, 29.8% margin
at 25 MHz).

## Next (as originally planned)
1. ~~step10a+step12 gates~~ DONE (both run; FAIL verdicts above).
2. Bench/promote — SUPERSEDED: nothing reached the bench gate.
3. 50 MHz itself: CLOSED as a campaign; needs the rl_pipe
   decomposition project (scope before retry).
