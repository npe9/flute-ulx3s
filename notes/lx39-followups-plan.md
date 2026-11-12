# After lx39: plan for the open issues (2026-11-06)

lx39 (G1 HDMI framebuffer) is promoted, and lx40 after it (2026-11-09: the TVM and RegBus lost-ack
fixes the formal work found; build/ulx3s_top.bit md5 6c7b9293, 56.38 MHz s5). This plan orders what is left. The user asked for **as
much formal verification as possible**, so formal is a workstream of its own (section A) and runs
alongside the feature work (B, C). Section D lists the decisions only the user can make.

Standing limits: at most ~2 heavy jobs at once (a deep formal run counts as one); one run per
`RISCV_FORMAL` checkout (`formal/run.sh` deletes `checks/`, so read a FAIL trace before rerunning
in that directory); leave peer sessions' bsc/yosys/sby processes alone.

## Where formal stands today

| Area | Tooling | Last result |
|---|---|---|
| RV32IMC instruction smoke (10 checks) | `formal/run.sh`, upstream riscv-formal | **10/10 on lx39** (2026-11-06; 44 min at -j4, not ~4 min: the CPU has grown) |
| A, B/Zk, S-mode, CSRs, traps, F/D (313 checks) | forks `~/src/riscv-formal-{a,dev,s,fp}`; `fp-ext` contains `s-mode` | **2026-11-08/09 on the lx39+ netlist: 289 PASS** of the 298 that ran; the 9 FAILs are the 8 M checks (netlist without the ALTOPS stand-in; 8/8 PASS on the fixed one, row below) and `liveness` (latency, A6). 12 `csrc_*` targets have no template by design (`formal/csrs_msu_fd.cfg`) and their `csrw_*` checks PASS. Deep `freg` / `pc_fwd` / `reg` still running |
| M (8 checks, FP config) | private checkout `~/src/riscv-formal-m`, netlist with the MBox ALTOPS stand-in | **8/8 PASS** 2026-11-09; operand-swap mutant fails `div`. Covers operands, dispatch, rd, unit timing; **not the arithmetic**, which only the ISA tests exercise |
| `reg` / `pc_fwd` (deep) | `formal/run.sh deep` | pc_fwd PASS on E8d; reg stalls at step 75 (use `REG_DEPTH=74`) |
| AXI4 protocol | vendored FVIP `formal/axi4_fvip` | Mem_Controller slave, AXI4_Deburster only |
| Fabrics, MMIO slaves, SoC reset | none | **no formal** |
| AXI4_SPI | `formal/spi/` | **proved** (pdr + k-induction, SCKDIV <= 1) |
| AXI4_RegBus bridge | `formal/regbus/` | **proved** (pdr, with and without reset); found a lost-ack bug |
| Video_DVI (system side) | `formal/video/` | **proved** (k-induction, single clock) |
| Equivalence | yosys `equiv` script (`build/timing-exp/equiv_modules.sh`) | EQY not installed |
| Lockstep | TestRIG (sail-riscv-rvfi) | D1-D3 and F/D 200+200 clean in October; not routine |
| Compliance | `~/src/riscv-arch-test`, `~/src/riscof-venv` present | not run |

## A. Formal (ordered by risk to code that just changed, then by breadth)

**A1. Re-baseline the CPU proofs on lx39.** The SFENCE urgency change touched `CPU.bsv`, and
AGENTS rule 13 requires the smoke gate before P&R of a CPU change; it was skipped for lx39.
(1) smoke (minutes); (2) the full 313-check set from `riscv-formal-fp` with
`CSRCFG=formal/csrs_msu_fd.cfg` (hours, background); (3) `REG_DEPTH=74 formal/run.sh deep`
(hours). Any FAIL: read the trace, fix, rerun only that check.

