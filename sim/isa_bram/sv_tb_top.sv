// ================================================================
// sv_tb_top.sv — J1 verilation top (Track J, option B).
//
// Wraps the F1 harness WITHOUT modifying it: instantiates sim_board
// (tb_board.v: ulx3s_top + strict BRAM2 substitution + W9825G6 model)
// and the board_pins_if, owns the agent/scoreboard/coverage instances,
// and ticks them on the NEGEDGE of clk.  Ticking on the opposite edge
// from the DUT's sampling keeps every agent write (blocking assigns,
// required under --no-timing) clear of the posedge sampling race the
// J0 vif probe documented.
//
// Phase-1 ownership split (see each file's header):
//   C++ main (tb_top.cpp) — clock, btn1, JTAG tieoff, scenario FSM
//        (banner wait, chunked load ACK pacing, deadlines), image
//        framing, PASS/FAIL reporting, coverage file write.
//   sv_inject_byte          C++ -> SV driver (replaces C++ send_byte)
//   sv_tx_avail/sv_tx_byte  SV monitor -> C++ TX view (replaces
//                           C++ tx_sample/tx_log plumbing)
//   sv_sb_set_expected      expected chunk count / last chunk length
//   sv_sb_note_chunk_txn    one per framed chunk queued by the host
//                           (scoreboard: ACK only after a full chunk)
//   sv_final_checks         end-of-run: scoreboard verdict + coverage
//                           sampling (incl. the strict-BRAM census,
//                           read hierarchically from BRAM2's counters)
//
// Fatal protocol checks live as concurrent assertions here (compiled
// in with --assert; a failed assertion exits nonzero = the gate).
// ================================================================

module sv_tb_top (
    input  wire        clk,
    input  wire        btn1,
    output wire [7:0]  led,
    input  wire        jtag_tck,
    input  wire        jtag_tms,
    input  wire        jtag_tdi,
    output wire        jtag_tdo,
    output wire        wifi_en,
    // SDRAM pin taps (observability, as in sim_board)
    output wire        sdram_clk_o,
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_dqm,
    output wire [15:0] sdram_dq_pin
);

  import uart_agent_pkg::*;
  import scoreboard_pkg::*;
  import coverage_pkg::*;

  // ---- board pins interface + F1 board (unmodified) -----------------
  board_pins_if pins();

  wire board_ftdi_rxd;

  assign pins.clk      = clk;
  assign pins.ftdi_rxd = board_ftdi_rxd;

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
      .sdram_dq_pin(sdram_dq_pin)
  );

  // ---- agents ---------------------------------------------------------
  mailbox #(byte) txmbox;
  uart_driver  drv;
  uart_monitor mon;
  scoreboard   sb;
  tb_coverage  cov;

  initial begin
    // NOTE: pins.ftdi_txd is declaration-initialized in board_pins_if
    // (set at construction, before any eval); no assignment needed here.
    txmbox = new();
    drv = new(pins);
    mon = new(pins, txmbox);
    sb  = new(txmbox);
    cov = new();
  end

  // ticked agents: negedge, driver first (its pin update must settle
  // before the next posedge), monitor next, scoreboard drains last
  always @(negedge clk) begin
    drv.tick();
    mon.tick();
    sb.tick();
  end

  // ---- fatal protocol checks (need --assert) --------------------------
  // The board's power-on reset (src/Top.v) releases after 256 clocks;
  // from then on both UART pins must be driven to a known level every
  // single cycle.
  int unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  a_txd_known: assert property (@(posedge clk)
      disable iff (cyc < 300)
      !$isunknown(pins.ftdi_txd))
    else $error("ftdi_txd went X/Z after reset at cyc=%0d", cyc);

  a_rxd_known: assert property (@(posedge clk)
      disable iff (cyc < 300)
      !$isunknown(board_ftdi_rxd))
    else $error("ftdi_rxd went X/Z after reset at cyc=%0d", cyc);

  // ---- DPI bridge: C++ main stays in charge of the scenario -----------
  export "DPI-C" function sv_inject_byte;
  function void sv_inject_byte(input int b);
    drv.send_byte(8'(b));
  endfunction

  export "DPI-C" function sv_tx_avail;
  function int sv_tx_avail();
    return mon.n_avail();
  endfunction

  export "DPI-C" function sv_tx_byte;
  function int sv_tx_byte(input int idx);
    return mon.byte_at(idx);
  endfunction

  export "DPI-C" function sv_sb_set_expected;
  function void sv_sb_set_expected(input int n_cks, input int last_len);
    sb.set_expected(n_cks, last_len);
  endfunction

  export "DPI-C" function sv_sb_note_chunk_txn;
  function void sv_sb_note_chunk_txn();
    sb.note_chunk_txn();
  endfunction

  // Compliance signature readout (tb_top.cpp TB_SIG): one SDRAM model
  // halfword by model index (isa_run.py model_idx layout).
  export "DPI-C" function sv_sdram_peek;
  function int sv_sdram_peek(input int idx);
    return {16'h0, board.mem.mem[idx[23:0]]};
  endfunction

  // End-of-run verdict + one-shot coverage sampling.  Returns 0 on
  // success; assertion failures (the gate) abort before the return.
  export "DPI-C" function sv_final_checks;
  function int sv_final_checks();
    int rc;
    rc = sb.final_check(mon.framing_errs);
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
    return rc;
  endfunction

endmodule
