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

    // microSD: a behavioral SDHC card in SPI mode (sim/common/sd_spi_model.v: +sd_none no card,
    // +sd_image=<hex> contents), or with +sd_native in native SD mode (sim/common/sd_native_model.v:
    // +sdn_image=<hex>, writes only here).  Pull-ups on every line, as on the board.
    wire sd_clk, sd_cmd, sd_d0, sd_d1, sd_d2, sd_d3, sd_spi_miso, sdn_cmd_o, sdn_cmd_oe;
    wire [3:0] sdn_dat_o, sdn_dat_oe;
    reg  sd_native;
    initial sd_native = $test$plusargs ("sd_native");
    pullup (sd_cmd); pullup (sd_d0); pullup (sd_d1); pullup (sd_d2); pullup (sd_d3);
    sd_spi_model sd (.clk (clk), .sck (sd_native ? 1'b0 : sd_clk), .mosi (sd_cmd), .cs_n (sd_native ? 1'b1 : sd_d3),
                     .miso (sd_spi_miso));
    assign sd_d0 = (!sd_native && !sd_d3) ? sd_spi_miso : 1'bz;     // DO is driven only while selected
    sd_native_model sdn (.clk (clk), .sck (sd_native ? sd_clk : 1'b0), .cmd_i (sd_cmd), .cmd_o (sdn_cmd_o),
                         .cmd_oe (sdn_cmd_oe), .dat_i ({sd_d3, sd_d2, sd_d1, sd_d0}), .dat_o (sdn_dat_o),
                         .dat_oe (sdn_dat_oe));
    assign sd_cmd = (sd_native && sdn_cmd_oe)    ? sdn_cmd_o    : 1'bz;
    assign sd_d0  = (sd_native && sdn_dat_oe[0]) ? sdn_dat_o[0] : 1'bz;
    assign sd_d1  = (sd_native && sdn_dat_oe[1]) ? sdn_dat_o[1] : 1'bz;
    assign sd_d2  = (sd_native && sdn_dat_oe[2]) ? sdn_dat_o[2] : 1'bz;
    assign sd_d3  = (sd_native && sdn_dat_oe[3]) ? sdn_dat_o[3] : 1'bz;

    // Configuration flash: behavioral SPI NOR (+flash_image=<hex>: contents, else erased).  The
    // clock has no pin on ulx3s_top (USRMCLK drives CCLK), so it is read through the stub.
    wire flash_csn, flash_mosi, flash_miso, flash_wpn, flash_holdn;
    spi_flash_model flash (.clk (clk), .sck (top.u_usrmclk.USRMCLKI), .mosi (flash_mosi),
                           .cs_n (flash_csn), .miso (flash_miso));

    // DVI scan-out to a PPM (+fb_ppm=<file>; the pixel clock is the system clock here)
    fb_capture fbcap (.clk (clk), .rgb (top.video.dbg_rgb), .de (top.video.dbg_de),
                      .vs (top.video.dbg_vs));

    // the I2C bus: pull-ups, and the board's RTC + EDID
    wire gpdi_sda, gpdi_scl, i2c_slave_low;
    pullup (gpdi_sda);
    pullup (gpdi_scl);
    assign gpdi_sda = i2c_slave_low ? 1'b0 : 1'bz;
    i2c_slave_model i2c_slaves (.clk (clk), .scl (gpdi_scl), .sda (gpdi_sda), .sda_low (i2c_slave_low));

    // the ADC's place: a stand-in that echoes the previous 16-bit word (sim/common/spi_echo_model.v)
    wire adc_sclk, adc_mosi, adc_csn, adc_miso;
    spi_echo_model adc (.clk (clk), .sck (adc_sclk), .mosi (adc_mosi), .cs_n (adc_csn), .miso (adc_miso));

    // the ESP32's place: its RX looped to its TX while EN is high (a stand-in, not the ROM)
    wire wifi_gpio0, wifi_rxd;
    wire wifi_txd = wifi_en ? wifi_rxd : 1'b1;

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
        .sd_d0       (sd_d0),
        .sd_d1       (sd_d1),
        .sd_d2       (sd_d2),
        .sd_d3       (sd_d3),
        .flash_csn   (flash_csn),
        .flash_mosi  (flash_mosi),
        .flash_miso  (flash_miso),
        .flash_wpn   (flash_wpn),
        .flash_holdn (flash_holdn),
        .btn_pwr_n   (1'b1),
             .shutdown    (),
        .user_programn (),
        .wifi_gpio0  (wifi_gpio0),
        .wifi_rxd    (wifi_rxd),
        .wifi_txd    (wifi_txd),
   .btn_rest    (5'b0),
        .sw          (4'b0101),
        .gpdi_sda    (gpdi_sda),
        .gpdi_scl    (gpdi_scl),
        .audio_l     (),
        .audio_r     (),
        .adc_sclk    (adc_sclk),
        .adc_mosi    (adc_mosi),
        .adc_csn     (adc_csn),
        .adc_miso    (adc_miso),
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

    assign sdram_dq_pin = sdram_dq;

endmodule
