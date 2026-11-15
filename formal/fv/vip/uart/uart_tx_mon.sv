// uart_tx_mon: an 8N1 UART transmitter's TXD pin against its frame trace, C clocks per bit.
// start (with byte) says a frame begins: from the next clock TXD carries the start bit (0) for C
// clocks, then byte's bits LSB first, C clocks each, then the stop bit (1) for C clocks.  Outside a
// frame TXD is idle (1).  A new frame may start at the frame's last clock (a stop bit of exactly C)
// or later; never earlier.
// Outputs for the user's properties and invariants: act (a frame is on the wire this clock), seg
// (0 start, 1..8 data bit seg-1, 9 stop), cnt (clocks into seg), last (the frame's last clock),
// sh (the frame's bits, {stop, byte, start}), exp (TXD's expected level).
// en: the user's assertion enable (out of reset).  rst: the monitor's reset (no frame).
`default_nettype none
module uart_tx_mon #(parameter integer C = 4, parameter integer CW = 16) (
    input  wire          clk, rst, en,
    input  wire          txd,
    input  wire          start, input wire [7:0] byte_in,
    output reg           act,
    output reg  [3:0]    seg,
    output reg  [CW-1:0] cnt,
    output reg  [9:0]    sh,
    output wire          last,
    output wire          exp
);
    initial begin act = 1'b0; seg = 4'd0; cnt = 0; sh = 10'h3FF; end
    assign last = act && seg == 4'd9 && cnt == C - 1;
    assign exp  = act ? sh[seg] : 1'b1;
    always @(posedge clk) begin
        if (act) begin
            if (cnt == C - 1) begin cnt <= 0; seg <= seg + 4'd1; if (seg == 4'd9) act <= 1'b0; end
            else cnt <= cnt + 1'b1;
        end
        if (start) begin act <= 1'b1; seg <= 4'd0; cnt <= 0; sh <= {1'b1, byte_in, 1'b0}; end
        if (rst) begin act <= 1'b0; seg <= 4'd0; cnt <= 0; end
    end
    always @(*) if (en) begin
        assert (txd == exp);
        if (start) assert (!act || last);                  // no frame cut short
        if (act) assert (seg <= 4'd9 && cnt < C);
    end
endmodule
`default_nettype wire
