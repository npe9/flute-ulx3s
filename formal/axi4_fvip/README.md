# YosysHQ SVA AXI4 FVIP (vendored)

- **Upstream:** https://github.com/YosysHQ-GmbH/SVA-AXI4-FVIP, commit `250f1ff`. The `AXI4/src` tree is flattened here and **unmodified**. ISC license, see `COPYING`.
- **Fork:** https://github.com/npe9/SVA-AXI4-FVIP branch `flute-ulx3s` carries these harnesses as `AXI4/examples/flute_ulx3s` (run with `RTL=build/<variant>/verilog`).
- **Tool:** the SVA yosys at `~/src/sv-yosys/third_party/yosys/build/yosys`, fork `npe9/yosys` branch `sva-frontend-ic3`, at `03cc3a9f4` or later. Builds before that zero struct parameter overrides, which gives false proofs. Stock yosys silently drops `bind`.

## Flow
```
read_verilog -sv -formal <pkg + checker files> <dut>
hierarchy -check -top <top>
sva2check
proc
async2sync
flatten
opt_clean
memory
opt_clean
setundef -init -zero
dffunmap
write_smt2 -wires
```
Then run `yosys-smtbmc --keep-going`.

## Configuration rules
These were learned from the axi_crossbar oracle run on 2026-10-21. The results are in the campaign memory.
- **`MAX_WR_BURSTS` / `MAX_RD_BURSTS` ≥ 2.** At 1, the source-side `cp_no_overflow_no_dead_end` reduces to `!AWVALID`. That assumption covers a DUT output, so the whole write path is checked vacuously.
- **`MAXWAIT` ≤ 15.** Larger values are approximate in sva2check. On a pass-through block, set the far side's MAXWAIT shorter than the near side's by the block's latency, otherwise the bounds do not compose.
- **Covers.** `cover property` is not yet checked. Add explicit AxVALID reachability checks until it is.
- **`ENABLE_XPROP=0`.** `$isunknown` is constant 0 in a two-state flow.

## Results (2026-10-21, sv-yosys >= eab0ee5c5)
| Harness | Asserts | Environment assumptions | Result |
|---|---|---|---|
| `mem_ctrl/` Mem_Controller slave | 15 (DESTINATION) | EN only when RDY; no `server_reset` after boot; at most 4 outstanding writes | No failure through step 13 (BMC slows sharply after step 11). All 8 witnesses reached: OKAY/SLVERR B and R, 4 outstanding writes. |
| `deburster/` AXI4_Deburster | 74 (DESTINATION upstream, bursts ≤ 256; SOURCE downstream, single beat) | no AxLOCK; at most 4 outstanding write bursts; downstream answers in order | No failure through step 14. All 6 witnesses reached, including multi-beat upstream bursts. |

Findings:
- **Mem_Controller:** a mid-traffic `server_reset` drops BVALID/RVALID before the handshake (`ap_B_BVALID_until_BREADY` / `ap_R_RVALID_until_RREADY` at step 6). Reset is boot-only in this SoC.
- **AXI4_Deburster:** `rl_wr_resp_slave_to_master` matches downstream B responses by position (`f_w_awlen`) and forwards the last beat's BID. A slave that reorders across IDs, which is legal AXI, makes it return a wrong BID and then a duplicate upstream (`ap_data_integrity_out_of_order` at step 10). This is latent here because Boot_ROM and Mem_Controller answer in order. The read path depends on the same ordering.
- **FVIP DESTINATION scoreboard:** `ap_no_overflow` asserts over AWVALID, which the environment drives. A standalone destination check therefore needs the source-side bound added explicitly.

### Harness modes (2026-10-25, m5 RTL, `SOLVER=bitwuzla`)
`mem_ctrl/run.sh [depth] [REACH]` takes `DEFS=` (extra defines), `TAGX=` (build-file suffix, so runs
can share the directory) and `SOLVER=` (default yices; yices stalls past step 11 on m5).

| Mode | Adds | Result |
|---|---|---|
| base | `ap_owed_le8`: the controller never owes raw memory more than 8 chunks | No failure through step 13 (`run.sh 14`). |
| `DEFS=-DLIVE` | Bounded liveness: with a prompt environment (raw memory and RREADY/BREADY never wait), a read in flight gets an R beat, and a write whose AW and last W are in gets its B, within 12 cycles (`LIVE_K`, `LIVE_RAW_W`, `LIVE_RDY_W` override) | No failure through step 15. Non-vacuity: `LIVE_K=6` fails `ap_live_b` (step 10), `LIVE_K=3` fails both (step 7). |
| `DEFS=-DDATA` | Data integrity for one symbolic word X with symbolic initial content. Raw memory is storage for X; an OKAY R beat for X must equal the last W data written to X, unless a write to X overlapped the read. Also R/B response = SLVERR exactly for bad bursts. | No failure through step 15. `reach_data_x` and `reach_data_wb` (read served from raw memory after a writeback of X) reached at step 13. Mutants fail: RDATA bit 0 flipped (step 8), writeback with all byte enables (step 11). |
| `build_small.sh` + `DEFS=-DMC_SMALL` | Formal-only build: idle write-back after 2 cycles, age-out after 4, `dbg_age_out` probe; witness `reach_age_wb` | BMC no failure through step 13. All 12 witnesses reached; `reach_age_wb` at step 10. |