**A2. One command, one table.** `formal/run_all.sh`: runs the sets in sequence (each in its own
checkout), writes `build/formal/summary.md` (check, status, depth, seconds). Wire the smoke set
into CI if the runner can afford it (~4 min locally, ~20 min at CI's 5x).

**A3. Fabric response conservation (closes the gap in the lx39 bus-error change).** FVIP on
`AXI4_Fabric` (main 2x5 and peripheral fabric): masters assume FVIP-master, slaves assume
FVIP-slave, the fabric asserts both sides, plus a conservation harness: every AR/AW gets exactly
one R-last/B, to the right master, with the right ID; DECERR for unmapped addresses.
Known open point to settle with this proof: lx39's error capture takes an event only when the
master's toggle is idle (`tog == ack`). A second DECERR on the same master and direction before
the merge rule runs is **dropped** (the old FIFO stalled the response instead). Property:
"each DECERR response raises the bus-error count by exactly one". Expect a counterexample, then
either (a) document the monitor as best-effort, or (b) prove it under an issue-rate assumption,
or (c) go back to back-pressure on that one path. -> user decision D3.

**A4. Debug reset without a magic number.** The 64-cycle ndmreset settle is long enough for an I$
refill today but proves nothing against a slave with unbounded latency. Replace it with a
quiescence wait (second reset pass only when the hart's AXI masters have no outstanding
transactions; counters per master), and prove with SBY: no R/B beat reaches a master across its
reset, and the reset sequence completes whenever the slaves are fair (liveness).

**A5. Peripheral IP proofs** (each a small SBY job, induction where possible):
- `AXI4_RegBus` bridge: FVIP AXI4 slave side, reg-bus handshake asserts, one access in flight.
  **Done 2026-11-06: `formal/regbus/`, unbounded by abc pdr** (seconds), with and without
  the reset method toggling. Hand-written AXI master assumptions (valid held until ready,
  single beat) rather than FVIP. Asserts: word-aligned rb_addr, no zero-strobe write,
  rb_valid held until ack or watchdog, dropped the cycle after ack, B/R held until accepted,
  rlast on every read, response count = request count. BMC found a real bug: intake did
  not check the response FIFO, so a request accepted while B/R was full lost its ack
  (`rl_wr_start`/`rl_rd_start` now require `notFull`). Covers (write, read, upper lane,
  watchdog SLVERR) all reached; the SLVERR cover uses a `-D FORMAL_SHORT_WDOG` build (limit 7)
  because 255 cycles is too deep for BMC. `mutate.sh`: 3 injected bugs fail.
- `Video_DVI.v`: reset values that fb_test reads; read FSM always completes in 5 cycles; bank
  select one-hot; last bank bounds; writes dropped past the backed RAM; the two clock domains
  with `multiclock on`: MODE through the two-flop synchronizer, banks written only on sys clk.
  **Done 2026-11-06 (single clock): `formal/video/`, unbounded by k-induction** (depth 10,
  seconds): reg-bus device contract (write ack 1 cycle, read 5, one-cycle pulse), a symbolic
  pixel word / palette entry / MODE read back what was written, unbacked reads 0, control
  registers. 36-word geometry (same banks and muxes); `mutate.sh` checks 3 injected bugs fail.
  Open: multiclock, and the scan-out side.
- `Sdram_Controller`: **Done 2026-11-08: `formal/sdram/`, unbounded except as noted** (`run.sh`
  runs all of it, seconds to a minute a group; pdr gave up after an hour on refresh and decode,
  and k-induction with a ranking function and FSM-to-pin invariants does them in seconds).
  Init order, one MRS, state at the MRS (pdr). JEDEC timings in 50 MHz clocks: tRP/tRAS/tRC/tRRD/tDAL (tRCD is
  one clock by construction, no assert), no command truncating a burst, REF only with all banks idle (pdr). Read credit: `chunks in flight <= 8`,
  capture never stalled, every chunk at READ+6 then every 4 clocks (k-induction). Refresh gap
  <= 150 cycles at every point after the MRS, whatever the requests do (k-induction). Commands
  match the request: row, bank, column, burst order, gapless, auto-precharge on the last (k-induction).
  Read and write data, byte masks (k-induction, k=12). Assume-guarantee chain, no cycles, listed
  in `run.sh`; the FIFO contract is `fifo.sby` on bsc's SizedFIFO at width 1 (control does not
  read the data). `mutate.sh`: 14 injected bugs, each stops its proof, and it requires the same
  task to pass unmutated first.
  Bounded, or assumed and not proved: the refresh gap at the MRS is a BMC on the
  `FORMAL_SHORT_PWR` build, exhaustive because init takes no inputs, with the real 200 us pause
  covered by argument only (ref_cnt reaches 1, the gap is the few cycles since the last init REF).
  Request shapes are assumed of Mem_Controller (not proved of it). Refresh is stated for the
  50 MHz divider; SDRAM electrical timing and CAS capture delay are not modelled (the capture
  offset comes from `t_cas_first`, sim-validated). The joint check with no hand-offs is only a
  bound: `bmc` (boolector, with data) reached step 85 in about a minute and got no further in a
  30-minute limit; `bmc_deep` (abc bmc3, no data) found nothing through frame 132 in a 1-hour limit
  on this harness. `cover` reaches all its statements, including the MRS and a full-line read.
- `AXI4_SPI`: FIFO bounds, CS HOLD semantics (FE310: a *different* value releases HOLD),
  mode 0/3 clock phase, no lost TX byte.
  **Done 2026-11-08: `formal/spi/`, unbounded.** `prove_ctl` (abc pdr, seconds): TX/RX levels
  <= 8; a CS asserts only when selected and CSMODE != OFF (the flash only for CSID 1); every SCK
  edge of a frame has the selected CS asserted; HOLD survives same-value CSID/CSMODE/CSDEF
  rewrites; AXI B/R stability and response counts. `prove_k` (k-induction, k=6, about a second, with
  invariants on FIFO slots, shifters and edge count): a tracked TXDATA byte goes out on MOSI, decoded
  at the pins in the frame's CPOL/CPHA/bit order, and comes back through the MISO loopback in
  FIFO order. It assumes the FIFO bounds from prove_ctl, which assumes nothing from it. Limits: the
  environment keeps SCKDIV <= 1 while frames are queued and changes SCKMODE/FMT only when idle;
  FMT.len and proto are stored but not modelled; the RX end is the RXDATA pop, not the R channel
  (lanes: Tb_AXI4_SPI). `mutate.sh`: 7 injected bugs each give a BMC counterexample and stop the proof
  passing; 4 covers reached. Plain pdr on the data path did not converge (frame 110, 30 min). No
  bugs found.
