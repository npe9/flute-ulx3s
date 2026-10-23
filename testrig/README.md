# TestRIG lockstep testing (RVFI-DII): Sail vs Flute

TestRIG's QuickCheckVEngine (QCVEngine) generates instruction sequences and
injects them, one instruction at a time, into two implementations over RVFI-DII
(Direct Instruction Injection). It then compares the RVFI retirement records.

* Implementation A (reference): the Sail RISC-V model (`riscv_rvfi_RV32`).
* Implementation B (DUT): this Flute core (RV32 IMAC + B + Zkn + Zkr,
  M/S/U, Sv32, PMP), built for Bluesim with `-D RVFI -D RVFI_DII`.

Everything added for TestRIG sits behind `RVFI_DII`. Production builds are
bit-identical: `testrig/netlist_hash.sh` re-runs the V7 production bsc
command, and the Verilog hash
`2edbb236105a3441e6938399b2ea3dd6df4b86a119c9d1fefde4aef189c741db` is the
same before and after this branch.

## Pinned versions

| piece | version |
|---|---|
| TestRIG | `CTSRD-CHERI/TestRIG` 7071795 (clone at `~/src/TestRIG`) |
| QuickCheckVEngine | 5e15965, `cabal build -w ghc-9.4.8 -j4`, binary copied to `vengines/QuickCheckVEngine/bin/QCVEngine` |
| BSV-RVFI-DII | 68c65a8, copied into `Flute/src_Testbench/RVFI_DII/` (two C fixes, see below) |
| SocketPacketUtils | 08eddb7 (`socket_packet_utils.c`, same directory) |
| Sail RISC-V | `riscv/sail-riscv` af5c2f2 + `testrig/sail-rvfi.patch`, sail 0.18.0 (opam switch 4.14.2) |
| bsc | 2025.01 (`~/src/bsc/inst/bin`; Bluesim needs `bluetcl` on `PATH`) |

## Build

```sh
# 1. QCVEngine
git clone https://github.com/CTSRD-CHERI/TestRIG ~/src/TestRIG
cd ~/src/TestRIG && git checkout 7071795 && git submodule update --init vengines/QuickCheckVEngine utils/BSV-RVFI-DII
cd vengines/QuickCheckVEngine && cabal build -w ghc-9.4.8 -j4 \
  && mkdir -p bin && cp "$(cabal list-bin -w ghc-9.4.8 QCVEngine)" bin/QCVEngine

# 2. Sail with RVFI-DII (a separate clone; the normal riscv_sim_RV32 has no --rvfi-dii)
git clone --shared ~/src/sail-riscv ~/src/sail-riscv-rvfi
cd ~/src/sail-riscv-rvfi && git checkout af5c2f2 \
  && git apply ~/src/ulx3s-experiments/flute-testrig/testrig/sail-rvfi.patch
eval $(opam env --switch=4.14.2 --set-switch)
ARCH=RV32 make -j3 c_emulator/riscv_rvfi_RV32

# 3. Flute RVFI-DII DUT (Bluesim) -> build/testrig-dii/Flute_RVFI_DII
make -C testrig JOBS=4
make -C testrig ram8m          # optional: Sail's default 8 MiB map, build/testrig-dii-ram8m/

# 4. Production netlist identity check (V7 bsc command) -> build/testrig-<tag>/netlist.sha256
testrig/netlist_hash.sh after
```

## Run

