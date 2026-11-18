# Linux ISA plan (linux-isa branch)

Goal: complete RISC-V support on the ULX3S Flute: RV32GC (IMAFDC + Zicsr/Zifencei), with B,
Zkn/Zkr/Zkt, S-mode, Sv32 and PMP.
- Linux boots through OpenSBI.
- Every extension is checked against Sail.
- Order: features first, timing after (rule 0 still applies at the timing stage).

## Status (2026-10-21)

| Item | State |
|---|---|
| S-mode, Sv32 I+D, PMP (8 entries, G=10) | done (V1-V5), formal CSR/trap/legal checks green |
| B (Zba/Zbb/Zbc/Zbs), Zkn, Zkt | done (XBox), 53/53 insn checks, 317 Sail-checked cases |
| Zkr | done (V7): seed CSR, ring-oscillator TRNG, SP 800-90B RCT/APT, formal csr_ill |
| OpenSBI 1.9 + Linux 6.12 | boots to user space in sim (V6) |
| Boot time | 640.45M -> 204.42M cycles after kernel config trim (legacy ptys, VT, unaligned probe) |
| **F, D** | **not started (this plan)** |

## Area budget (measured)

| | LUT4 | DFF | MULT18 | DP16KD |
|---|---|---|---|---|
| E22 (M/U, promoted) nextpnr | 51.8K (61%) | 25.8K | 10 | 11 |
| V7 nextpnr fit (`build/timing-exp/v7-fit.log`) | 62.1K (74%) | 28.0K | 10 | 13 |
| Stock Flute FBox, RV32 F+D+div+sqrt, yosys | ~22K-eq (18.9K LUT4 + 1.6K CCU2C) | 5.0K | 9 | 0 |

- **Ceiling.** At 90% (10% routing headroom) the ceiling is 75.3K LUT4, so F/D gets **~13K LUT4**.
- **Stock FBox.** It does not fit: it would land at ~85K, over 100%. Its FMA is also deep combinational logic.
- **Spare resources:**
  - DSPs: 146 MULT18 and 78 ALU54B unused.
  - Memory: 195 DP16KD unused, and LUTRAM (TRELLIS_RAMW) is at 3%.
- **Where the non-ISA area is.** Non-flattened synthesis (`v7-hier-stat.txt`) shows it, though the absolute numbers are inflated about 2.7×. In decreasing order:
  - AXI fabrics (Fabric_AXI4 and Fabric_2x3, mostly wide FIFO2s).
  - The Debursters.
  - Debug Module + DMI bridge + JTAG.
  - GPIO, SoC_Info, boot ROM.

  These are the reclaim candidates. ISA logic (XBox, CSR, MBox) is not on the list.

## Order

1. **Memory latency** (in progress; first bring up the SDRAM device model, Verification roadmap item 4). The I-refill costs 109 cycles against a floor of about 40.
   - Mem_Controller does eager 32 B writebacks.
   - Each line is two serialized 32 B reloads.
   - Contained to Mem_Controller/SDRAM, so it costs no core LUTs.
2. **F and D** (below). Settle FPU area before spending LUTs on cache ways or TLB entries: tag-compare and CAM logic compete for the same budget.
3. **Cache/TLB sizing.** Grow I$/D$ by ways (VIPT, 4 KB per way) and use set-associative TLBs. The metric is Linux boot cycles.
4. **Remaining extensions** in the "complete" scope (see Open decisions).
5. **Timing** back to ≥ the E20/E22 target with ≥10% margin, by architecture (rule 0).

## F and D

### Datapath: area-trimmed FPU behind the existing FBox interface
- The FBox request/response interface is already decoupled. Stage2 issues, Stage3 waits for the response, so a multi-cycle FPU costs nothing structurally.
- The existing `ISA_F`/`ISA_D` hooks stay valid: CPU 14, Stage1 8, Stage2 28, Stage3 10, Decode_C 13, CSR 11, EX_ALU 15.
- One shared 64-bit significand datapath:
  - **Multiply:** the 53×53 significand product on DSPs, with 9 MULT18 (spare: 146). The wide add can go on ALU54B.
  - **FMA:** multi-cycle through one aligner, adder, normalizer and rounder. Add, sub and mul reuse it.
  - **Div and sqrt:** one iterative radix-2 (or radix-4) unit shared by both. Long latency is acceptable.
  - **The rest:** conversions (int↔fp, s↔d), compares, min/max, sign-injection and classify reuse the normalizer and rounder.
