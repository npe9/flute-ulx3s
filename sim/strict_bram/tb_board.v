// ================================================================
// tb_board.v — thin sim wrapper around ulx3s_top + the W9825G6 model.
//
// Exists so the SDRAM dq tri-state bus is resolved in Verilog (inside
// the verilated model) instead of at the C++ boundary, where a
// top-level inout would be awkward.  Everything else is passed
// straight through to the C++ bench (tb_top.cpp), which drives the
// board clock/reset and plays the UART host.
// ================================================================

module sim_board (
    input  wire        clk,
    input  wire        btn1,
    output wire [7:0]  led,
    input  wire        ftdi_txd,   // host -> FPGA (FPGA RX pin)
    output wire        ftdi_rxd,   // FPGA -> host (FPGA TX pin)
    input  wire        jtag_tck,
    input  wire        jtag_tms,
    input  wire        jtag_tdi,
    output wire        jtag_tdo,
    output wire        wifi_en,
    // SDRAM pin taps (observability for the bench)
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

    tri  [15:0] sdram_dq;

    ulx3s_top top (
        .CLK      (clk),
        .BTN1     (btn1),
        .led      (led),
        .ftdi_txd (ftdi_txd),
        .ftdi_rxd (ftdi_rxd),
`ifdef JTAG_TAP
        .jtag_tck (jtag_tck),
        .jtag_tms (jtag_tms),
        .jtag_tdi (jtag_tdi),
        .jtag_tdo (jtag_tdo),
`endif
        .wifi_en     (wifi_en),
        .sdram_clk   (sdram_clk_o),
        .sdram_cke   (sdram_cke),
        .sdram_cs_n  (sdram_cs_n),
        .sdram_ras_n (sdram_ras_n),
        .sdram_cas_n (sdram_cas_n),
        .sdram_we_n  (sdram_we_n),
        .sdram_ba    (sdram_ba),
        .sdram_a     (sdram_a),
        .sdram_dq    (sdram_dq),
        .sdram_dqm   (sdram_dqm)
    );

    w9825g6 mem (
        .clk   (clk),
        .cke   (sdram_cke),
        .cs_n  (sdram_cs_n),
        .ras_n (sdram_ras_n),
        .cas_n (sdram_cas_n),
        .we_n  (sdram_we_n),
        .ba    (sdram_ba),
        .a     (sdram_a),
        .dqm   (sdram_dqm),
        .dq    (sdram_dq)
    );

    assign sdram_dq_pin = sdram_dq;

endmodule
