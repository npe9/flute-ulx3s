// uart_line_src: a well-formed 8N1 UART line (a peer transmitter), C clocks per bit, for driving a
// receiver's RXD.  Idle is 1; at any idle clock (go) a frame may start with any byte: from the next
// clock the start bit for C clocks, the byte LSB first, the stop bit for C clocks.  The next frame
// may start at the stop bit's last clock (back to back) or after any idle gap.  sent / sent_byte:
// the frame begun this clock (for the user's scoreboard).  No jitter: the bit time is exactly C.
`default_nettype none
module uart_line_src #(parameter integer C = 4, parameter integer CW = 16) (
    input  wire       clk, rst,
    output wire       rxd,
    output wire       sent, output wire [7:0] sent_byte
);
    (* anyseq *) reg go; (* anyseq *) reg [7:0] b;
    reg act = 1'b0; reg [3:0] seg = 4'd0; reg [CW-1:0] cnt = 0; reg [9:0] sh = 10'h3FF;
    wire last = act && seg == 4'd9 && cnt == C - 1;
    assign sent = go && (!act || last) && !rst;
    assign sent_byte = b;
    assign rxd = act ? sh[seg] : 1'b1;
    always @(posedge clk) begin
        if (act) begin
            if (cnt == C - 1) begin cnt <= 0; seg <= seg + 4'd1; if (seg == 4'd9) act <= 1'b0; end
            else cnt <= cnt + 1'b1;
        end
        if (sent) begin act <= 1'b1; seg <= 4'd0; cnt <= 0; sh <= {1'b1, b, 1'b0}; end
        if (rst) begin act <= 1'b0; seg <= 4'd0; cnt <= 0; end
    end
endmodule
`default_nettype wire
