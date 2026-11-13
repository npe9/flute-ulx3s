// Verilog wrapper: connects the BSC-generated mkULX3S_Top to ULX3S-85F
// board pins (clock, FTDI UART, LEDs, ESP32 reset, SDR SDRAM).
//
// The board clock is 25 MHz.  Default build: the system clock is the raw
// board clock.  `make SYS_PLL=1`: the system clock is 32.14 MHz from the
// ECP5 PLL (see below); `make SYS_PLL=50`: 50 MHz.  SDRAM/UART timing parameters derive from
// sys_clk_hz in src/ULX3S_Top.bsv (SYS_CLK_HZ define in the PLL build).
module ulx3s_top(
    input  wire        CLK,         // 25 MHz, G2
    input  wire        BTN1,        // FIRE1, active high, R1
    output wire [7:0]  led,
    input  wire        ftdi_txd,    // from FTDI, M1
    output wire        ftdi_rxd,    // to FTDI, L4
`ifdef JTAG_TAP
`ifdef VERILATOR
    // The RISC-V DTM is on the FPGA's configuration JTAG port (JTAGG, below), which has no user
    // pins.  In simulation these four ports stand for that port (the FT231X's TCK/TMS/TDI/TDO)
    // and drive src/ecp5_jtag_model.v, a model of the configuration TAP, in place of JTAGG.
    input  wire        jtag_tck,
    input  wire        jtag_tms,
    input  wire        jtag_tdi,
    output wire        jtag_tdo,
`endif
`endif
    output wire        wifi_en,     // ESP32 EN, F1: 0 holds it in reset (gpio1 0x0C, src/Board_IO.v)
    output wire        wifi_gpio0,  // ESP32 GPIO0, L2: held low, so it can only start its ROM bootloader
    output wire        shutdown,    // G16: 1 turns the board off (gpio1 0x10 POWER, src/Board_IO.v)
    output wire        user_programn, // M4: pulled low to reconfigure from flash (gpio1 0x14 RECONF), else released
    output wire        wifi_rxd,    // ESP32 UART0 RX, K3: the FPGA transmits (uart1)
    input  wire        wifi_txd,    // ESP32 UART0 TX, K4: the FPGA receives
    // microSD: SPI mode (spi0) or native SD mode (src/Sd_Host.v), muxed in Sd_Host
    output wire        sd_clk,      //   SCLK / CLK, H2
    inout  wire        sd_cmd,      //   MOSI / CMD, J1
    inout  wire        sd_d0,       //   MISO / DAT0, J3; also the ESP32's GPIO2 strap (gpio1 0x0C [2])
    inout  wire        sd_d1,       //   DAT1, H1
    inout  wire        sd_d2,       //   DAT2, K1
    inout  wire        sd_d3,       //   CS (active low) / DAT3, K2
    output wire        flash_csn,   // configuration flash: CS, R2
    output wire        flash_mosi,  //   D0, W2
    input  wire        flash_miso,  //   D1, V2
    output wire        flash_wpn,   //   write protect (held high), Y2
    output wire        flash_holdn, //   hold (held high), W1
    input  wire        btn_pwr_n,   // BTN0, power button, active low, D6 (src/Board_IO.v)
    input  wire [4:0]  btn_rest,    // FIRE2 T1, UP R18, DOWN V1, LEFT U1, RIGHT H16, active high
    input  wire [3:0]  sw,          // DIP switches E8 D8 D7 E7
    inout  wire        gpdi_sda,    // I2C shared by the RTC and HDMI DDC, open drain, B19
    inout  wire        gpdi_scl,    //   E12
    output wire [3:0]  audio_l,     // jack DACs (src/Audio.v), mute until software sets VOLUME
    output wire [3:0]  audio_r,
    output wire [3:0]  audio_v,     // jack ring 2 DAC (E5 F5 F2 H5): S/PDIF when audio 0x1C PINS is set
    inout  wire        gpdi_cec,    // HDMI CEC, A18: open drain (gpio1 0x18 [0] pulls it low)
    input  wire        gpdi_hpd,    // HDMI HPD, B20 (pin 19, HEAC-): input only
    input  wire        gpdi_util,   // HDMI Utility, A19 (pin 14, HEAC+): input only
    output wire        adc_sclk,    // on-board ADC (MAX11125) on the second SPI host: P17
    output wire        adc_mosi,    //   R16
    output wire        adc_csn,     //   R17
    input  wire        adc_miso,    //   U16
    output wire [3:0]  gpdi_dp,     // DVI: blue A16, green A14, red A12, clock A17 (LVCMOS33D:
                                    // the _dn pins are driven as the complements)
    output wire        sdram_clk,   // F19
    output wire        sdram_cke,   // F20
    output wire        sdram_cs_n,  // P20
    output wire        sdram_ras_n, // R20
    output wire        sdram_cas_n, // T19
    output wire        sdram_we_n,  // T20
    output wire [1:0]  sdram_ba,    // P19 N20
    output wire [12:0] sdram_a,     // M20..G19
    inout  wire [15:0] sdram_dq,    // J16..J17
    output wire [1:0]  sdram_dqm    // U19 E20
);
`ifdef SYS_PLL
    // System clock: 32.142857 MHz from the ECP5 PLL (25 MHz x 9 / 7; the
    // VCO runs at 610.7 MHz, CLKOP_DIV 19).  32.5 MHz is not reachable
    // (25 x 13/10 needs a 2.5 MHz PFD, below the 3.125 MHz minimum);
    // `ecppll -i 25 -o 32.5` picks this.  Build with `make SYS_PLL=1`,
    // which also passes SYS_CLK_HZ=32142857 to bsc (UART divisor 51,
    // 0.8% fast; SDRAM tRFC 3 clocks).  Timing margin vs the 37.2 MHz
    // E8d fmax: 13.6%, inside the 12% rule.
    wire sys_clk;
    wire pll_locked;
`ifdef SYS_PLL_50
    // `make SYS_PLL=50`: 50 MHz = 25 MHz x 2 (VCO 600 MHz, CLKOP_DIV 12; ecppll -i 25 -o 50).
    localparam PLL_CLKI_DIV = 1, PLL_CLKFB_DIV = 2, PLL_CLKOP_DIV = 12, PLL_CLKOP_CPHASE = 5;
    (* FREQUENCY_PIN_CLKI="25" *)
    (* FREQUENCY_PIN_CLKOP="50" *)
