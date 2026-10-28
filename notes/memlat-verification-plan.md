# Memory path (memlat): verification plan for the open gaps

Scope: the streaming Mem_Controller + Sdram_Controller (m4b / m5). The core is unchanged, so
riscv-formal, RISCOF and TestRIG do not apply (they model memory themselves). Ordered by
cost-to-value; items 1-3 are one file each.

## 1. mc_ut extensions (gaps 2, 6; part of 1) -- DONE (bfc2cea)
- Random `arid/awid` (Wd_Id bits); assert `rid/bid` echo the request's ID.
- `NLines` 8 -> 32, so evictions and line-crossing segments hit more distinct lines.
- Raw-memory mode with the real cadence: first chunk after ~10 cycles, then one chunk every 4.
- Error bursts: `set_addr_map` window ends inside the traffic range, and some bursts cross it.
  In the SoC the fabric and Mem_Controller share SoC_Map, so a burst crossing the end of the
  window is the only realistic error. Expect SLVERR on every R beat with `rlast` on beat
  `arlen`, and one SLVERR B per write burst after all its W beats are consumed.
- Pass: 0 errors; mutants (no ID echo, rlast early, B before last W) fail. Effort: small.

## 2. sdram_ut on the streaming request shapes (gap 6, gap 7) -- DONE (d442e17, `RAW=1`, `RAW_PLL=1 TCK_PS=31111`)
- Second UT top driving `mkSdram_Controller`'s raw port directly: random `b_first..b_last`
  (single bursts, odd first burst, all 4), partial `wbe` (empty bursts skipped), same-bank
  back-to-back (tDAL hold), credit-limited reads (consumer stalls). Mirror model + checker.
- Parametrize tb.sv `TCK_PS`; run 40000 and 31100 (PLL clock). Counts round the same today;
  the run guards future constants.
- Pass: 0 mismatches, `[sdram_chk] 0 error(s)` at both clocks. Effort: small.

## 3. Soft reset with traffic in flight (gap 3) -- FIXED (m12, 2026-10-26)
- m12 (Flute a440cc7, outer 2af8251): I$ epoch+abandon, MC drain keeps reqs taken during the drain,
  D$ epoch filter on B/R, two-pass ndmreset in SoC_Top, Boot_ROM/deburster/GPIO/SoC_Info reset with
  the SoC. Board idle 10/10, busy 10/10 (m9: 1/10); sim/ndm_bram 24/24; J1 strict, ISA 79/79.
  Merged into linux-isa (084c246).
- Ported to main/E20 (outer 63449fa, Flute cebade2). E20 needed two extras: Mem_Controller
  `f_reqs.clear`, and resetting the AXI4_Deburster in front of mem0_controller (unreset, it kept a
  stale AW, mis-paired the next write, lost a B, and the D$ hung in CACHE_START_REFILL). E20 custody
  bit fails busy ndmreset at cycle 19/20; the port passes 40/40. All rule-15 gates green.
- `SoC_Top.fa_reset_start_actions` (debug-module ndmreset, e.g. GDB `monitor reset`) resets
  the core, Mem_Controller and fabric, not Sdram_Controller. A raw read in flight keeps
  returning chunks into the cleared Mem_Controller: later reads get shifted data. The write
  buffer is also dropped (acceptable on reset).
- REPRODUCED (2026-10-25): `sim/mc_ut/run.sh +reset_test` resets Mem_Controller with 6 raw
  chunks of a line read still to come; the next line read returns those 6 stale chunks first
  (8 errors, every word shifted by 6). Reachable on the board: SoC_Top.rl_ndm_reset_start
  (debug-module ndmreset, INCLUDE_GDB_CONTROL) calls the same fa_reset_start_actions.
  The default mc_ut run (no plusarg) does not exercise it and passes.
- Fix options (USER DECISION): (a) Mem_Controller drains owed chunks (counter, like the FVIP
  `owed`) before answering the reset; (b) reset Sdram_Controller with the SoC (refresh must
  continue; keep its init); (c) document reset as boot-only. Recommended: (a).
- Then lift the FVIP `!EN_server_reset_request_put` assume, so B/R handshakes in flight are
  covered (the fabric is reset too, so the harness may need the slave side to drop them).

## 4. Formal depth and data (gap 5) -- (a), (c) DONE 2026-10-25 (see formal/axi4_fvip/README.md)
- (a) `max_dirty_cycles` and `idle_wb_cycles` behind a `define`; a formal-only bsc build of
  mkMem_Controller with 4 / 2, so depth 12 reaches age-out. New witness `reach_age_wb`.
- (b) Unbounded: rerun the ic3 flow (sv-yosys fork) that proved 9/15 on the old controller,
  on m5. Pass: every protocol assert proved or a counterexample explained.
- (c) Data integrity in the harness: one free address X; assert any R beat for X returns the
  last W data accepted for X (shadow register, byte strobes). Needs the raw memory modelled
  as storage for X only.
- (d) Last: Sdram_Controller raw-port formal (credit never exceeds 8, chunks in order,
  command spacing). Effort: large; only if (a)-(c) are clean.

## 5. Liveness (gap 8) -- FVIP part DONE 2026-10-25 (`DEFS=-DLIVE`; found the power-on-cycle drop)
- Bounded liveness as safety in the FVIP harness: assume raw memory returns owed chunks within
  M cycles and RREADY/BREADY within MAXWAIT; assert `rd_out > 0` -> an R handshake within K
  cycles, `wr_out > 0` -> a B within K (K < depth). Assert `owed <= 8`.
