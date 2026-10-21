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

1. **Memory latency** (in progress). The I-refill costs 109 cycles against a floor of about 40.
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

## Open decisions (user)

1. **Scope of "complete".** Baseline: RV32GC plus everything above. Candidates:
   - **Sstc** (stimecmp/stimecmph), which is backed by a measurement: `__sbi_set_timer` M-mode traps dominated the steady-state boot loop.
   - Zicntr/Zihpm with mcountinhibit, and menvcfg/senvcfg (priv 1.12).
   - Svinval, and Zicbom/Zicboz.
   - Zfa and Zfh/Zfhmin. Both cost FPU area.
2. **Reclaim** if F/D plus cache growth exceeds the budget. Which non-ISA blocks are negotiable?
   - Narrowing the fabric and its FIFOs is pure architecture.
   - Removing debug/JTAG, GPIO or SoC_Info changes features.
