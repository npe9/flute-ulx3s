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

    // microSD (SPI mode): no card unless a model drives MISO
    wire sd_clk, sd_cmd, sd_cs_n;
    wire sd_miso = 1'b1;
    wire flash_csn, flash_mosi, flash_wpn, flash_holdn;
    wire flash_miso = 1'b1;    // erased flash: no boot image

    // the I2C bus: pull-ups, and the board's RTC + EDID
    wire gpdi_sda, gpdi_scl, i2c_slave_low;
    pullup (gpdi_sda);
    pullup (gpdi_scl);
    assign gpdi_sda = i2c_slave_low ? 1'b0 : 1'bz;
    i2c_slave_model i2c_slaves (.clk (clk), .scl (gpdi_scl), .sda (gpdi_sda), .sda_low (i2c_slave_low));

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
        .sd_clk      (sd_clk),
        .sd_cmd      (sd_cmd),
        .sd_d0       (sd_miso),
        .sd_d3       (sd_cs_n),
        .flash_csn   (flash_csn),
        .flash_mosi  (flash_mosi),
        .flash_miso  (flash_miso),
        .flash_wpn   (flash_wpn),
        .flash_holdn (flash_holdn),
        .btn_pwr_n   (1'b1),
        .btn_rest    (5'b0),
        .sw          (4'b0101),
        .gpdi_sda    (gpdi_sda),
        .gpdi_scl    (gpdi_scl),
        .audio_l     (),
        .audio_r     (),
        .gpdi_dp     (),
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

`ifndef SDRAM_TCK_PS
`define SDRAM_TCK_PS 40000
`endif
    // JEDEC protocol/timing checker for the W9825G6KH-6 (passive).
    sdram_timing_check #(.TCK_PS(`SDRAM_TCK_PS)) mem_chk (
        .clk   (clk),
        .cke   (sdram_cke),
        .cs_n  (sdram_cs_n),
        .ras_n (sdram_ras_n),
        .cas_n (sdram_cas_n),
        .we_n  (sdram_we_n),
        .ba    (sdram_ba),
        .a     (sdram_a),
        .dqm   (sdram_dqm)
    );

    assign sdram_dq_pin = sdram_dq;

endmodule