Finding (`ap_live_r`, 2026-10-25): in the power-on reset cycle (`rg_ready` low) `rl_power_on_reset`
clears the slave transactor FIFOs while AWREADY/WREADY/ARREADY are high, so a handshake in that one
cycle is dropped. In the SoC the masters are still in reset then; the harness now makes masters
wait for `RDY_set_addr_map` (= `rg_ready`).

m6 (Flute bf32060: drain-on-reset, no power-on FIFO clear), 2026-10-25: base BMC no failure
through step 13; DATA no failure through step 15; LIVE with `-DNO_RDY_WAIT` (masters may drive in the
power-on cycle) no failure through step 15, while the same harness fails `ap_live_r` at step 15 on m5.
LIVE now also assumes the source rules W-after-AW and WLAST-on-AWLEN (without them a WLAST on beat 0
of an AWLEN=1 burst made the harness count a finished write the controller was still receiving).

ic3 (unbounded) on m5, `ic3 -check-cells -init-zero -bmc 30 -timeout 120`: 9 of 16 asserts proved
(B/R STABLE*, `ap_making_progress_bounded`), 7 undecided (B/R `*_until_*READY`,
`*_UNSUPPORTED_RESPONSE`, AW `ap_no_overflow`, `ap_data_integrity_out_of_order`, `ap_owed_le8`), 0
disproved; covers 30 of 34 reached. Do NOT add `setundef -undriven -zero` before ic3: with it the
run "proved" all 16 in 34 s with 0 of 34 covers reached (vacuous).

Harness rules learned: the DESTINATION checker does not assume WLAST on beat AWLEN (a source rule);
the DATA mode assumes it, because Mem_Controller counts beats from AWLEN. Edit run scripts only
by rename (sed -i, python write to a new file): bash reads a running script by offset.

### Unbounded results (2026-10-22, sv-yosys 5a2fc7b93, `ic3 -init-zero -bmc N -timeout T`)
- **Mem_Controller** (`rst_done = 0` harness, `ic3 -check-cells -init-zero -bmc 30 -timeout 60`, 21 min):
  - **Asserts:** 9 of 15 proved for all depths, namely the STABLE checks on B/R and `ap_making_progress_bounded`. 6 are undecided because they ran out of budget, with no counterexample: B/R `UNSUPPORTED_RESPONSE`, `BVALID_until_BREADY`, `RVALID_until_RREADY`, AW `ap_no_overflow` and `ap_data_integrity_out_of_order`. These remain bounded-only, to step 13.
  - **Covers:** 29 of 34 reached. Every handshake, OKAY/SLVERR response and last-beat cover fires.
    - Unreached, as expected: EXOKAY (EXCLUSIVE_ACCESS 0), DECERR (the controller only returns SLVERR), and AR WRAP (proved unreachable, since AxLEN = 0).
  - **Cross-check:** smtbmc -c (asserts deleted) reaches the same 29 at identical steps.
  - An earlier run with a `reg init = 1` reset generator never applied reset under `-init-zero`. It was retracted and replaced by this one.
- **AXI4_Deburster** (`rst_done = 0` harness, `ic3 -check-cells -init-zero -bmc 12 -timeout 60`, sv-yosys e318a3f48 gated build, 50 min):
  - **Covers:** 130 of 152 reached, 3 unreachable, 19 undecided. The unreachable ones are the exclusive-access covers (upstream ARLOCK EXCLUSIVE, downstream B/R EXOKAY); the harness has EXCLUSIVE_ACCESS 0. Downstream INCR/WRAP covers are absent by design: the Deburster issues every downstream beat as FIXED (AXI4_Deburster.bsv:199, :314).
  - **Asserts:** 42 of 68 proved, 0 disproved, 26 undecided (budget), bounded-only for those.
  - Identical verdict for every property to the earlier ungated-build run (221 lines, no diff).
- **Crossbar oracle** (Forencich axi_crossbar 1S:1D, `-bmc 30 -timeout 120`; scratchpad only):
  - With `MAX_WR_BURSTS 1`, 102/145 covers are reached. The whole source write path (22 AW/W/B covers) never fires, so write-side asserts in that configuration are vacuous.
  - With `MAX_WR_BURSTS 4`, 130/151 covers are reached and all 22 of those write-path covers fire.
  - Every unreachable cover matches the YosysHQ crossbar write-up or the crossbar config.
  - `yosys-smtbmc -c -t 10` reaches the same 130 covers at identical steps.
  - smtbmc's cover mode stops at the first failing assert, so with a known-failing assert it only cross-checks up to that step.
- **Rule:** with `ic3 -init-zero`, every harness register must have a zero init (write reset generators as `reg rst_done = 0`).
- **Rule:** a FVIP harness counts only if its covers are run and every write/read handshake, response and last-beat cover is reached. Use `MAX_*_BURSTS >= 2`.