- FPR file: 32 × 64 bits in LUTRAM.
- Area target: **≤10K LUT4** for the FPU plus the FPR file. If the first synthesis exceeds 13K, reclaim non-ISA area before shrinking FP features.
- The stock FBox stays the functional reference while the new unit is brought up (same interface).

### RV32-specific items to get right
- RV32D has no FMV.X.D or FMV.D.X. Moves go through memory (FLD/FSD). FCVT.D.W/WU, FCVT.W/WU.D and FCVT.S.D/D.S remain.
- FLD/FSD are single 64-bit beats on FABRIC64.
  - Confirmed: the D$ datapath is 64-bit and handles size-D accesses (`MMU_Cache.bsv:262,302`).
  - Still to check: the Deburster/Mem_Controller lane handling for 8-byte accesses, and a page- or line-straddling FLD (misaligned → trap → OpenSBI emulation).
- Compressed FP: C.FLW/C.FSW/C.FLWSP/C.FSWSP are RV32-only and share encodings with RV64 C.LD/C.SD/C.LDSP/C.SDSP. In `CPU_Decode_C.bsv`:
  - C.FLW checks no `misa.f`, unlike C.FLWSP.
  - None of the C.F* decodes checks `xl`.

  Fix both; the Sail-derived legal check will catch any remaining gaps.
- **mstatus.FS:**
  - Off makes every FP instruction and fcsr/frm/fflags access illegal.
  - Any FPR or fflags write sets FS=Dirty, and SD follows.
  - Check the sstatus view as well; the S view has been wrong before.
  - Linux lazy FP save depends on all of this.
- **Rounding:** an invalid rm, or frm=DYN with an invalid frm, is illegal. fflags accumulate; frm/fflags alias fcsr.
- **NaNs:** NaN-boxing of single values in 64-bit FPRs, with canonical NaN on results.
- **misa:** F and D set (D requires F).

### Verification
1. **Unit (arithmetic).** Verilate the FPU alone and drive Berkeley TestFloat (`testfloat_gen`) vectors checked against SoftFloat.
   - Cover every op × every rounding mode, checking exceptions flags.
   - Pattern: test/zkr/run.sh.
   - This is the standard method for FMA/div/sqrt. Bounded model checking those against IEEE is not practical.
2. **ISA.** rv32uf/rv32ud from the Flute and Sail riscv-tests through `sim/isa_bram/isa_run.py`, with Sail (`riscv_sim_RV32`) as the reference.
3. **Formal (riscv-formal fork).** Upstream riscv-formal has no FP verification. `docs/rvfi.md` has
   only a *proposed* FP interface (last touched in d2fd4d0, 2017): no checks, no insn models, and the
   FP ALTOPS it promises were never defined. Sail delegates FP arithmetic to SoftFloat externs, so
   it gives no formal spec for the math either. Build the proposal out:
   - Implement the proposed signals with their exact names (`rvfi_frs1..3_*`, `rvfi_frd_*`,
     `rvfi_csr_fcsr_*`) in Flute's RVFI wrapper, so the work stays upstreamable.
   - Define FP ALTOPS: simple stand-in functions used by both the DUT and the model for
     add/mul/FMA/div/sqrt/cvt. They prove operand, rm, flag and writeback plumbing; TestFloat (1)
     proves the math.
   - Sail-derived models for FL*/FS*, FSGNJ*, FCLASS, FMIN/FMAX, FEQ/FLT/FLE, FCVT int↔fp and FMV.X.W/W.X.
   - CSR checks for fcsr/frm/fflags.
   - Trap and legal checks for FS=Off → illegal and the invalid-rm cases.
   - A check that FS goes Dirty on FP writes, in both the mstatus and sstatus views.