`else
    localparam PLL_CLKI_DIV = 7, PLL_CLKFB_DIV = 9, PLL_CLKOP_DIV = 19, PLL_CLKOP_CPHASE = 9;
    (* FREQUENCY_PIN_CLKI="25" *)
    (* FREQUENCY_PIN_CLKOP="32.142857" *)
`endif
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(PLL_CLKI_DIV), .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(PLL_CLKOP_DIV),
        .CLKOP_CPHASE(PLL_CLKOP_CPHASE), .CLKOP_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(PLL_CLKFB_DIV)
    ) sys_pll (
        .RST(1'b0), .STDBY(1'b0), .CLKI(CLK),
        .CLKOP(sys_clk), .CLKFB(sys_clk),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b1),
        .PHASESTEP(1'b1), .PHASELOADREG(1'b1), .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0), .LOCK(pll_locked)
    );
`else
    // System clock: raw 25 MHz board clock.
    wire sys_clk = CLK;
    wire pll_locked = 1'b1;
`endif

    // Hold the design in reset briefly after configuration (and until the
    // PLL locks, in the PLL build); FIRE1 restarts it manually.  Count on
    // the sys_clk domain.
    reg [7:0] power_on_reset = 8'h00;
    always @(posedge sys_clk) begin
        if (BTN1 || !pll_locked)
            power_on_reset <= 8'h00;
        else if (!&power_on_reset)
            power_on_reset <= power_on_reset + 1'b1;
    end

    // E34: registered.  As a wire from the BTN1 pad it fed ~3.8K sinks
    // across the die on general routing (fanout census, E32), with no
    // synchronizer on the async button.  One cycle later, same behavior:
    // BTN1 also clears power_on_reset.
    reg rst_n = 1'b0;
    always @(posedge sys_clk)
        rst_n <= (&power_on_reset) & ~BTN1;

