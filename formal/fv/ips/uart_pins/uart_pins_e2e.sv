// uart_pins_e2e: with RXD from a well-formed peer (uart_line_src, the same bit time), every byte
// sent is received, in order, with no glitch or framing error, and at most two are ever in flight.
`default_nettype none
module uart_pins_e2e (
    input wire clk, rst, sent, input wire [7:0] sent_byte,
    input wire [8:0] tr_rx_byte, input wire tr_rx_ferr, tr_rx_glitch
);
    wire [7:0] h; wire [3:0] n;
    fv_queue #(.W(8), .D(4)) q (.clk(clk), .rst(rst), .push(sent), .din(sent_byte),
        .pop(tr_rx_byte[8]), .head(h), .n(n), .full(), .ents());
    always @(*) if (!rst) begin
        if (tr_rx_byte[8]) assert (n != 4'd0 && tr_rx_byte[7:0] == h);
        assert (!tr_rx_ferr && !tr_rx_glitch);
        assert (n <= 4'd2);
        cover (n == 4'd0 && tr_rx_byte[8] && tr_rx_byte[7:0] == 8'h3C);   // a second byte, back to back
    end
endmodule
`default_nettype wire
