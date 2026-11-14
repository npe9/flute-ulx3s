// spi_host_mon: an SPI host's single-lane 8-bit frames at the wires (SCK, MOSI, the selected CS),
// against the host's trace of them, in the role-parameter style (HOST_IS_DUT=1: the host's
// rules are asserted; there is nothing to assume of a device here, MISO is the user's).
// Trace inputs: start (a frame starts; byte: the byte as queued, pol/pha/lsb its mode), stop
// (its tail ends).  pol_now: the host's current CPOL (the idle level between frames).
// Host rules:
//   * SCK is at CPOL when a frame starts, makes exactly 16 edges in it (the last may come in the
//     cycle the frame ends), and outside frames moves only to the idle level;
//   * every SCK edge of a frame has the selected CS asserted (cs_act);
//   * MOSI is stable across every sampling edge (PHA=0: leading, PHA=1: trailing), and the 8 bits
//     there are the frame's byte, MSB first (LSB first with lsb).
// Outputs: the monitor's state, for invariants.
`default_nettype none
module spi_host_mon #(parameter integer HOST_IS_DUT = 1) (
    input  wire       clk, rst,
    input  wire       sclk, mosi, cs_act,
    input  wire       start, input wire [7:0] byte_in, input wire pol, pha, lsb,
    input  wire       stop, pol_now,
    output reg        inf,                 // in a frame (from the cycle after its start)
    output reg        first,               // its first cycle
    output reg  [4:0] ne,                  // SCK edges so far
    output reg  [7:0] dec, output reg [3:0] ndec,   // sampled bits (wire order), how many
    output reg  [7:0] f_b, output reg f_pol, f_pha, f_lsb,
    output reg        sclk_q, mosi_q
);
    initial begin inf = 1'b0; first = 1'b0; ne = 5'd0; ndec = 4'd0; sclk_q = 1'b0; end
    reg pol_q = 1'b0, r_q = 1'b1;
    wire edg     = sclk != sclk_q;
    wire leading = edg && sclk_q == f_pol;
    wire smp     = f_pha ? (edg && !leading) : leading;
    wire fe      = inf && !first;          // the first cycle may show the idle level's change
    wire take    = fe && smp && ndec < 4'd8;
    wire [7:0] dec_n  = take ? {dec[6:0], mosi} : dec;
    wire [3:0] ndec_n = take ? ndec + 4'd1 : ndec;
    wire [4:0] ne_n   = (fe && edg) ? ne + 5'd1 : ne;
    wire [7:0] wire_b = f_lsb ? {f_b[0], f_b[1], f_b[2], f_b[3], f_b[4], f_b[5], f_b[6], f_b[7]} : f_b;
    always @(posedge clk) begin
        sclk_q <= sclk;  mosi_q <= mosi;  pol_q <= pol_now;  r_q <= rst;
        first <= start;
        if (inf) begin dec <= dec_n; ndec <= ndec_n; ne <= ne_n; end
        if (stop) inf <= 1'b0;
        if (start) begin
            inf <= 1'b1;  ne <= 5'd0;  ndec <= 4'd0;  dec <= 8'd0;
            f_b <= byte_in;  f_pol <= pol;  f_pha <= pha;  f_lsb <= lsb;
        end
        if (rst) begin inf <= 1'b0; first <= 1'b0; end
    end
    wire h_start = !first || sclk == f_pol;
    wire h_edges = !(fe && edg) || ne < 5'd16;
    wire h_cs    = !(fe && edg) || cs_act;
    wire h_hold  = !(fe && smp) || mosi == mosi_q;
    wire h_end   = !stop || (inf && ne_n == 5'd16 && ndec_n == 4'd8 && dec_n == wire_b);
    wire h_idle  = inf || first || !edg || sclk == pol_q;
    generate if (HOST_IS_DUT) begin : host
        always @(*) if (!rst && !r_q) begin
            assert (h_start); assert (h_edges); assert (h_cs); assert (h_hold); assert (h_end);
            assert (h_idle);
        end
    end endgenerate
endmodule
`default_nettype wire
