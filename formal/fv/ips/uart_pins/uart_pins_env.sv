// uart_pins_env: an instance of src/Uart_Pins.bsv's mkUART_Pins (Uart_Pins_Fv.bsv: C clocks per bit
// by define, FV_CPB5 / FV_CPB50 / FV_CPB434, else 4) with every input free and one reset cycle; the
// checker (uart_pins_wb.sv) is bound into it.  FV_LINE: RXD comes from a well-formed peer
// transmitter (vip/uart/uart_line_src) instead, and uart_pins_e2e checks the bytes arrive.
`ifndef UP_C
`ifdef FV_CPB434
`define UP_TOP mkUART_Pins_434
`define UP_C 434
`elsif FV_CPB50
`define UP_TOP mkUART_Pins_50
`define UP_C 50
`elsif FV_CPB5
`define UP_TOP mkUART_Pins_5
`define UP_C 5
`else
`define UP_TOP mkUART_Pins_4
`define UP_C 4
`endif
`endif
`default_nettype none
module uart_pins_env (
    input wire       clk, en_put, en_get, rxd_free,
    input wire [7:0] put_d
);
    reg init = 1'b1;                           // one reset cycle (RST_N low)
    always @(posedge clk) init <= 1'b0;
    wire rxd;
    wire [8:0] tr_rx_byte; wire tr_rx_ferr, tr_rx_glitch;
`ifdef FV_LINE
    wire sent; wire [7:0] sent_byte;
    uart_line_src #(.C(`UP_C)) src (.clk(clk), .rst(init), .rxd(rxd), .sent(sent), .sent_byte(sent_byte));
    uart_pins_e2e e2e (.clk(clk), .rst(init), .sent(sent), .sent_byte(sent_byte),
        .tr_rx_byte(tr_rx_byte), .tr_rx_ferr(tr_rx_ferr), .tr_rx_glitch(tr_rx_glitch));
`else
    assign rxd = rxd_free;
`endif
    `UP_TOP dut (
        .CLK(clk), .RST_N(!init),
        .put_put(put_d), .EN_put_put(en_put), .RDY_put_put(),
        .EN_get_get(en_get), .get_get(), .RDY_get_get(),
        .txd(), .rxd_v(rxd), .rx_overflow(), .rx_frame_err(), .tx_busy(),
        .tr_tx_load(), .tr_tx_done(), .tr_rx_start(), .tr_rx_glitch(tr_rx_glitch), .tr_rx_bit(),
        .tr_rx_byte(tr_rx_byte), .tr_rx_ferr(tr_rx_ferr), .tr_rx_ovf());
endmodule
`default_nettype wire