4. **Linux.**
   - An FP userspace program (`-march=rv32imafdc -mabi=ilp32d`) running in two processes, to exercise context save/restore.
   - Boot time must not regress.

### Software
- Kernel: `CONFIG_FPU=y`.
- DT: `riscv,isa` / `riscv,isa-extensions` gain `f`, `d`.
- OpenSBI: `PLATFORM_RISCV_ISA=rv32imafdc_zicsr_zifencei`. Check that misaligned emulation covers FLD/FSD/FLW/FSW.
- Toolchain: the docker image already has `riscv64-linux-gnu-` with ilp32d multilib? Check this; it may need an rv32 glibc/musl build if userspace is more than freestanding.

## Verification roadmap

These are additions to the per-feature verification above. Statuses were written 2026-10-21; each item's **Update 2026-11-16** line says what has happened since.

### High priority
1. **riscv-arch-test under RISCOF, with Sail as the reference model.**
   - This is the official architectural compliance suite, separate from riscv-tests. It covers privileged behaviour, PMP, Zb*, Zk*, F/D and C at the encoding level.
   - It is required before claiming compliance, and would likely have caught the c.addi HINT bug earlier.
   - Status: not started. Sail (`~/src/sail-riscv`) and Spike (`~/src/spike`) are present locally.
   - **Update 2026-11-16: running.** `compliance/run.sh` (RISCOF against the Sail C model; `config-fd.ini` for the trimmed FPU, EXCLUDE globs for subsets), in the README gates; e.g. B 32 / K 21 / M 8 vs Sail on m14p (notes/memlat-verification-plan.md).
2. **Lockstep co-simulation against Sail or Spike on random instruction streams.**
   - Options:
     - **TestRIG** (Cambridge). It needs an RVFI-DII port: instruction injection plus an RVFI trace back. Flute's RVFI wrapper is the starting point.
     - A Spike step-and-compare harness on RVFI traces from the Verilator TB.
   - Why: riscv-formal BMC is only about 20–30 cycles deep. Long-sequence bugs slip past it: a TLB refill racing a page-table write, PMP changes mid-pipeline, interrupts during misaligned-access traps.
   - Status: **not started**.
   - **Update 2026-11-16: done with TestRIG** (`testrig/`, 312ab51, 2026-10-23): Sail vs Flute over RVFI-DII in Bluesim. Campaigns found D1-D3 (fixed in Flute d9cc5c4; 6b487b4: campaign 4 clean of DUT bugs). Not in CI (needs Sail, GHC, bsc locally).
3. **Random instruction generator: riscv-dv (CHIPS Alliance) or FORCE-RISCV.**
   - Stresses privilege-mode switches, Sv32 page-table configurations (megapages, A/D bits, permission combinations), PMP regions and interrupt injection.
   - Feeds item 2. TestRIG brings its own QuickCheck generators (VEngine).
   - Status: not started.
   - **Update 2026-11-16:** QCVEngine's generators (arith, mem, control, cache, muldiv, atomic, compressed, fencei, csr, pte, random, unstructured, bk) drive the TestRIG campaigns; riscv-dv / FORCE-RISCV not used.