- System level: mc_ut watchdog, Linux boots, board soaks (already running).

## 6. Other masters (gap 1) -- debug sysbus DONE on the board 2026-10-26 (m12)
- `test/sysbus_board.py`: with Linux running, 4096-word sysbus read of OpenSBI text vs the
  payload, same-value word/byte/64 B-block writes, then 16 KiB of distinct-value writes (256
  autoincrement blocks + 1197 shuffled byte/halfword/word writes) to the padding after OpenSBI
  text (0x80038000, nomap for Linux), checked against a host model and zeroed again.
  m12: PASS, 0 mismatches, sberror clear, Linux keeps ticking. Sim variant not done.
- accel0 (`src/AXI4_GPIO.bsv`) never issues on its master port: nothing to test.
- Debug-module system bus: on the board, GDB/JTAG reads and writes to SDRAM while Linux runs
  (word, byte, 64 B block), compared with a CPU-side readback. Pass: data matches, Linux keeps
  ticking. In sim: a DMI-driven sysbus test in strict_bram if the JTAG TB supports it (check).
- Interleaved masters: I$ + D$ interleave in every Linux boot already.

## 7. Vendor SDRAM model (gap 4) -- USER DECISION: which model
- W9825G6KH-6: 256 Mb x16, 4 banks x 8192 rows x 512 cols. Candidate: Micron MT48LC16M16A2
  Verilog model (same organization, has its own timing checks; -75 grade ~ -6 here). Verify
  the organization and timing parameters before use. Download into its own empty directory.
- Build variant of sdram_ut and linux_bram with the vendor model. Pass: 0 model warnings,
  0 checker errors, 0 mismatches, Linux boot.
- Validates `t_cas_first = 3` (IOB + input register pipeline) only as far as the model is
  cycle-accurate at the pins; the board remains the final word.

## 8. Board-level timing (gap 7) -- m12 soak DONE; PLL: m15p soak PASS (m14 box-launch fix)
- m12 30-min Linux soak (build/m12/ulx3s_top-m12-s3.bit, md5 e3729c14): tick 1740 at 1774 s,
  0 bad (one tick line interleaved with "crng init done", as on m5).
- m12 SYS_PLL=1 (32.14 MHz): seeds 33.33 / 35.35 / 34.10 / 31.54 (FAIL) MHz, LUT4 59,186,
  COMB 87%. Best margin 9.99% < rule 7's 10%: not benched. Critical path: D$ rg_addr ->
  rg_lrsc_pa enable (LR/SC reservation compare), 5.1 ns logic / 23.2 ns routing (congestion).
  Correction: the real sink is stage2_fbox.rg_x CE -- box reqs were issued from fa_enq, so
  their enables depended on the stage2 advance (D$ hit).
- m14 (Flute c36092e): deferred box launch (shifter/MBox/XBox/FBox), +1 cycle per box op.
  ISA 79/79, RISCOF B 32 / K 21 / M 8 vs Sail. m14p seeds 37.51/37.10/37.79/35.40 MHz.
- m14p board: Linux ran clean ~28 min (1635 ticks, 0 bad) but Linux time ran 1.286x fast:
  mtime counted system clocks against the 25 MHz DTB timebase.
- m15 (Flute: mtime Bresenham accumulator under SYS_CLK_HZ): m15p seeds 36.41/35.99/37.57/
  38.94 MHz (worst 12% margin), LUT4 59,205. Board build/m15p/ulx3s_top-m15p-s4.bit (md5
  04a0e097): 30-min soak tick 1751, 0 bad, uptime 1775 s in 1779 s wall. Item 8 PLL: PASS.
- m15 gates (2026-10-28): riscv-formal smoke 10/10 PASS (no FP; covers deferred SH/M/X
  launch). F2 8 seeds identical on non-PLL build/m15 (the strict sim's UART monitor assumes
  25 MHz, so PLL netlists garble the banner -- run sims on the non-PLL build). Sim cache /
  AMO print T..D (run.sh FAIL is the expected missing-hello scoreboard check, same as E20).
  Board m15p: cache PASS, AMO PASS, bench 69/1/2 at 32.14 MHz (perf cycles rate ok); the one
  FAIL is `Reg misa` hard-coded to main's 0x40101105 vs linux-isa 0x4014112f (ACDFIMSU),
  i.e. the suite needs a per-config misa. A first bench run showed a second FAIL that was
  not captured and did not recur. Custody restored (e8521522).
- m5 board boot + 30-min soak (first board run of consecutive ACT -> READ).
- PLL build (`make SYS_PLL=1`, 32.14 MHz) of m5: seeds, boot, soak. Only place the real
  tRCD / CAS margins are exercised. Bitstreams named *.bit; restore the custody bit after.
- Board cache / AMO tests and ipc_bench on the chosen candidate.

## Gate table to finish (existing gates)
| | m4b | m5 |
|---|---|---|
| sim cache/AMO/CSR | cache pass, AMO/CSR running | to run |
| J1 strict | pass | queued (strict_bram busy) |
| Linux sim + sdram_chk | pass | running |
| FVIP BMC + reach | pass | pass (d13 bitwuzla, 11/11 by step 12; +LIVE, +DATA) |
| board boot + soak | pass | pass 2026-10-25: build/m5/ulx3s_top-m5-s2.bit (md5 80673f00), tick 1 at 3 s, 30-min soak tick 1743, 0 bad |
