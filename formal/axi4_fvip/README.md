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