4. **SDRAM device model.**
   - The vendor's (e.g. Micron) behavioural Verilog model of the ULX3S SDRAM chip, which checks tRCD/tRP/tRFC and refresh.
   - **Prerequisite for the Mem_Controller/Sdram_Controller latency rewrite (Order step 1).** The current TB memory would not flag a timing-parameter violation that fails only on silicon.
   - Status: **checker done (e20dc9e).** `sim/linux_bram/sdram_timing_check.v` is a passive pin-level checker for the actual part, the Winbond W9825G6KH-6 (datasheet A04), sitting beside `sdram_model.v`. The model already checks data integrity; the checker covers timing, init and refresh. No vendor Verilog model exists for this part (Micron's is for a different chip).
   - It found three bugs, all present on main too:
     - Refreshes were dropped while a request was in flight. The hello boot saw a 1666-clock (66 us) REF gap, close to the 9 x tREFI limit; under Linux traffic it is unbounded.
     - Init issued 2 refreshes instead of 8.
     - CKE was low during the 200 us pause.
     - All three are fixed on linux-isa. The V8 hello boot is clean: max REF gap 124 clocks.
   - Not covered: setup/hold (P&R covers these). The tRCD/tRAS/tRRD/tCCD/auto-precharge rules have not yet been shown to fire on a violation.
   - Port to main: pending the user's decision (it changes the promoted E20 controller).
   - Latent: `rl_rd_cap` stalls on the final beat when `f_rsps` is full while `rg_dq_in` keeps sampling, so beat 15 would be wrong. It is unreachable today, because Mem_Controller has at most one read outstanding.

### Medium priority
5. **Memory-model litmus tests (riscv-litmus / herd, RVWMO).**
   - Single-hart issues: I/D and MMIO ordering, fence.i with the write-through D$, sfence.vma, AMO and LR/SC ordering, fences around non-posted MMIO.
   - Small and cheap to run.
   - **Update 2026-11-17: done as `test/mm_test.S`** (litmus by construction, no herd: on one hart
     RVWMO reduces to "a load sees the latest program-order store to its bytes", plus FENCE.I
     for fetch and SFENCE.VMA for translation, so each check is a store/fence/load sequence with
     a fixed expected value).  0x1x FENCE.I: rewrite a slot already in the I$ twice, a never-run
     slot in the same line, a compressed slot by `sh`.  0x2x cached store -> load back to back:
     byte/half merges with sign extension, both halves of a 64-bit cache word, WAW of mixed
     widths, WAR, three tags on one index, and a cached and an uncached address with equal low
     12 bits.  0x3x uncached (framebuffer RAM, palette): partial-width stores then loads, two
     MMIO stores then loads, MMIO/cached interleaving with and without FENCE, palette [23:0]
     write semantics and restore.  0x4x Sv32 from M-mode with MPRV=1/MPP=S (PMP entry 0 NAPOT
     all, RWX): remap + full SFENCE.VMA, remap + address-specific flush, a store through the VA
     lands in the new page only, megapage, read-only PTE (load ok, store -> cause 15, mtval =
     VA), invalid PTE (load -> cause 13), the faulting store left memory unchanged.
     lx49b: PASS in the strict sim and on the board.  Mutant (one FENCE.I and one SFENCE.VMA
     removed): fails 0x11 (old instruction) and 0x41 (old translation) in both, so this core's
     I$ and TLB really do hold stale state and the fences are what clear it.  In CI (strict
     matrix `mm`, with `csr`).  Not covered: fences around a non-posted MMIO side effect
     visible elsewhere (no device here has one the hart can observe), and A/D updates (Svade:
     TLB.bsv faults on A=0, or D=0 for a store, before its update branch; Linux sets them).
6. **Debug spec compliance.**
   - The riscv-tests debug suite (gdbserver.py through OpenOCD) covers the Debug Module and JTAG: abstract commands, halt/resume, single-step over traps, DM system bus.
   - Nothing else checks these today.
   - **Update 2026-11-16: running on the board** (`test/debug/run.sh`, README "JTAG").  lx48:
     27 pass, 33 not applicable, 18 fail or error.  Triage:
     - Caches not flushed on resume (Flute flushes on Debug Mode entry only).  With no program
       buffer the debugger cannot run FENCE.I, so memory it writes while halted (software
       breakpoints, loaded code) can be hidden by I-cache lines fetched during the halt:
       StepTest (stepi stays on the breakpoint), PrivChange, ProgramSwWatchpoint, DebugExit,
       DebugBreakpoint, DebugSymbols, DebugChangeString, DebugFunctionCall.
     - A resume ignored `dcsr.prv`: the hart kept its old mode (PrivRw: `$priv=0` then stepi
       ran in M).  `dcsr.prv` was also not WARL (2 = H accepted).
     - A debugger access to a CSR that does not exist returned ok (SimpleNoExistTest); spec
       says cmderr 3 (exception).  The DM mapped every hart error to cmderr 4 (halt/resume).
     - RV32 with D: the DM rejected aarsize 64, so OpenOCD could not read the 64-bit FPRs
       (SimpleF18Test).
     - Not hart bugs: the four trigger tests (no trigger module; Sdtrig is not implemented),
       RepeatReadTest (expects riscv-openocd's newer message), SemihostingFileio (needs host
       semihosting set up): skipped in FluteUlx3s.py with these reasons.
     - Sv32Test (a gdb read through the page table at `$priv=0` failed) passes on lx49: the
       stale-cache bug, the page table had been written while halted.
     - lx49 (Flute d455742) fixes all four.  First build: 37 pass, 2 fail (PrivChange, PrivRw:
       a resume ignored `dcsr.prv`).  That fix made the restart rule wait on near_mem's fence
       response RDY, which reached the fetch-request select (seeds 46.17/52.78/49.39): the
       flush ack now only sets a flag and the restart fires off registers (55.87/51.15/51.47).
     - The suite never resets the hart between test classes; TooManyHwbp hung in 3 of 5 runs
       when an earlier test's timer interrupt was taken before the new program's first
       instruction through the old `mtvec`.  `FluteUlx3s.cfg` now does `reset halt`.
     - lx49 final (seed 7 bit, 57.54 MHz): 38 pass, 39 not applicable, 1 fail: DisconnectTest
       compares `mcycleh` across a disconnect and lost the race with the low half's wrap
       (`mcycle` was 0xff5f8282).
     - lx49b (Flute 6b893dc): `dcsr.stopcount` resets to 1 and holds `mcycle` while the CPU is
       in CPU_DEBUG_MODE / GDB_PAUSING / GDB_RESUMING (CPU rule -> `ma_debug_mode` ->
       `rg_hold_mcycle`, a ConfigReg: as a plain Reg bsc found a cycle rl_mcycle_incr ->
       ma_debug_mode -> mav_csr_write -> rl_mcycle_incr).  `dcsr.stepie` masks interrupts and
       NMI in rl_int_pending_bridge while stepping.  `stoptime` reads 0 (mtime is the CLINT's).
       Found on the way: CSR writes to `mcycle`/`mcycleh` were dropped (both arms of
       rl_mcycle_incr incremented, upstream "TODO: fix this"); riscv-formal's csrc_inc check
       cannot see that.  test/csr_test 0x22-0x24 now check it (FAIL on lx49, PASS on lx49b);
       riscv-formal csrw_mcycle_ch0 and csrc_inc_mcycle_ch0 PASS on lx49b.
     - lx49b board (seed 7): debug suite 39 pass, 39 not applicable, 0 fail (DisconnectTest
       pass in 6.6 s).
7. **CDC and reset checks.**
   - The ring-oscillator TRNG crosses an async boundary into the core clock; candidate tool is `run_cdc.py` in the sv-yosys battery.
   - UART RX, buttons and other async inputs go through the same pass.
   - **Update 2026-11-16:** not run as a CDC pass.  The TRNG's crossing is checked on the netlist (formal/fv/bin/ro_trng_netlist.py: each ring tap into a two-flop s1 -> s2 synchronizer without reset, all on the system clock), and the per-IP formal/fv specs leave pin inputs free.
8. **Raw-sample entropy assessment.**
   - Run NIST SP 800-90B `ea_non_iid` on raw ring-oscillator samples captured from the board.
   - RCT/APT only detect failures; Zkr needs a justified min-entropy claim.
   - **Done 2026-11-16, one board (promoted lx46 bit in SRAM, room temperature).** test/trng_dump.bin
     polls seed into SDRAM (168 clocks per word: 16 samples kept, ~5 dropped between words), then
     scripts/trng_capture.py writes one sample per byte.  NIST SP800-90B_EntropyAssessment 87c104d
     (build/ext, clang + libomp), `ea_non_iid -a <file> 1`, 2,097,152 samples per run:
     run 1 H_original 0.911 (lowest: compression; MCV 0.997, Markov 0.999), run 2 0.859; ones
     0.5002 / 0.4996; no health-test failure in either run.  Sanity: os.urandom (1M bits) 0.851, a
     p = 0.8 biased source 0.188 (true 0.32).  So the assumed H = 0.5 has margin.
   - **Restart test done 2026-11-16** (scripts/trng_restart.py, unattended, ~3.4 s per restart).
     A restart is a full FPGA reconfiguration from flash (JTAG refresh; flash offset 0 now holds the
     promoted lx46 SoC), NOT a power cut: the board's hub port (RTS5411) drops USB data but not VBUS.
     Each restart: test/trng_restart.bin (N_WORDS=63), first 1000 samples after the source's startup.
     1000 restarts, 0 retries, 0 health-test failures, 0 DEAD.  `ea_restart -v rows.bits 1 0.859`:
     sanity check passed (X_max 557 < X_cutoff 621), validation passed, H_r 0.884, H_c 0.847,
     min(H_r, H_c, H_I) = 0.847.
   - Not done: restarts through a real power cut (needs a VBUS-switching hub or relay), other boards /
     temperatures / voltage, and the raw pre-decimation bits (not reachable from software; the claim
     is per decimated sample).

### Campaign workflow
9. **Equivalence checking with YosysHQ EQY**, between pre- and post-change netlists, for behaviour-preserving E-series changes (retiming, FIFO insertion, ConfigReg swaps). Today equivalence is inferred from formal + J1 + bench.
10. **Functional coverage.** riscv-dv covergroups or OpenHW riscvISACOV, to show which instruction × privilege × trap combinations have actually run. Pass/fail is the only signal today.
11. **Formal liveness and deadlock.**
    - Run riscv-formal's liveness check routinely; there were hangs in E8a/E8b.
    - Add the FVIP MAXWAIT checks with properly composed bounds.
    - From the crossbar oracle: equal MAXWAIT on both sides does not compose through register slices. The far side needs a smaller bound, reduced by the pipeline latency.

    **Update 2026-11-18: MMU_Cache deadlock freedom, bounded** (`formal/fv/ips/mmu_cache`, `mmu_cache_tiny`; table in formal/fv/README.md). E8, E8b and E8c were all hangs at the D-cache's request / busy contract, so the checker states that contract at the ports: the CPU side as CPU_Stage2 and Near_Mem keep it, and the fabric as fair AXI4 (every channel within L = 2 cycles, in order). It asserts that every request is answered, busy drops, and reset / flush complete, each within 96 cycles. It also asserts that busy never holds 4 cycles with nothing owed.
    - The cache RAMs are cut to two sets (`vip/bsclib/bram2_lowsets.v`, free reads elsewhere: sound). Even so, the shipped 8 KB build spends ~66 of a BMC's steps in the reset loop. The 1 KB build (riscv-formal's RVFI_TINY_CACHES geometry, same FSM, 1 way) resets in ~16.
    - Bounded, not proved, and the depths matter. The first request comes after reset: step ~68 in the 8 KB build, step 21 in the 1 KB build. A 96-cycle bound therefore cannot trip in the 8 KB live run (bmc 125, PASS) or in tiny short (bmc 80, PASS). Those two runs check K_IDLE, the AXI rules and R / B acceptance. PDR (run before K_IDLE was added) proved 3 of 9 properties and left the rest open at 2 h.
    - The latency bounds themselves only in tiny `bound`: K = 64 at depth 96 fails, and the counterexample is real latency. An AMO misses the uDTLB, walks 2 levels, refills the uDTLB, then snapshots and refills an 8-beat line, with every fabric channel at its L = 2 limit. That takes 64 cycles to AMO_EXEC, before the write and its B. K = 72 at depth 96 passes (2.6 h), which covers only requests launched at steps 21 to 23. K = 80 at depth 104 hit its 6 h limit at step 100, one step before it could trip: no result.
    - K_IDLE's scope: `owed` includes a pending request, so K_IDLE says "busy with no request pending and nothing on the fabric ends within 4 cycles" (the E8b / E25 hang). The other half, a pending request stuck with nothing on the fabric, is K_WAIT (added 11-18): the longest run seen is 9 cycles (uDTLB fill, re-request, then the refill's AR), bound 16, `short` passes.
    - Unbounded (`safe`, abc pdr, latency bounds off, 1 KB build, addresses in sets 0 and 1): AR / AW / W stability and K_IDLE are **proved for all depths**. K_WAIT, the outstanding-burst bound (fv_queue depth 4), K_R and K_B are open at 3 h. Sanity: the same PDR refutes e8b and e25 within a minute. Probes at bmc 70: a B is taken the cycle it is offered (K_B = 1 passes) and an R within 10 (K_R = 11 passes); `safet` gives PDR those tighter bounds.
    - Mutants: reverting E8b (CACHE_ST_AMO_RSP counted as busy) or E25 (CACHE_LD_RSP) fails the K_IDLE assertion within 80 steps; the unmutated cache passes.
    - I side (`formal/fv/ips/icache`, `icache_tiny`): mkICache_Pipe has no busy. The obligation is that a wanted pc is presented within K_F of the last request or context change, plus reset / flush completion and nothing-owed idle bounds. Resets may come at any time and also reset the fabric, which is how the one real I-side hang happened (Flute 054d309, ndmreset). Reverting 054d309 fails K_IDLE_RST in `short` (bmc 60); four synthetic exit mutants fail K_IDLE; the unmutated cache passes, and the reset-during-a-PTE-read witness completes. Bounded only: 8 KB live passes to step 100, but the K_F / K_RST latency bounds are unchecked (K = 64 needs depth >= 84; the tiny `bound` run reached step 68 in 3 h).
    - Next: an unbounded proof (k-induction with invariants on the FSM, or PDR with a smaller loop counter), then compose with the I side and Near_Mem's arbiter.