`ifdef BSV_POSITIVE_RESET
    // E35: the BSV netlist is synthesized with BSV_POSITIVE_RESET, so its
    // flops take an active-high reset directly on LSR (no inverter LUT).
    // (The RST_N port name is bsc's; under this define it is active high.)
    // E38: no DCCA.  Routing this net through a DCCA onto a global passed
    // P&R and Verilator but the board never came out of reset (debug
    // bridge dead); general routing works.
    reg sys_rst = 1'b1;
    always @(posedge sys_clk)
        sys_rst <= ~((&power_on_reset) & ~BTN1);
    wire top_rst = sys_rst;
`else
    wire top_rst = rst_n;
`endif

    // SDRAM clock: forward the system clock through an ECP5 DDR output
    // cell so it uses the dedicated IOLOGIC clock path.
    ODDRX1F sdram_clk_oddr (
        .D0  (1'b0),
        .D1  (1'b1),
        .SCLK(sys_clk),
        .RST (1'b0),
        .Q   (sdram_clk)
    );

    // Read-data sampling: DQ must be registered AT THE PAD (IOB FF) so
    // all 16 bits sample on the same clock edge.  Fabric routing skew
    // between DQ[15:8] and DQ[7:0] bytes one of them a cycle late on
    // some placements, which reads back as byte1<->byte3 swaps within
    // each 32-bit word (seen as high-byte corruption of alternate
    // beats).  The BSV controller's own input register adds the second
    // stage; keep t_cas_first=2 to match the original timing chain.
    (* useioff = 1 *) reg [15:0] sdram_dq_iob;
    always @(posedge sys_clk)
        sdram_dq_iob <= sdram_dq;

    // Bidirectional SDRAM data bus
    wire [15:0] sdram_dq_out;
    wire        sdram_dq_oe;
    assign sdram_dq = sdram_dq_oe ? sdram_dq_out : 16'hZZZZ;

    // The flash clock is the dedicated CCLK pin (U3), reachable after configuration only
    // through USRMCLK (the LPF's MASTER_SPI_PORT=DISABLE frees the other flash pins).
    wire flash_sclk;
    USRMCLK u_usrmclk (.USRMCLKI(flash_sclk), .USRMCLKTS(1'b0));
    assign flash_wpn   = 1'b1;
    assign flash_holdn = 1'b1;

    // ---- DVI output (src/Video_DVI.v): 640x480 at 60 Hz from a second PLL, 25 MHz pixel
    // clock and the 125 MHz shift clock (10 bits per pixel, 2 per shift clock).  The video
    // PLL does not gate the system reset.  Without SYS_PLL (the Verilator benches) both video
    // clocks are the system clock and the block sits in mode 0 unless a bench drives it.
    wire        pix_clk, shift_clk;
`ifdef SYS_PLL
    (* FREQUENCY_PIN_CLKI="25" *)
    (* FREQUENCY_PIN_CLKOP="125" *)
    (* FREQUENCY_PIN_CLKOS="25" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"), .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"), .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1), .CLKFB_DIV(5), .FEEDBK_PATH("CLKOP"),         // VCO 625 MHz
        .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(5),  .CLKOP_CPHASE(2),  .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"), .CLKOS_DIV(25), .CLKOS_CPHASE(12), .CLKOS_FPHASE(0)
    ) video_pll (
        .RST(1'b0), .STDBY(1'b0), .CLKI(CLK),
        .CLKOP(shift_clk), .CLKOS(pix_clk), .CLKFB(shift_clk),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0), .PHASEDIR(1'b1),
        .PHASESTEP(1'b1), .PHASELOADREG(1'b1), .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0), .LOCK()
    );