```sh
# one generator: Sail on PORT_BASE, DUT on PORT_BASE+1 (free ports are picked automatically)
testrig/run_testrig.sh -o build/testrig-runs/x -r rv32imacs_zicsr_zifencei -I '^mem$' -n 200 \
    --csr-exclude-regex 'mhpm|hpmcounter|mcountinhibit|pmpaddr([89]|1[0-5])|pmpcfg[23]|cycle|time|^mip$'

# replay one trace (no shrinking); DUT_ARGS=+dii_memtrace logs every D-side AXI beat to dut.log
testrig/run_testrig.sh -r rv32imacs_zicsr_zifencei -S -t testrig/divergences/d2_stale_load_after_misaligned_trap.S

# full campaign: N tests per generator, keep going on failure, save + classify failures
testrig/run_campaign.sh build/testrig-runs/campaign 200 arith mem control cache muldiv atomic memAmo
testrig/run_campaign.sh build/testrig-runs/campaign 200 compressed fencei csr pte random all unstructured bk

# B / Zkn: QCVEngine has no generator templates for them, so random traces come from
# gen_bk_traces.py and are replayed with -d ('bk' in run_campaign.sh does this)
python3 testrig/gen_bk_traces.py build/testrig-runs/bk 300 1 24
testrig/run_testrig.sh -r rv32imacs_zicsr_zifencei -S --continue-on-fail -d build/testrig-runs/bk

# classify saved failures; delta-debug one down to a minimal trace
python3 testrig/classify_failures.py build/testrig-runs/campaign/*/fail
python3 testrig/minimize.py FAILURE.S OUT.S [LABEL] [JOBS]
```

Use `-S` (no shrinking) for campaigns. The D2 bug below depends on a D-cache
BRAM output register that is not reset between tests. Because of that,
QuickCheck's shrink replays are not reproducible: a test fails, and its
"shrunk" replay then passes. `run_testrig.sh` passes `--no-save` unless `-s DIR` is given.

## Harness

* `Flute/src_Core/CPU/CPU_DII_IMem.bsv` wraps Near_Mem's I-side.
  * Every fetch still goes to the real ICache_Pipe, so ITLB/PTW, PMP and
    fetch faults are real. Only the instruction bits come from the trace.
  * Instructions are indexed by trace position. A sequential fetch uses
    the previous index + 1.
  * Every redirect (branch, trap, xRET, CSR/FENCE restarts) uses the number
    of RVFI records retired so far. All redirects in this pipeline happen
    after the redirecting instruction retires. FENCE, FENCE.I and SFENCE.VMA
    count the instruction retiring in the same rule.
  * Known approximation: for a 32-bit instruction at PC = 2 mod 4, the
    PC+2 granule is not translated or checked separately. Sail does check it.
* `CPU.bsv` changes, all under `ifdef RVFI_DII`:
  * The changes above.
  * WFI retires as a NOP.
  * The `rg_rvfi_mtvec` read in `rl_trap` is left out, because it triggers a
    Bluesim scheduling error.
* `Flute/src_Testbench/RVFI_DII/`:
  * `mkFlute_RVFI_DII` holds the BSV-RVFI-DII bridge (TCP port `$RVFI_DII_PORT`)
    and `mkFlute_DII_DUT` (CPU + two AXI4 slaves). The bridge resets the
    DUT after every test.
  * `DII_AXI4_Mem.bsv` is the D-side RAM: a sparse C store (`dii_mem.c`),
    zeroed on every reset, returning SLVERR outside RAM. The I-side returns
    OKAY/zero for every read.
  * RVFI records are converted from riscv-formal's word-aligned memory fields to
    byte address + LSB-aligned data, and RVC HINTs report rd = 0, as Sail does.
  * Two fixes to `socket_packet_utils.c`: `#include <string.h>` and
    `static inline acceptConnection` (clang).
