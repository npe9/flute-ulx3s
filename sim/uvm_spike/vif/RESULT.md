# vif — result: WORKS (virtual interfaces + class pin agents + DPI bridge)

Probe: `tb_vif.sv` + `probe_main.cpp` — the exact J1 shape:

- `board_uart_if` interface with `clk` / `ftdi_txd` (agent-driven) /
  `ftdi_rxd` (agent-monitored), mirroring the sim_board pin names.
- Driver and monitor CLASSES hold `virtual board_uart_if` handles
  (passed via constructor from the module's initial block), maintain
  per-cycle state, and are ticked from `always @(posedge clk)` — no
  timing controls inside class code, pure `--no-timing` operation.
- A toy DUT (registered shift loopback) stands in for sim_board.
- DPI-C export functions (`sv_inject_byte`, `sv_injected_count`,
  `sv_mon_sample`, `sv_drv_pending`) give the C++ main a byte-level
  API into the SV agents. C++ must call
  `svSetScope(svGetScopeFromName("TOP.tb_top"))` once after the first
  `eval()` (IEEE 1800-2023 35.5.3) — without it the run aborts with
  "scope wasn't set".

Evidence (`run.log`):

```
[sv] inject byte 0xa5 at time 10
[cpp] driver bits pending after 1st byte + 20 cy: 0
[sv] inject byte 0x3c at time 50
[cpp] injected=2 pending=0 mon_sample=0xff
VIF+DPI: PASS
```

Constraints discovered:
- **NBA (`<=`) to an interface signal from a class function is
  rejected under `--no-timing`** (`NOTIMING: Delayed assignment in a
  non-inlined function/task requires --timing`). Use blocking assigns
  inside agent `tick()` and manage DUT sampling order by ticking
  agents on the opposite clock edge from the DUT's own always blocks.
- DPI exports are plain C functions on the generated model — cheap
  and reliable; the alternative (driving pins directly from C++ like
  F1's tb_top.cpp) also works and remains the right choice for the
  raw clock/reset/args plumbing.