`else
    assign pix_clk   = sys_clk;
    assign shift_clk = sys_clk;
`endif

    wire        rb_valid, rb_we, rb_ack;
    wire [31:0] rb_addr, rb_wdata, rb_rdata;
    wire [3:0]  rb_wstrb;
    // The bridge's devices.  Only mapped windows get here, so bits 24 (0xC1xx_xxxx) and 16
    // (0xC001_xxxx) tell the video windows from the 0xC000_6000+ small devices.
    wire        rb_sel_video = rb_addr[24] || rb_addr[16];
    wire        rb_sel_audio = !rb_sel_video && (rb_addr[15:12] == 4'h9);
    wire        rb_sel_sdh   = !rb_sel_video && (rb_addr[15:12] == 4'hD);
    wire        video_ack, io_ack, audio_ack, sdh_ack;
    wire [31:0] video_rdata, io_rdata, audio_rdata, sdh_rdata;
    assign rb_ack   = video_ack || io_ack || audio_ack || sdh_ack;
    assign rb_rdata = io_ack ? io_rdata : audio_ack ? audio_rdata : sdh_ack ? sdh_rdata : video_rdata;

    audio audio_0 (
        .clk(sys_clk), .rst(~rst_n),
        .rb_valid(rb_valid && rb_sel_audio), .rb_we(rb_we), .rb_addr(rb_addr[11:0]),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(audio_ack), .rb_rdata(audio_rdata),
        .audio_l(audio_l), .audio_r(audio_r), .audio_v(audio_v)
    );

    wire i2c_scl_low, i2c_sda_low;
    assign gpdi_scl = i2c_scl_low ? 1'b0 : 1'bz;
    assign gpdi_sda = i2c_sda_low ? 1'b0 : 1'bz;
    wire esp32_en, esp32_strap, board_reconf;
    wire cec_low;
    assign gpdi_cec = cec_low ? 1'b0 : 1'bz;     // open drain: only ever pulled low
    // microSD pins: SPI0 (SPI mode) plus the ESP32's GPIO2 strap, or the native SD host.  The ESP32
    // strap pulls DAT0 low only in SPI mode while the card is deselected (its DO is then
    // high-impedance); native mode needs the ESP32 in reset with the strap released.
    wire        spi_sclk, spi_mosi, spi_cs_n, spi_miso;
    wire        sdh_clk, sdh_cmd_o, sdh_cmd_oe;
    wire [3:0]  sdh_dat_o, sdh_dat_oe;
    assign sd_clk = sdh_clk;
    assign sd_cmd = sdh_cmd_oe    ? sdh_cmd_o    : 1'bz;
    assign sd_d0  = sdh_dat_oe[0] ? sdh_dat_o[0] : 1'bz;
    assign sd_d1  = sdh_dat_oe[1] ? sdh_dat_o[1] : 1'bz;
    assign sd_d2  = sdh_dat_oe[2] ? sdh_dat_o[2] : 1'bz;
    assign sd_d3  = sdh_dat_oe[3] ? sdh_dat_o[3] : 1'bz;
    sd_host sdh (
        .clk(sys_clk), .rst(~rst_n),
        .rb_valid(rb_valid && rb_sel_sdh), .rb_we(rb_we), .rb_addr(rb_addr[11:0]),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(sdh_ack), .rb_rdata(sdh_rdata),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n), .spi_miso(spi_miso),
        .esp32_en(esp32_en), .esp32_strap(esp32_strap),
        .clk_o(sdh_clk), .cmd_o(sdh_cmd_o), .cmd_oe(sdh_cmd_oe), .cmd_i(sd_cmd),
        .dat_o(sdh_dat_o), .dat_oe(sdh_dat_oe), .dat_i({sd_d3, sd_d2, sd_d1, sd_d0})
    );
    board_io board_io_0 (
        .clk(sys_clk), .rst(~rst_n),
        .rb_valid(rb_valid && !rb_sel_video && !rb_sel_audio && !rb_sel_sdh), .rb_we(rb_we), .rb_addr(rb_addr[15:0]),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(io_ack), .rb_rdata(io_rdata),
        .btn_i({btn_rest, BTN1, btn_pwr_n}), .sw_i(sw), .esp32_tx_i(wifi_txd),
        .scl_i(gpdi_scl), .sda_i(gpdi_sda), .scl_low(i2c_scl_low), .sda_low(i2c_sda_low),
        .esp32_en(esp32_en), .esp32_strap(esp32_strap), .shutdown(shutdown), .reconf(board_reconf),
        .cec_i(gpdi_cec), .hpd_i(gpdi_hpd), .util_i(gpdi_util), .cec_low(cec_low)
    );

    wire [9:0]  tmds_r, tmds_g, tmds_b;
    wire        pix_tog;
    video_fb video (
        .clk(sys_clk), .rst(~rst_n),
        .rb_valid(rb_valid && rb_sel_video), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
        .rb_wstrb(rb_wstrb), .rb_ack(video_ack), .rb_rdata(video_rdata),
        .pclk(pix_clk), .tmds_r(tmds_r), .tmds_g(tmds_g), .tmds_b(tmds_b), .ptog(pix_tog),
        .dbg_rgb(), .dbg_de(), .dbg_hs(), .dbg_vs()
    );
    dvi_ser dvi (
        .sclk(shift_clk), .ptog(pix_tog),
        .tmds_r(tmds_r), .tmds_g(tmds_g), .tmds_b(tmds_b), .gpdi_dp(gpdi_dp)
    );

`ifdef JTAG_TAP
    // RISC-V debug over the FPGA's own JTAG port: the configuration TAP's ER1 (IR 0x32) and
    // ER2 (IR 0x38) select src/JtaggDtm.bsv's dmi and dtmcs registers; it samples these
    // strobes with sys_clk (no TCK clock domain).
    wire [6:0] jtagg_pins;
    wire       jtagg_tdo;
    wire jg_tck, jg_tdi, jg_shift, jg_update, jg_rstn, jg_ce1, jg_ce2;
    assign jtagg_pins = {jg_ce2, jg_ce1, jg_rstn, jg_update, jg_shift, jg_tdi, jg_tck};
`ifdef VERILATOR
    ecp5_jtag_model jtagg_i (
        .TCK(jtag_tck), .TMS(jtag_tms), .TDI(jtag_tdi), .TDO(jtag_tdo),
`else
    JTAGG jtagg_i (
`endif
        .JTCK(jg_tck), .JTDI(jg_tdi), .JSHIFT(jg_shift), .JUPDATE(jg_update), .JRSTN(jg_rstn),
        .JCE1(jg_ce1), .JCE2(jg_ce2), .JRTI1(), .JRTI2(),
        .JTDO1(jtagg_tdo), .JTDO2(jtagg_tdo)
    );
`endif

    mkULX3S_Top top (
        .CLK(sys_clk),
        .RST_N(top_rst),
        .serial_txd(ftdi_rxd),
        .serial_rxd_v(ftdi_txd),
        .esp32_txd(wifi_rxd),
        .esp32_rxd_v(esp32_en ? wifi_txd : 1'b1),   // idle while held (the pin is pulled down)
        .leds(led),
        .btn1_v(BTN1),
        .sd_sclk(spi_sclk),
        .sd_mosi(spi_mosi),
        .sd_cs_n(spi_cs_n),
        .sd_miso_v(spi_miso),
        .flash_sclk(flash_sclk),
        .flash_mosi(flash_mosi),
        .flash_cs_n(flash_csn),
        .flash_miso_v(flash_miso),
        .adc_sclk(adc_sclk),
        .adc_mosi(adc_mosi),
        .adc_cs_n(adc_csn),
        .adc_miso_v(adc_miso),
        .rb_valid(rb_valid),
        .rb_we(rb_we),
        .rb_addr(rb_addr),
        .rb_wdata(rb_wdata),
        .rb_wstrb(rb_wstrb),
        .rb_ack_ack(rb_ack),
        .rb_ack_rdata(rb_rdata),
`ifdef JTAG_TAP
        .jtagg_v(jtagg_pins),
        .jtagg_tdo(jtagg_tdo),
`endif
        .sdram_cke(sdram_cke),
        .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n),
        .sdram_ba(sdram_ba),
        .sdram_a(sdram_a),
        .sdram_dqm(sdram_dqm),
        .sdram_dq_out(sdram_dq_out),
        .sdram_dq_oe(sdram_dq_oe),
        .sdram_dq_in_v(sdram_dq_iob)
    );

    // The ESP32: released only by software (Board_IO, reset 0), and then only into its ROM
    // bootloader: GPIO0 low at EN's rising edge selects download mode, never the flashed firmware.
    assign user_programn = board_reconf ? 1'b0 : 1'bz;
    assign wifi_en    = esp32_en;
    assign wifi_gpio0 = 1'b0;
endmodule

`ifdef JTAG_TAP
`ifdef VERILATOR
`include "ecp5_jtag_model.v"
`endif
`endif