* Other `RVFI_DII`-only reset/config changes:
  * GPRs and mscratch/mepc/mtval/sscratch/sepc/stval reset to 0 (Sail's values).
  * PC resets to 0x8000_0000 and mtvec to 0.
  * Production cache/BTB geometry (the riscv-formal "tiny" variants stay
    formal-only).

## Configuration (Sail vs Flute)

* Sail flags: `-I -F -i --pmp-count 16 --pmp-grain 10`.
  * misa is not writable.
  * No F/D.
  * mtval holds the instruction bits on an illegal instruction.
  * PMP grain is 4 KiB. Sail accepts only 0/16/64 PMP entries, and Flute has 8.
* Memory map: RAM is `[0, 0xFFFF_FFC0)` on both sides
  (`SAIL_RVFI_RAM_BASE=0 SAIL_RVFI_RAM_SIZE=0xffffffc0`, an env override
  added by the patch).
  * Sail's RAM size is XLEN wide and cannot reach 2^32.
  * A 64-byte-aligned limit makes Sail's end-of-access check and the D-cache
    line granularity agree.
  * The top line is vacant, so stores there show D1.
  * `RAM8M=1` runs Sail's default map (8 MiB at 0x8000_0000) against the
    `ram8m` DUT build.
* `testrig/sail-rvfi.patch` (harness fixes in the reference, none
  architectural):
  1. RAM base/size env override.
  2. `reinit_sail` cancels the LR/SC reservation. It lives in the C
     platform, so it used to survive the per-test reset, and a test's first
     SC then succeeded.
  3. The RVFI-DII fetch now does the PMP check the normal fetch does. It
     only translated, so U/S-mode fetches with no matching PMP entry
     succeeded in Sail.
  4. `rvfi_insn` for a 16-bit instruction is reported with the upper half
     zero (the RVFI convention). Sail used to echo the whole injected word.
* CSR exclusions (`--csr-exclude-regex`) cover platform choices where the two
  models legitimately differ:
  * HPM events/counters and mcountinhibit: Sail traps, Flute reads zero.
  * pmpaddr8-15 / pmpcfg2-3: Sail has 16 entries, Flute 8.
  * cycle/time values: not comparable in lockstep.
  * mip: Sail's MTIP is always pending, because its mtimecmp is 0. The DUT
    ties the timer interrupt off.
* QCVEngine names every CSR it does not know "reserved", so a regex cannot
  separate pmpaddr16-63 or the debug/trigger CSRs from truly reserved numbers.
  These are classified per address in the results instead (see below).
* XBox (`RISCV_XBox.bsv`) is Flute's execution unit for the standard Zb*/Zk*
  encodings (OP / OP-IMM). It adds no custom opcodes, so nothing had to be
  excluded from generation for it. Its instructions are covered by the B/Zkn
  traces.

## Results (2026-10-22, campaign `build/testrig-runs/campaign3`)

Arch `rv32imacs_zicsr_zifencei`, `-S --continue-on-fail`, with the CSR
exclusions above. "Failing" counts the failures saved with `-s`. Each one
was classified by `classify_failures.py` from its re-run.

| generator | sequences | failing | classification of failures |
|---|---|---|---|
| arith | 200 | 0 | |
| control | 200 | 0 | |
| muldiv | 200 | 0 | |
| mem | 200 | 27 | D2 21, D2? 3, rerun-ok 3 |
| cache | 200 | 36 | D2 27, D2? 9 |
| fencei | 200 | 29 | D2 22, D2? 5, rerun-ok 2 |
| atomic | 200 | 79 | SC-allowed 51, D2 13, D2? 10, rerun-ok 5 |
| memAmo | 200 | 30 | D2 20, D2? 8, rerun-ok 2 |
| compressed | 200 | 16 | D1 16 |
| csr | 200 | 76 | D3 36, cfg-pmp 34, cfg-csr 3, cfg-debug 3 |
| pte | 200 | 0 | (see note) |
| random | 200 | 24 | D2 15, D2? 3, D1 6 |
| all | 200 | 21 | D3 4, cfg-pmp 3, SC-allowed 3, D2 2, D2? 4, rerun-ok 5 |
| unstructured | 8 x 25 (2 chunks aborted by a Sail crash) | 42 | D2 15, D3 6, D1 10, cfg-csr 7, cfg-pmp 1, D2? 1, rerun-ok 2 |
| B/Zkn (`gen_bk_traces.py`, 300 traces x 54 insns, 7200 B/K ops) | 300 | 0 | |

Every saved failure falls into one of the classes below; none is unexplained.
D2? and rerun-ok are heuristic (see the class descriptions).

### Real DUT bugs (fixed in Flute d9cc5c4; minimal counterexamples in `testrig/divergences/`)

* **D1, store access fault lost**: `d1_vacant_store_no_fault.S`, `sw x0, -16(x0)`.
  * A store or AMO to a vacant physical address completes with no exception
    (Sail: mcause 7). Loads to the same address do fault.
  * MMU_Cache's write-through/IO store path never turns the AXI write
    error (SLVERR) into a precise trap.
  * Shown by every store to the vacant top line in compressed, random and
    unstructured.
* **D2, stale D-cache data after a misaligned trap**:
  `d2_stale_load_after_misaligned_trap.S` (6 insns).
  * After a misaligned load or store exception, the first load that hits in
    the D-cache returns the previous BRAM read's cword instead of the
    addressed data.
  * The misaligned access can be to any address. ECALL does not trigger it.
  * With FENCE.I in between, a later load miss is also wrong:
    `d2b_stale_load_after_misaligned_trap_fencei.S` (9 insns,
    delta-debugged from a `cache` failure). The memory trace shows the
    correct data on the fabric.
  * Suspected cause: `MMU_Cache.req` takes the `MODULE_EXCEPTION_RSP` path
    without `fa_req_ram_B`, and the registered BRAM output
    (`rg_tag_ram_q`/`rg_data_ram_q`, a +1-cycle timing change; first in
    Flute 4c2bdc5 per `git log -S rg_tag_ram_q`) is then consumed stale.
  * No D2-classified failure was triggered by an access fault on the vacant
    line. Sail reports mem_addr for those, and none of the 178 triggers
    carries one, so the triggers are the misaligned traps.
  * It also reproduces with `RAM8M=1` (Sail's default 8 MiB map).
  * The D-side RTL has no RVFI-conditional code. The only `RVFI` ifdef in
    `Near_Mem_VM_WT_L1` selects the formal-only tiny cache geometry, which
    the DII build does not use.
  * This is the main source of failures in mem/cache/fencei/atomic/memAmo/random.
  * D2 means the wrong load immediately follows a trapped load/store. D2?
    means a trapped load/store occurred earlier in the test (the D2b form).
  * rerun-ok means the failure did not recur on QCVEngine's re-run. This is
    consistent with D2's state, which is not reset between tests, but it is
    not proven.
* **D3, PMP CSR decode too wide**: `d3_reserved_csr_0x380_decoded_as_pmp.S`,
  `csrrs x1, 0x380, x0`.
  * CSRs 0x380-0x39F and 0x3F0-0x3FF are accepted (read 0) instead of
    raising illegal-instruction.
  * `PMP.bsv` `fv_is_pmp_csr` matches `a[11:6] == 6'b00111x`, i.e.
    0x380-0x3FF.

### After the fixes (campaign `build/testrig-runs/campaign4`, Flute d9cc5c4)

All four counterexamples (d1, d2, d2b, d3) pass.  12 generators x 200
sequences (arith control muldiv mem cache fencei atomic memAmo compressed csr
random all):

| generator | failing | classification |
|---|---|---|
| arith, control, muldiv, mem, cache, fencei, compressed, random | 0 | |
| atomic | 72 | SC-allowed 68, SC-trap 1, rerun-ok 3 |
| memAmo | 4 | SC-allowed 3, SC-trap 1 |
| csr | 67 | cfg-pmp 48, cfg-csr 13, cfg-debug 6 |
| all | 20 | SC-allowed 9, SC-trap 3, cfg-pmp 3, cfg-csr 3, rerun-ok 2 |

No D1/D2/D3 remain.  The classifier now checks SC outcomes before the D2
stale-load rule (SCs were being labelled D2), and:

* `SC-allowed` covers any load/store/AMO/FENCE/SYSTEM between the LR and the
  SC (the constrained-loop rules of unpriv "Eventual Success"), e.g. a load
  that evicts the reserved line in the direct-mapped D-cache.
* `SC-trap`: Sail fails the SC, Flute succeeds, with a trap in between.  Sail
  cancels the reservation on every trap; the ISA does not require that.
  Matching Sail would need a trap signal from the CPU into MMU_Cache.
* The 5 `rerun-ok` all contain LR/SC and did not reproduce on the
  per-failure re-run; not explained yet.

### Configuration / reference differences (not DUT bugs)

* **cfg-pmp**: pmpcfg4-15 and pmpaddr16-63. QCVEngine calls these
  "reserved", so the regex cannot exclude them.
  * With 16 entries, Sail traps on pmpaddr16-63. Per spec they exist (WARL 0),
    as in Flute.
  * Sail also implements pmpcfg4-15 state that Flute's 8-entry PMP does not.
* **cfg-debug**: tdata2/tdata3 (0x7A2-0x7A3) and dcsr/dpc (0x7B0-0x7B1).
  * Flute (`INCLUDE_GDB_CONTROL`) exposes trigger/debug CSRs in M-mode.
  * Sail has none.
  * Strictly, debug-spec dcsr/dpc should be Debug-Mode-only. That is a
    minor deviation, noted here rather than counted as a bug.
* **cfg-csr**: misa (the Sail model sets V and clears B), V CSRs
  (0x008-0x00F), menvcfg/senvcfg (priv 1.12, Flute is 1.11),
  sedeleg/sideleg (Flute keeps the legacy N-extension CSRs), mip, counters,
  and HPM CSRs hit by `unstructured`.
* **SC-allowed**: an SC succeeds in Sail and fails in Flute after a
  store/AMO, FENCE.I or SFENCE.VMA by the same hart between the LR and the
  SC. The ISA allows the SC to fail there, because only constrained LR/SC
  loops must succeed.
* **Sail crash**: in `unstructured`, Sail aborts with
  `Assertion failed: model/riscv_fdext_regs.sail:230` on an FP-opcode word
  (e.g. 0xa1f8cb53, OP-FP funct7 0x50 with a reserved funct3) when F/D are
  disabled (`-F`). This is a reference-model bug: the encoding should be
  illegal. QCVEngine then spins ("Gave up!") until killed, so unstructured
  runs in chunks under `timeout`.

### Harness artifacts found and fixed

* RVC HINT rd reporting.
* riscv-formal aligned memory fields converted to byte address + data.
* GPR/CSR reset values.
* mtvec reset.
* Sail RAM size and the vacant top line.
* Sail LR/SC reservation surviving the per-test reset.
* Sail RVFI-DII fetch missing the PMP check.
* `rvfi_insn` upper half for RVC.
* Run script fixes:
  * LOGDIR and `-t`/`-d` paths made absolute.
  * `--no-save` dropped when `-s` is given.
  * Port collisions between parallel runs.

### Notes / limits

* `pte`: QCVEngine's PTE template is written for RV64/Sv39. On RV32 its
  `sd` page-table stores are illegal, so it mainly exercises satp writes,
  SFENCE.VMA, SRET to U-mode and U-mode fetch under PMP. It does not give
  meaningful Sv32 walk coverage.
* QCVEngine has no B or Zk* templates (`RV32_B.hs` is disassembly only).
  `gen_bk_traces.py` covers:
  * Zba/Zbb/Zbc/Zbs/Zbkb/Zbkx/Zkne/Zknd/Zknh.
  * Encodings checked with `spike-dasm`.
  * Zkr's `seed` CSR is not covered (its values are random).
* The I-side RAM returns zeros (the bits come from the trace), so the
  PC = 2 mod 4 straddle approximation (see Harness) is not exercised
  against real memory contents.

## F/D (FP=1 builds)

    make -C testrig OUT=$PWD/build/testrig-dii-fpt \
        EXTRA_DEFINES="-D ISA_F -D ISA_D -D INCLUDE_FDIV -D INCLUDE_FSQRT -D FPU_TRIM"
    ARCH=rv32imafdcs_zicsr_zifencei DUT=$PWD/build/testrig-dii-fpt/Flute_RVFI_DII \
        SAIL_FLAGS="-I -i --pmp-count 16 --pmp-grain 10" \
        testrig/run_campaign.sh build/testrig-runs/camp-fp 200 float double all

Sail runs with F/D (no `-F`).  QCVEngine needs `qcv-rv32d-prologue.patch`: its
FP prologue clears f16-f20 with `fmv.d.x`, which is RV64-only and traps on
RV32, so those registers carry the previous test's values on the DUT (Sail
resets them per test) and every later use of them diverges.  The patch uses
`fcvt.d.w fN, x0` on RV32.  With it: float 200/200, double 200/200 (2026-10-23).
