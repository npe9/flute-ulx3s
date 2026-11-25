# G0117 action shadowing in the SoC (2026-11-25)

`BSC_FLAGS` has `-no-warn-action-shadowing`, which hides bsc warning G0117: two rules (or a method and a rule)
fire in the same clock and write the same register, and the later one in the execution order wins, so the
other write is lost that clock.  The hardware and the proofs are unchanged by the flag (the proofs check the
Verilog); this file lists what it hides, so each case can be recorded as intended or fixed.

How it was made: bsc 2025.01 (a798d8a9), the Makefile's `BSC_FLAGS` without `-no-warn-action-shadowing`,
`make compile SOC=game2d BUILD=build/g0117-game2d` (and `SOC=linux`), then
`python3 scripts/g0117_report.py build/g0117-game2d/elaboration.log`.  game2d and linux give the same 141
groups; linux has 2 more warnings (fabric rd_resp copies for SPI2 / UART1).

Reading of group C (rule over rule), the ones worth a decision:
- PLIC `m_rl_process_rd_req` over `interrupt_req` (16, every source's ip): the claim's indexed write to the
  ip vector shadows every source's set that clock.  Harmless: `m_interrupt_req` is always_enabled and takes the source's
  level every clock (PLIC.bsv:545), so a set lost in the claim's clock is taken the next one.
- PLIC `m_rl_process_wr_req` over `m_rl_process_rd_req` on source_busy: a completion write in the claim's clock.
- SoC_Info `rl_wr` over `note_err`: BUSERR_CLEAR wins over a same-clock error.  Intended, and proved
  (formal/fv soc_info).
- CLINT `rl_wr_apply` over `rl_mtip`: a timecmp write recomputes mtip itself.  Intended.
- MBox `rl_mul_sum` over `rl_capture` on rg_word: a multiply and a divide result in one clock; one op at a
  time, so not reachable unless the MBox protocol is broken.
- Debug module (DM_Run_Control, DM_System_Bus): `rl_sb_write_response` over the DM `reset` / a `write` of
  sbcs: a system-bus error lands over a same-clock clear.  Debug-only.
Group A (reset / flush wins) is intended by construction.  Group B (a method call wins over the module's own
rule) is each module's interface contract: e.g. MMU_Cache `req` over every FSM rule's rg_state is the E8 /
RLD-4 contract that formal/fv mmu_cache's environment assumes (req only the first clock mv_busy is low).

190 warnings in 141 groups (numbered copies of one rule folded to N).

### C. One internal rule wins over another (10 groups)

| n | where | wins | loses | registers |
|---|---|---|---|---|
| 1 | Flute/src_Core/Near_Mem_IO/Near_Mem_IO_AXI4.bsv:103 | `rl_wr_apply` | `rl_mtip` | rg_mtip |
| 1 | Flute/src_Core/PLIC/PLIC_16_2_7.bsv:36 | `m_rl_process_wr_req` | `m_rl_process_rd_req` | m_vrg_source_busy_N |
| 16 | Flute/src_Core/PLIC/PLIC_16_2_7.bsv:36 | `m_rl_process_rd_req` | `v_sources_N_m_interrupt_req` | m_vrg_source_ip_N |
| 1 | src/SoC_Info.bsv:102 | `rl_wr` | `note_err` | rg_err_count, rg_err_valid |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `rl_hartN_run_rsp` | `rl_hartN_reset_rsp` | rg_hartN_running |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `rl_hartN_run_rsp` | `write` | rg_dmstatus_allresumeack |
| 1 | Flute/src_Core/Debug_Module/DM_System_Bus.bsv:176 | `rl_sb_write_response` | `reset` | rg_sbcs_sberror |
| 1 | Flute/src_Core/Debug_Module/DM_System_Bus.bsv:176 | `rl_sb_write_response` | `rl_sb_read_finish` | rg_sbcs_sberror |
| 1 | Flute/src_Core/Debug_Module/DM_System_Bus.bsv:176 | `rl_sb_write_response` | `write` | rg_sbcs_sberror |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `rl_mul_sum` | `rl_capture` | rg_word |

### B. A method (the caller) wins over an internal rule (51 groups)

| n | where | wins | loses | registers |
|---|---|---|---|---|
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `write` | `rl_gpr_read_start` | rg_start_reg_access |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `write` | `rl_gpr_write_start` | rg_start_reg_access |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `write` | `rl_csr_read_start` | rg_start_reg_access |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `write` | `rl_csr_write_start` | rg_start_reg_access |
| 1 | Flute/src_Core/CPU/RISCV_XBox.bsv:578 | `req` | `rl_finish` | rg_state |
| 1 | Flute/src_Core/CPU/RISCV_XBox.bsv:578 | `req` | `rl_aes_so` | rg_state |
| 1 | Flute/src_Core/CPU/RISCV_XBox.bsv:578 | `req` | `rl_compute` | rg_state |
| 1 | Flute/src_Core/RegFiles/CSR_MIP.bsv:71 | `timer_interrupt_req` | `reset` | rg_mtip |
| 1 | Flute/src_Core/RegFiles/CSR_MIP.bsv:71 | `software_interrupt_req` | `reset` | rg_msip |
| 1 | Flute/src_Core/RegFiles/CSR_MIP.bsv:71 | `s_external_interrupt_req` | `reset` | rg_seip |
| 1 | Flute/src_Core/RegFiles/CSR_MIP.bsv:71 | `s_external_interrupt_req` | `mav_write` | rg_seip |
| 1 | Flute/src_Core/RegFiles/CSR_MIP.bsv:71 | `m_external_interrupt_req` | `reset` | rg_meip |
| 1 | Flute/src_Core/RegFiles/CSR_MIP.bsv:71 | `mav_write` | `mav_sip_write` | rg_ssip, rg_ueip, rg_usip |
| 1 | Flute/src_Core/RegFiles/CSR_MIE.bsv:59 | `mav_write` | `reset` | rg_mie |
| 1 | Flute/src_Core/RegFiles/CSR_MIE.bsv:59 | `mav_write` | `mav_sie_write` | rg_mie |
| 1 | Flute/src_Core/RegFiles/CSR_RegFile_MSU.bsv:318 | `mav_csr_write` | `write_dpc` | rg_dpc |
| 1 | Flute/src_Core/CPU/IntMulDiv.bsv:176 | `put_args` | `m_compute` | m_rg_state, m_rg_x, m_rg_xy, m_rg_y |
| 1 | Flute/src_Core/CPU/IntMulDiv.bsv:182 | `put_args` | `m_compute` | m_rg_state, m_rg_x, m_rg_xy, m_rg_y |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `req` | `intDiv_rl_loopN` | intDiv_rg_state, rg_vN |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `req` | `intDiv_rl_loopN` | intDiv_rg_state |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `req` | `intDiv_rl_start_s` | intDiv_rg_state, rg_vN |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `req` | `intDiv_rl_start_overflow` | intDiv_rg_state, rg_vN |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `req` | `intDiv_rl_start_div_by_zero` | intDiv_rg_state |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `req` | `rl_mul_sum` | rg_state, rg_valid |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `req` | `rl_capture` | rg_valid |
| 1 | Flute/src_Core/CPU/RISCV_MBox.bsv:57 | `req` | `rl_mul` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_start_reset` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `ma_kill_echo` | rg_kill_echo |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_io_amo_write` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_io_AMO_read_rsp` | rg_exc_code, rg_st_amo_val, rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_io_AMO_op_req` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_io_AMO_SC_req` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_io_write_rsp` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_io_write_req` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_io_read_rsp` | rg_exc_code, rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_io_read_req` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_kill_echo_exit` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_amo_write` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_amo_exec` | rg_st_amo_val, rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_cache_refill_rsps_loop` | rg_exc_code, rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_start_cache_refill` | rg_state |
| 2 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_ptw_level_N` | rg_exc_code, rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_start_tlb_refill` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_ptw_send` | rg_exc_code, rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_ptw_chk` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_udtlb_fillN` | rg_exc_code, rg_pa, rg_state, rg_udtlb_bypass |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_udtlb_fillp` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_udtlb_fill` | rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_probe_and_immed_rsp` | rg_pa, rg_state |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv:519 | `req` | `rl_reset` | rg_state |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `set_verbosity` | `hartN_put_other_req_put` | cfg_verbosity |

### A. A reset / flush / start rule wins over normal work (80 groups)

| n | where | wins | loses | registers |
|---|---|---|---|---|
| 11 | Flute/src_Testbench/SoC/SoC_Fabric.bsv:37 | `fabric_rl_reset` | `fabric_rl_rd_resp_slave_to_master_N` | fabric_v_rg_r_beat_count_N |
| 1 | Flute/src_Testbench/SoC/SoC_Fabric.bsv:37 | `fabric_rl_reset` | `fabric_rl_rd_resp_slave_to_master` | fabric_v_rg_r_beat_count_N |
| 2 | Flute/src_Testbench/SoC/SoC_Fabric.bsv:37 | `fabric_rl_reset` | `fabric_rl_wr_xaction_master_to_slave_data_N` | fabric_v_rg_wd_beat_count_N |
| 1 | Flute/src_Testbench/SoC/SoC_Fabric.bsv:37 | `fabric_rl_reset` | `fabric_rl_wr_xaction_master_to_slave_data` | fabric_v_rg_wd_beat_count_N |
| 3 | Flute/src_Testbench/SoC/SoC_Fabric.bsv:98 | `fabric_rl_reset` | `fabric_rl_rd_resp_slave_to_master_N` | fabric_v_rg_r_beat_count_N |
| 1 | Flute/src_Testbench/SoC/SoC_Fabric.bsv:98 | `fabric_rl_reset` | `fabric_rl_rd_resp_slave_to_master` | fabric_v_rg_r_beat_count_N |
| 1 | Flute/src_Testbench/SoC/SoC_Fabric.bsv:98 | `fabric_rl_reset` | `fabric_rl_wr_xaction_master_to_slave_data` | fabric_v_rg_wd_beat_count_N |
| 1 | Flute/src_Testbench/SoC/Boot_ROM.bsv:82 | `reset` | `rl_process_rd_req` | rg_rd_v |
| 1 | Flute/src_Testbench/SoC/Mem_Controller.bsv:198 | `rl_external_reset` | `rl_merge_wr_beat` | rg_wr_left |
| 1 | Flute/src_Testbench/SoC/Mem_Controller.bsv:198 | `rl_external_reset` | `rl_merge_wr_req` | rg_wr_left |
| 1 | Flute/src_Testbench/SoC/Mem_Controller.bsv:198 | `rl_external_reset` | `rl_invalid_rd_address` | rg_err_beat |
| 1 | Flute/src_Testbench/SoC/Mem_Controller.bsv:198 | `rl_external_reset` | `rl_rd_stream` | rg_ck, rg_fwd |
| 1 | Flute/src_Testbench/SoC/Mem_Controller.bsv:198 | `rl_external_reset` | `rl_rd_issue` | rg_seg_on |
| 1 | Flute/src_Testbench/SoC/Mem_Controller.bsv:198 | `rl_external_reset` | `rl_wr` | rg_buf_dirty |
| 1 | Flute/src_Testbench/SoC/UART_Model.bsv:190 | `rl_reset` | `rl_receive` | rg_lsr |
| 1 | Flute/src_Testbench/SoC/UART_Model.bsv:190 | `rl_reset` | `rl_process_wr_req` | rg_dll, rg_dlm, rg_fcr, rg_ier, rg_lcr, rg_mcr, rg_scr |
| 1 | Flute/src_Testbench/SoC/UART_Model.bsv:190 | `rl_reset` | `rl_process_rd_req` | rg_lsr |
| 5 | Flute/src_Core/Core/Fabric_2x3.bsv:60 | `fabric_rl_reset` | `fabric_rl_rd_resp_slave_to_master_N` | fabric_v_rg_r_beat_count_N |
| 1 | Flute/src_Core/Core/Fabric_2x3.bsv:60 | `fabric_rl_reset` | `fabric_rl_rd_resp_slave_to_master` | fabric_v_rg_r_beat_count_N |
| 1 | Flute/src_Core/Core/Fabric_2x3.bsv:60 | `fabric_rl_reset` | `fabric_rl_wr_xaction_master_to_slave_data_N` | fabric_v_rg_wd_beat_count_N |
| 1 | Flute/src_Core/Core/Fabric_2x3.bsv:60 | `fabric_rl_reset` | `fabric_rl_wr_xaction_master_to_slave_data` | fabric_v_rg_wd_beat_count_N |
| 1 | Flute/src_Core/Near_Mem_IO/Near_Mem_IO_AXI4.bsv:103 | `rl_reset` | `rl_mtip_edge` | rg_mtip_prev |
| 16 | Flute/src_Core/PLIC/PLIC_16_2_7.bsv:36 | `m_rl_reset` | `v_sources_N_m_interrupt_req` | m_vrg_source_ip_N |
| 1 | src/AXI4_RegBus.bsv:67 | `reset` | `rl_rd_start` | rg_state |
| 1 | src/AXI4_RegBus.bsv:67 | `reset` | `rl_wr_start` | rg_state |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `reset` | `rl_hartN_run_rsp` | rg_dmstatus_allresumeack, rg_hartN_running |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `reset` | `rl_ndm_reset_rsp` | rg_hartN_running |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `reset` | `rl_hartN_reset_rsp` | rg_hartN_running |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `reset` | `write` | rg_dmcontrol_dmactive, rg_dmcontrol_haltreq, rg_dmcontrol_hartreset, rg_dmcontrol_ndmreset, rg_dmstatus_allunavail, rg_hartN_hasreset |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `rl_ndm_reset_rsp` | `rl_hartN_reset_rsp` | rg_hartN_running |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `rl_ndm_reset_rsp` | `write` | rg_dmstatus_allunavail |
| 1 | Flute/src_Core/Debug_Module/DM_Run_Control.bsv:55 | `rl_hartN_reset_rsp` | `write` | rg_hartN_hasreset |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `reset` | `rl_unknown_read_start` | rg_abstractcs_cmderr |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `reset` | `rl_unknown_write_start` | rg_abstractcs_cmderr |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `reset` | `rl_gpr_read_finish` | rg_abstractcs_cmderr, rg_dataN |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `reset` | `write` | rg_abstractcs_busy, rg_abstractcs_cmderr, rg_command_access_reg_regno, rg_command_access_reg_write, rg_dataN, rg_start_reg_access |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `reset` | `rl_gpr_write_finish` | rg_abstractcs_cmderr |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `reset` | `rl_csr_read_finish` | rg_abstractcs_cmderr, rg_dataN |
| 1 | Flute/src_Core/Debug_Module/DM_Abstract_Commands.bsv:52 | `reset` | `rl_csr_write_finish` | rg_abstractcs_cmderr |
| 1 | Flute/src_Core/Debug_Module/DM_System_Bus.bsv:176 | `reset` | `rl_sb_read_finish` | rg_sbcs_sberror, rg_sbdataN |
| 1 | Flute/src_Core/Debug_Module/DM_System_Bus.bsv:176 | `reset` | `write` | rg_sb_state, rg_sbaddressN, rg_sbcs_sbaccess, rg_sbcs_sbautoincrement, rg_sbcs_sbbusyerror, rg_sbcs_sberror, rg_sbcs_sbreadonaddr, rg_sbcs_sbreadondata, rg_sbdataN |
| 1 | Flute/src_Core/Debug_Module/DM_System_Bus.bsv:176 | `reset` | `av_read` | rg_sb_state, rg_sbaddressN, rg_sbcs_sbbusyerror |
| 1 | Flute/src_Core/RegFiles/GPR_RegFile.bsv:73 | `server_reset_request_put` | `rl_reset_loop` | rg_state |
| 1 | Flute/src_Core/RegFiles/GPR_RegFile.bsv:73 | `server_reset_request_put` | `rl_reset_start` | rg_state |
| 1 | Flute/src_Core/CPU/Branch_Predictor.bsv:203 | `reset` | `rl_reset` | rg_index, rg_resetting |
| 1 | Flute/src_Core/RegFiles/CSR_MIP.bsv:71 | `reset` | `mav_write` | rg_seip, rg_ssip, rg_stip, rg_ueip, rg_usip, rg_utip |
| 1 | Flute/src_Core/RegFiles/CSR_MIP.bsv:71 | `reset` | `mav_sip_write` | rg_ssip, rg_ueip, rg_usip |
| 1 | Flute/src_Core/RegFiles/CSR_MIE.bsv:59 | `reset` | `mav_sie_write` | rg_mie |
| 1 | Flute/src_Core/RegFiles/CSR_RegFile_MSU.bsv:318 | `server_reset_request_put` | `rl_reset_start` | rg_state |
| 1 | Flute/src_Core/RegFiles/CSR_RegFile_MSU.bsv:318 | `rl_reset_start` | `csr_ret_actions` | csr_mstatus_rg_mstatus |
| 1 | Flute/src_Core/RegFiles/CSR_RegFile_MSU.bsv:318 | `rl_reset_start` | `csr_trap_actions` | csr_mstatus_rg_mstatus, rg_mcause, rg_scause |
| 1 | Flute/src_Core/RegFiles/CSR_RegFile_MSU.bsv:318 | `rl_reset_start` | `write_dcsr_cause_priv` | rg_dcsr |
| 1 | Flute/src_Core/RegFiles/CSR_RegFile_MSU.bsv:318 | `rl_reset_start` | `write_dpc` | rg_dpc |
| 1 | Flute/src_Core/RegFiles/CSR_RegFile_MSU.bsv:318 | `rl_reset_start` | `nmi_req` | rg_nmi |
| 1 | Flute/src_Core/Near_Mem_VM_WT_L1/TLB.bsv:153 | `flush` | `rl_initialize` | rg_flushing |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_debug_run_restart` | stageF_rg_epoch, stageF_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_trap_fetch` | stageF_rg_epoch, stageF_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_finish_SFENCE_VMA` | stageF_rg_epoch, stageF_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_WFI_resume` | stageF_rg_epoch, stageF_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_finish_FENCE` | stageF_rg_epoch, stageF_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_finish_FENCE_I` | stageF_rg_epoch, stageF_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_stageN_restart_after_csrrx` | stageF_rg_epoch, stageF_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_reset_complete` | stageF_rg_epoch, stageF_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageF_rl_reset` | `rl_front` | stageF_rg_epoch |
| 2 | Flute/src_Core/CPU/CPU.bsv:175 | `stageN_rl_reset` | `rl_pipe` | stageN_rg_full |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageN_rl_reset_begin` | `stageN_rl_reset_end` | stageN_rg_resetting |
| 1 | Flute/src_Core/CPU/CPU.bsv:175 | `stageN_rl_reset_begin` | `rl_pipe` | stageN_rg_full |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:737 | `m_rl_reset` | `m_rl_rd_resp_slave_to_master` | m_rg_r_beat_count |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:737 | `m_rl_reset` | `m_rl_rd_xaction_master_to_slave` | m_rg_ar_beat_count |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:737 | `m_rl_reset` | `m_rl_wr_resp_slave_to_master` | m_rg_b_beat_count, m_rg_b_resp |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:737 | `m_rl_reset` | `m_rl_wr_xaction_master_to_slave` | m_rg_w_beat_count |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_ndm_reset_settle` | `rl_periph_reset` | rg_periph_reset |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_ndm_reset_settle` | `rl_accelN_reset` | rg_accelN_reset |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_ndm_reset_settle` | `rl_fabric_reset` | rg_fabric_reset |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_ndm_reset_start` | `rl_periph_reset` | rg_periph_reset |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_ndm_reset_start` | `rl_accelN_reset` | rg_accelN_reset |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_ndm_reset_start` | `rl_fabric_reset` | rg_fabric_reset |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_reset_start_initial` | `rl_periph_reset` | rg_periph_reset |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_reset_start_initial` | `rl_accelN_reset` | rg_accelN_reset |
| 1 | Flute/src_Testbench/SoC/SoC_Top.bsv:190 | `rl_reset_start_initial` | `rl_fabric_reset` | rg_fabric_reset |

