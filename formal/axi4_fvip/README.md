# YosysHQ SVA AXI4 FVIP (vendored)

- **Upstream:** https://github.com/YosysHQ-GmbH/SVA-AXI4-FVIP, commit `250f1ff`. The `AXI4/src` tree is flattened here and **unmodified**. ISC license, see `COPYING`.
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
