// Verilog wrapper: connects the BSC-generated mkULX3S_Top to ULX3S-85F
// board pins (clock, FTDI UART, LEDs, ESP32 reset, SDR SDRAM).
//
// The board clock is 25 MHz and the design closes timing at 25 MHz on
// the 85F (26.99 MHz worst seed-1 path after the Stage2 BYPASS_RD fix),
// so the system clock is the raw board clock.  SDRAM/UART timing
// parameters derive from sys_clk_hz in src/ULX3S_Top.bsv.
module ulx3s_top(
    input  wire        CLK,         // 25 MHz, G2
    input  wire        BTN1,        // FIRE1, active high, R1
    output wire [7:0]  led,
    input  wire        ftdi_txd,    // from FTDI, M1
    output wire        ftdi_rxd,    // to FTDI, L4
`ifdef JTAG_TAP
    // Soft RISC-V JTAG TAP on GPIO header J1.  Kept in the design for
    // placement parity with the known-good 2026-10-04 build; the UART
    // DMI bridge is the actual debug transport.
    input  wire        jtag_tck,    // J1_7-  (gn[1], A11)
    input  wire        jtag_tms,    // J1_5+  (gp[0], B11)
    input  wire        jtag_tdi,    // J1_5-  (gn[0], C11)
    output wire        jtag_tdo,    // J1_7+  (gp[1], A10)
`endif
    output wire        wifi_en,     // ESP32 hold in reset, F1
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
    // System clock: raw 25 MHz board clock (timing closes at 25 MHz).
    wire sys_clk = CLK;

    // Hold the design in reset briefly after configuration; FIRE1
    // restarts it manually.  Count on the sys_clk domain.
    reg [7:0] power_on_reset = 8'h00;
    always @(posedge sys_clk) begin
        if (BTN1)
            power_on_reset <= 8'h00;
        else if (!&power_on_reset)
            power_on_reset <= power_on_reset + 1'b1;
    end

    wire rst_n = (&power_on_reset) & ~BTN1;

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

    mkULX3S_Top top (
        .CLK(sys_clk),
        .RST_N(rst_n),
        .serial_txd(ftdi_rxd),
        .serial_rxd_v(ftdi_txd),
        .leds(led),
        .btn1_v(BTN1),
`ifdef JTAG_TAP
        .jtag_tclk(jtag_tck),
        .jtag_tms(jtag_tms),
        .jtag_tdi(jtag_tdi),
        .jtag_tdo(jtag_tdo),
        .CLK_jtag_tclk_out(),
        .CLK_GATE_jtag_tclk_out(),
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

    // Keep the ESP32 from interfering with the FTDI UART
    assign wifi_en = 1'b0;
endmodule
