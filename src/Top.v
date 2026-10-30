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

    mkULX3S_Top top (
        .CLK(sys_clk),
        .RST_N(top_rst),
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