12. **FVIP on the remaining ports.**

    Done (`formal/axi4_fvip`, vendored @250f1ff, see its README):

    | Port | Result |
    |---|---|
    | Mem_Controller slave | 15 asserts. Response witnesses reachable. Protocol checks pass to the reached depth. A mid-traffic `server_reset` drops BVALID/RVALID, but reset is boot-only in the SoC. |
    | AXI4_Deburster, both sides | 74 asserts. **Finding:** its B path matches slave responses by position (`f_w_awlen`), so a downstream slave that reorders across IDs makes it return wrong or duplicate BIDs. This is latent in this SoC: Boot_ROM and Mem_Controller answer in order. |

    **Update 2026-11-16:** formal/fv now has a spec for every SoC peripheral (audio, board_io, gpio, jtagg_dtm, regbus, sdh, sdram, soc_info, spdif, spi, uart_dmi, uart_pins, video, entropy_ro), with protocol VIPs (axi4_sb_vip, regbus_vip, ...) on their ports.

    Remaining:
    - Fabric_AXI4.
    - The core's master ports, in the riscv-formal wrapper: assert master compliance, assume memory compliance.
    - MMIO slaves: UART, CLINT, PLIC, SoC_Info, GPIO. Use the FVIP's AXI4LITE mode if they are AXI4-Lite.

    Rules: `MAX_*_BURSTS` ≥ 2 (avoids the write-path vacuity), explicit reachability witnesses (covers are not checked yet), and a constant-assert guard in every run.

### Tool notes
- **SVA yosys:** fork npe9/yosys `sva-frontend-ic3`, owned by peer session sv-yosys-e3.
  - Use ≥ `eab0ee5c5`. Earlier builds had false proofs: zeroed struct parameter overrides, and asserts folded to constant true by a later non-`-formal` read.

## Open decisions (user)

1. **Scope of "complete".** Baseline: RV32GC plus everything above. Candidates:
   - **Sstc** (stimecmp/stimecmph), which is backed by a measurement: `__sbi_set_timer` M-mode traps dominated the steady-state boot loop.
   - Zicntr/Zihpm with mcountinhibit, and menvcfg/senvcfg (priv 1.12).
   - Svinval, and Zicbom/Zicboz.
   - Zfa and Zfh/Zfhmin. Both cost FPU area.
2. **Reclaim** if F/D plus cache growth exceeds the budget. Which non-ISA blocks are negotiable?
   - Narrowing the fabric and its FIFOs is pure architecture.
   - Removing debug/JTAG, GPIO or SoC_Info changes features.
