# riscv-formal smoke gate for Flute

Bounded model checking of `mkCPU` (the real CPU: caches, fetch shim, predictor,
debug module) against the RISC-V ISA with [riscv-formal](https://github.com/YosysHQ/riscv-formal),
to be run **before** a 40-minute P&R / 40-minute J1 sim.

    formal/run.sh            # THE GATE: build + smoke set (insn x8, causal, unique), ~4 min, run before every FPGA build
    formal/run.sh deep       # pc_fwd + reg at depth 75: pc_fwd ~2 h (PASS on E8d); reg proves 0-74 then
                             # stalls >10 h on step 75 -- use REG_DEPTH=74 for a run that finishes
    formal/run.sh cover      # find the first-retirement depth after a geometry change
    formal/run.sh insn_lw_ch0 pc_fwd_ch0    # individual checks

Results: `~/src/riscv-formal/cores/flute/checks/<check>/{status,logfile.txt}`;
a FAIL leaves `engine_0/trace.vcd` (open with gtkwave, or `build/timing-exp/vcd_probe.py`).

## How it is wired

* `make formal-verilog` compiles `mkCPU` with `-D RVFI` into `build/formal/` (own bsc
  tree; never touches `build/bsc`).  `RVFI` enables, in the BSV sources:
  * the RVFI retirement record (`CPU.bsv`: `fa_rvfi`, written at every retirement
    site: the 2->3 move for pipe ops, traps, CSRRx, xRET, FENCE/FENCE.I/SFENCE.VMA,
    WFI; interrupts only mark the next retirement `rvfi_intr`), carried through
    `Data_Stage1_to_Stage2` / `Data_Stage2_to_Stage3` (operands after bypass,
    resolved next pc, aligned-mem load/store lanes),
  * tiny geometry so the reset loops fit a BMC bound: 1 KB 1-way caches
    (`Cache_Decls_RV32_1KB_1way`, 16 sets) and a 16-entry BTB.
  Production builds (RVFI undefined) are unaffected -- check with
  `diff build/verilog/mkCPU.v` against the previous netlist after touching the ifdefs.
* `gen_wrapper.py` regenerates `wrapper.sv` from the generated `mkCPU.v` port list:
  one `axi_formal_slave` per AXI master port (unconstrained read data, OKAY
  responses, optional stalls via `FLUTE_AXI_STALL`), DMA port idle, debug servers
  drained, interrupts off, one `hart0_server_reset` request after reset.
* `checks.cfg.in` -> `checks.cfg` (depths and BSC library paths filled by `run.sh`).

## Conventions and limits

* `RISCV_FORMAL_ALIGNED_MEM`: `rvfi_mem_addr` is the 4-byte-aligned address; masks and
  data are byte lanes within that word.  AMO `mem_wdata` is the rs2 value, not the
  AMO result (riscv-formal has no AMO checks; `isa rv32imc`).
* Compressed instructions report the 16-bit word in `rvfi_insn[15:0]`.
* `rvfi_halt` is never set; `liveness` needs fairness assumptions on the AXI slave
  and is not in the smoke set.
* BMC with symbolic memory finds pipeline-consistency bugs (wrong-path leaks, lost
  writes, wrong operands) within the bound; it does not replace the hardware cache
  test, which needs a specific long program.
