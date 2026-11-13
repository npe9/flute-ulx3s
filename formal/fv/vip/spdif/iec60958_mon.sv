// iec60958_mon: IEC 60958 (S/PDIF, consumer, 16-bit PCM) checker on a transmitter's output pin,
// against the subframes the transmitter's trace port says it is sending (sf_*: one event per
// subframe, the clock before its first cell; whether that content is right is the IP's spec).
// The transmitter is locked to a sample tick: each tick starts a frame of 128 biphase-mark cells
// (2 subframes x 32 slots x 2 cells) spread over PERIOD clocks, cell k beginning at the first clock
// c after the tick with 128 * c >= k * PERIOD.  Checked at every clock after the first tick:
//   * a subframe event exactly at the tick (left) and on entering cell 64 (right);
//   * the output changes only at a cell boundary;
//   * slots 0-3: preamble B (frame 0 of 192) / M (other left) / W (right), each relative to the
//     level before it (inverted after a 1);
//   * slots 4-31: a transition at every slot start; a mid-slot transition exactly for a 1: slots
//     4-11 0, 12-27 the subframe's 16-bit sample (LSB first), 28 V = 0, 29 U = 0, 30 its channel
//     status bit, 31 even parity over 4-31;
//   * data never holds a level for 3 cells (the preambles do).
// Before the first tick the output is low.  Outputs its state for a checker's invariants.
`default_nettype none
module iec60958_mon (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,
    input  wire [16:0] period,
    input  wire        sf_valid,     // the transmitter's trace: a subframe starts
    input  wire        sf_right,
    input  wire [7:0]  sf_frame,
    input  wire [15:0] sf_sample,
    input  wire        sf_cs,
    input  wire        out,
    output reg         started = 1'b0,
    output reg  [16:0] kc = 17'd0,   // clocks since the tick
    output reg  [6:0]  hc,           // cell index
    output reg  [15:0] ws,           // this subframe's sample, channel status bit, preamble B
    output reg         wcs, wb,
    output reg         hbase,        // level before this subframe's preamble
    output reg         hpar,         // parity of the decoded slots 4 .. so far, this subframe
    output reg         prev, prev2,  // the previous two cells' levels
    output wire        step          // a new cell starts at the next clock
);
    // cell hc + 1 starts at clock kc + 1 when 128 (kc + 1) >= (hc + 1) PERIOD
    wire bnd = ({7'd0, kc} + 24'd1) * 24'd128 >= ({17'd0, hc} + 24'd1) * {7'd0, period};
    assign step = tick || (started && hc != 7'd127 && bnd);
    wire [4:0]  slot = hc[5:1];
    wire        t    = (out != prev);              // a transition into this cell
    function automatic [7:0] pat (input right_sf, input first);
        pat = right_sf ? 8'b11100100 : (first ? 8'b11101000 : 8'b11100010);
    endfunction
    reg out_q;
    reg step_q;

    always @(posedge clk) begin
        out_q <= out; step_q <= step;
        kc <= (rst || tick) ? 17'd0 : kc + 17'd1;
        if (tick) started <= 1'b1;
        if (step) begin prev <= out; prev2 <= prev; end
        if (sf_valid) begin ws <= sf_sample; wcs <= sf_cs; wb <= !sf_right && sf_frame == 8'd0; end
        if (tick) begin
            hc <= 7'd0; hbase <= out; hpar <= 1'b0;
        end else if (step) begin
            hc <= hc + 7'd1;
            if (hc[5:0] == 6'd63) begin hbase <= out; hpar <= 1'b0; end
            if (hc[0] && slot >= 5'd4 && slot <= 5'd30) hpar <= hpar ^ t;   // leaving a data slot's 2nd half
        end
        if (rst) begin
            started <= 1'b0; prev <= 1'b0; prev2 <= 1'b0; hc <= 7'd127;
            hbase <= 1'b0; hpar <= 1'b0; step_q <= 1'b0;
        end
    end

    always @(*) if (!rst) begin
        assert (sf_valid == (tick || (started && step && hc == 7'd63)));
        if (sf_valid) assert (sf_right == !tick);
        if (!started) assert (!out);
        else begin
            if (!step_q) assert (out == out_q);                        // changes only at a boundary
            if (slot < 5'd4)
                assert (out == (((pat (hc[6], wb) >> (3'd7 - hc[2:0])) & 8'd1) ^ hbase));
            else if (!hc[0])
                assert (t);                                            // every slot starts with a transition
            else begin
                if (slot <= 5'd11) assert (!t);
                if (slot >= 5'd12 && slot <= 5'd27) assert (t == ws[slot - 5'd12]);
                if (slot == 5'd28 || slot == 5'd29) assert (!t);
                if (slot == 5'd30) assert (t == wcs);
                if (slot == 5'd31) assert (t == hpar);                 // even parity over 4-31
            end
            if (slot >= 5'd5 || (slot == 5'd4 && hc[0])) assert (!(out == prev && prev == prev2));
        end
    end
    always @(*) if (started) cover (hc == 7'd20 && out != prev);      // into slot 10
endmodule
