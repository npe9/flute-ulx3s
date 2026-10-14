// ================================================================
// uvm_tb_top.sv — J2 full-UVM top module (Track J).
//
// Self-contained: 25 MHz clock, reset tie-offs, the strict-BRAM board
// (sim_board), the J1 agent objects ticked on the negedge exactly as in
// the J1 harness (driver, monitor, NAK-diagnostic filter, scoreboard),
// the posedge cycle counter, UVM config_db + run_test, then the
// end-of-run gate: scoreboard verdict + coverage sampling including the
// strict-BRAM census read hierarchically (module scope keeps those
// references legal).
//
// Plusargs: +UVM_TESTNAME (default boot_hello_test), +IMAGE_HEX,
// +IMAGE_LEN, +SMOKE=1 (banner-only plumbing check), +STRICT_BRAM=
// (read by the strict BRAM2 model itself).
// ================================================================

module uvm_tb_top;

  import uvm_pkg::*;
  import uart_agent_pkg::*;
  import scoreboard_pkg::*;
  import coverage_pkg::*;
  import uvm_j2_base_pkg::*;
  import uvm_j2_agent_pkg::*;
  import uvm_j2_test_pkg::*;

  logic clk      = 1'b0;
  logic btn1     = 1'b0;
  logic jtag_tck = 1'b0;
  logic jtag_tms = 1'b0;
  logic jtag_tdi = 1'b0;

  always #20 clk = ~clk;               // 25 MHz, 40 ns period

  board_pins_if pins();
  assign pins.clk = clk;

  wire board_ftdi_rxd;
  assign pins.ftdi_rxd = board_ftdi_rxd;

  wire [7:0]  led;
  wire        jtag_tdo;
  wire        wifi_en;
  wire        sdram_clk_o, sdram_cke, sdram_cs_n;
  wire        sdram_ras_n, sdram_cas_n, sdram_we_n;
  wire [1:0]  sdram_ba, sdram_dqm;
  wire [12:0] sdram_a;
  wire [15:0] sdram_dq_pin;

  sim_board board (
      .clk         (clk),
      .btn1        (btn1),
      .led         (led),
      .ftdi_txd    (pins.ftdi_txd),
      .ftdi_rxd    (board_ftdi_rxd),
      .jtag_tck    (jtag_tck),
      .jtag_tms    (jtag_tms),
      .jtag_tdi    (jtag_tdi),
      .jtag_tdo    (jtag_tdo),
      .wifi_en     (wifi_en),
      .sdram_clk_o (sdram_clk_o),
      .sdram_cke   (sdram_cke),
      .sdram_cs_n  (sdram_cs_n),
      .sdram_ras_n (sdram_ras_n),
      .sdram_cas_n (sdram_cas_n),
      .sdram_we_n  (sdram_we_n),
      .sdram_ba    (sdram_ba),
      .sdram_a     (sdram_a),
      .sdram_dqm   (sdram_dqm),
      .sdram_dq_pin(sdram_dq_pin));

  // ---- J1 agent objects, ticked exactly as in the J1 harness -------
  mailbox #(byte) mon_mbx;
  mailbox #(byte) sb_mbx;
  uart_driver  j1_drv;
  uart_monitor j1_mon;
  nak_diag_filter filt;
  scoreboard   sb;
  tb_coverage  cov;
  cycle_counter cyc;
  j2_ctrl      ctrl;

  always @(negedge clk) begin
    j1_drv.tick();
    j1_mon.tick();
    filt.tick();
    sb.tick();
  end

  always @(posedge clk) cyc.tick();

  // ---- pin-knowledge checks (as J1) ---------------------------------
  int unsigned cyc_n = 0;
  always @(posedge clk) cyc_n <= cyc_n + 1;

  a_txd_known: assert property (@(posedge clk)
      disable iff (cyc_n < 300)
      !$isunknown(pins.ftdi_txd))
    else $error("ftdi_txd went X/Z after reset at cyc=%0d", cyc_n);

  a_rxd_known: assert property (@(posedge clk)
      disable iff (cyc_n < 300)
      !$isunknown(board_ftdi_rxd))
    else $error("ftdi_rxd went X/Z after reset at cyc=%0d", cyc_n);

  // ---- UVM wiring + end-of-run gate --------------------------------
  initial begin : p_run
    string tn;
    int    rc;
    int    smoke;

    mon_mbx = new();
    sb_mbx  = new();
    j1_drv  = new(pins);
    j1_mon  = new(pins, mon_mbx);
    filt    = new(mon_mbx, sb_mbx);
    sb      = new(sb_mbx);
    cov     = new();
    cyc     = new();
    ctrl    = new();

    smoke = 0;
    if ($value$plusargs("SMOKE=%d", smoke) && (smoke != 0)) begin
      ctrl.smoke_only = 1;
      `uvm_info("J2", "SMOKE mode: banner-only plumbing check", UVM_LOW)
    end

    uvm_config_db #(virtual board_pins_if)::set(null, "uvm_test_top.env", "vif",    pins);
    uvm_config_db #(uart_driver)::set(null,           "uvm_test_top.env", "j1_drv", j1_drv);
    uvm_config_db #(uart_monitor)::set(null,          "uvm_test_top.env", "uart_mon", j1_mon);
    uvm_config_db #(scoreboard)::set(null,            "uvm_test_top.env", "sb",     sb);
    uvm_config_db #(cycle_counter)::set(null,         "uvm_test_top.env", "cyc",    cyc);
    uvm_config_db #(j2_ctrl)::set(null,               "uvm_test_top.env", "ctrl",   ctrl);
    uvm_config_db #(nak_diag_filter)::set(null,       "uvm_test_top.env", "filt",   filt);

    if (!$value$plusargs("UVM_TESTNAME=%s", tn)) tn = "boot_hello_test";
    run_test(tn);

    // ---- end-of-run gate -------------------------------------------
    if (ctrl.smoke_only) begin
      if (ctrl.banner_cyc == 0) $fatal(1, "[j2] SMOKE: banner never seen");
      $display("[j2] banner at cyc %0d", ctrl.banner_cyc);
      $display("==================== J2 UVM-SIM SMOKE: PASS ====================");
    end else begin
      rc = sb.final_check(j1_mon.framing_errs);
      sb.report();
      cov.sample_loader(sb.acks_seen, sb.naks_seen, sb.last_chunk_len, sb.txns);
      cov.sample_milestones(sb.m_prefix, sb.m_first_ack, sb.m_load_done,
                            sb.m_readback, sb.m_hello, sb.m_tick0);

      // strict-BRAM census: read BRAM2's own counters hierarchically so
      // the coverage bins cannot disagree with the model's printed
      // summary.  RAM order matches coverage_pkg's documentation.
      cov.sample_hazard(0,
        board.top.top.soc_top.core.cpu.near_mem.icache.ram_cword_set.n_lost_a,
        board.top.top.soc_top.core.cpu.near_mem.icache.ram_cword_set.n_lost_b,
        board.top.top.soc_top.core.cpu.near_mem.icache.ram_cword_set.n_cross_ab,
        board.top.top.soc_top.core.cpu.near_mem.icache.ram_cword_set.n_cross_ba);
      cov.sample_hazard(1,
        board.top.top.soc_top.core.cpu.near_mem.icache.ram_state_and_ctag_cset.n_lost_a,
        board.top.top.soc_top.core.cpu.near_mem.icache.ram_state_and_ctag_cset.n_lost_b,
        board.top.top.soc_top.core.cpu.near_mem.icache.ram_state_and_ctag_cset.n_cross_ab,
        board.top.top.soc_top.core.cpu.near_mem.icache.ram_state_and_ctag_cset.n_cross_ba);
      cov.sample_hazard(2,
        board.top.top.soc_top.core.cpu.near_mem.dcache.ram_cword_set.n_lost_a,
        board.top.top.soc_top.core.cpu.near_mem.dcache.ram_cword_set.n_lost_b,
        board.top.top.soc_top.core.cpu.near_mem.dcache.ram_cword_set.n_cross_ab,
        board.top.top.soc_top.core.cpu.near_mem.dcache.ram_cword_set.n_cross_ba);
      cov.sample_hazard(3,
        board.top.top.soc_top.core.cpu.near_mem.dcache.ram_state_and_ctag_cset.n_lost_a,
        board.top.top.soc_top.core.cpu.near_mem.dcache.ram_state_and_ctag_cset.n_lost_b,
        board.top.top.soc_top.core.cpu.near_mem.dcache.ram_state_and_ctag_cset.n_cross_ab,
        board.top.top.soc_top.core.cpu.near_mem.dcache.ram_state_and_ctag_cset.n_cross_ba);
      cov.sample_hazard(4,
        board.top.top.soc_top.core.cpu.stageF_branch_predictor.btb_bramcore2.n_lost_a,
        board.top.top.soc_top.core.cpu.stageF_branch_predictor.btb_bramcore2.n_lost_b,
        board.top.top.soc_top.core.cpu.stageF_branch_predictor.btb_bramcore2.n_cross_ab,
        board.top.top.soc_top.core.cpu.stageF_branch_predictor.btb_bramcore2.n_cross_ba);

      cov.print_summary();
      if (rc != 0) $fatal(1, "[j2] scoreboard verdict FAILED rc=%0d", rc);
      $display("==================== J2 UVM-SIM: PASS ====================");
    end
    $finish;
  end

endmodule
