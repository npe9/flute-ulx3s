// ================================================================
// ecp5_cells.v — behavioral models for the ECP5 primitives
// instantiated in src/Top.v.  Sim-only (never synthesized; the
// Yosys flow maps the real cells).
//
// src/Top.v instantiates ODDRX1F and, under BSV_POSITIVE_RESET (E35), DCCA:
//   ODDRX1F sdram_clk_oddr (.D0(1'b0), .D1(1'b1), .SCLK(sys_clk),
//                           .RST(1'b0), .Q(sdram_clk));
// i.e. pure clock forwarding: Q reproduces SCLK.  The ODDRX1F model below
// implements the general DDR output behavior (Q <= D1 on the rising
// edge, Q <= D0 on the falling edge, async clear by RST), which
// degenerates to Q == SCLK for that usage.
// ================================================================

`ifdef VERILATOR
`endif

module ODDRX1F (
    output reg Q,
    input  wire D0,
    input  wire D1,
    input  wire SCLK,
    input  wire RST
);
    always @(SCLK or RST) begin
        if (RST)
            Q <= 1'b0;
        else if (SCLK)
            Q <= D1;
        else
            Q <= D0;
    end
endmodule

// DCCA: clock-tree buffer with enable (E35 drives the active-high system
// reset through one onto a global net, under BSV_POSITIVE_RESET).
module DCCA (
    input  wire CLKI,
    input  wire CE,
    output wire CLKO
);
    assign CLKO = CE & CLKI;
endmodule