- `Sdram_Controller` raw port (memlat plan 4(d)): credit <= 8, chunks in order, refresh
  interval bound (the three refresh/init bugs were found only by the sim checker).
- MMIO slaves: UART, CLINT, PLIC, SoC_Info, GPIO with FVIP (AXI4LITE mode where they are Lite).

**A6. Liveness and deadlock.** riscv-formal `liveness` with fairness assumptions on the AXI
slave model (the E8a/E8b and ndm hangs were all of this class); FVIP MAXWAIT bounds composed
through the fabric's register slices (far side bound = near side minus pipeline latency).
  **2026-11-06 run (F/D netlist): `liveness 1 55 75` FAILS, but it is latency, not a hang.**
  The trace: a load at step 55 takes a uDTLB miss (UDTLB_FILL/FILLP/FILL2, 3 cycles), replays,
  misses the cache, then CACHE_SNAPSHOT (cwords_per_cline+2 = 10 cycles, by design) and an
  8-beat CACHE_REFILL, about 26 cycles in total against the check's 20-cycle window. A PTW whose PTE
  reads also miss is ~3x that, so no BMC window that fits in the solver budget (depth 76 took
  2 h) can bound Flute's worst-case per-instruction latency. Keep `liveness` only as a smoke test
  with an explicit window; real deadlock freedom has to come from the per-unit bounds above
  (MMU_Cache FSM: every state exits within N cycles given fair AXI, composed).

**A7. Property strength.** `mcy` (installed) on the A3/A5 harnesses and on a few CPU checks:
mutants the properties do not kill show what is unchecked.

**A8. Equivalence for behaviour-preserving changes.** Build and install EQY; use it for
retiming / FIFO / ConfigReg changes in place of "formal + J1 + bench".

**A9. Breadth beyond BMC depth** (not formal proofs, but the same goal): make TestRIG lockstep
routine (Sail-RVFI vs Flute, all extensions); run riscv-arch-test under RISCOF with Sail as the
reference; then the debug-spec suite and RVWMO litmus tests.

Order: A1 now; A3 and A5-RegBus/Video next (they cover lx39's new logic); A4 with the next
SoC_Top change; A2 once A1's sets are stable; A6-A9 as background work.

## B. Linux framebuffer (simple-framebuffer, in the tree uncommitted)

dts node at 0xC100_0000 (320x240 r5g6b5, stride 640), `/init` sets MODE=2 through `/dev/mem`
and mirrors its banner and tick lines to tty0 (fbcon); kernel config adds simplefb/fbcon.
1. Rebuild `out-fp` (in progress; lx39 image saved in `build/linux-out-fp-lx39/`).
2. Linux sim to tick 2; capture the framebuffer (fb_capture) and check fbcon text is drawn.
3. Board: boot, user checks the console on the monitor. Note the cost: fbcon scrolling through
   ~42-cycle uncached stores; measure tick-line latency on the board.
4. Commit on its own; CI's Linux job uses the same sources.

## C. TempleOS on the framebuffer

Video mode 1 is 640x480, 4 bpp palette, TempleOS's own graphics format, so no conversion layer:
point the gr frame buffer at 0xC100_0000 and load the 16-colour VGA palette into PAL (0x400).
Two scopes:
- C1 (small): a text VT on the framebuffer (8x8 font, 80x60), the REPL echoed to UART and screen.
  New `templeos/ulx3s_repl/ulx3s_video.hc`, address in `ulx3s_memmap.hc`.
- C2 (large): the real TempleOS gr/DC layer drawing into the framebuffer (windows, sprites,
  `GrPlot`/`GrLine`), which also needs a periodic update hook.
**Decided 2026-11-06: C2, full graphics** (plan in `soc-family-plan.md`, `templeos` profile).

## D. Decisions for the user

1. **Flash offset 0**: write the lx39 bitstream at 0 so the board powers up into Flute, replacing
   the original bitstream there (full flash backup exists: `build/flash-backup-20261104.bin`,
   md5 0ae3c1d8)? Today offset 0 is untouched.
2. **Default flash boot image and wait**: currently Linux, 3 s.
3. **Bus-error capture semantics** (A3): best-effort, or exact with back-pressure?
4. ~~TempleOS scope~~: decided, C2 (full graphics).

## Later (phase 2 continues)

USB keyboard (low-speed HID host on US2) and the other buttons/switches. The chip is at 71-72%
LUT and HDMI builds route at 50-53 MHz, so the next peripheral needs area back first: fabric
and FIFO narrowing (pure architecture), the register-bus bridge for every small device.
