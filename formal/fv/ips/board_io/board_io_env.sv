// board_io_env: the environment for src/Board_IO.v -- the DUT with every input free (the I2C
// wires too: the bus model is i2c_host_mon's) and one reset cycle.  No checking here: the
// checker (board_io_wb.sv) is bound into the DUT.
`default_nettype none
module board_io_env (
    input wire        clk,
    input wire        rb_valid, input wire rb_we, input wire [15:0] rb_addr,
    input wire [31:0] rb_wdata, input wire [3:0] rb_wstrb,
    input wire [6:0]  btn_i, input wire [3:0] sw_i,
    input wire        esp32_tx_i, cec_i, hpd_i, util_i, scl_i, sda_i
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    board_io dut (.clk(clk), .rst(init), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(), .rb_rdata(),
        .btn_i(btn_i), .sw_i(sw_i), .esp32_tx_i(esp32_tx_i), .cec_i(cec_i), .hpd_i(hpd_i), .util_i(util_i),
        .scl_i(scl_i), .sda_i(sda_i), .scl_low(), .sda_low(), .esp32_en(), .esp32_strap(), .shutdown(),
        .reconf(), .cec_low(),
        .tr_cmd_valid(), .tr_cmd(), .tr_cmd_tx(), .tr_start(), .tr_stop(), .tr_rx_valid(), .tr_rx(),
        .tr_ack_valid(), .tr_ack(), .tr_done(), .tr_al(), .tr_abort());
endmodule
