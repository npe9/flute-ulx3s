// audio_env: the environment for src/Audio.v (with its src/Spdif_Tx.v) -- the DUT with every
// input free and one reset cycle.  No checking here: the checker (audio_wb.sv) is bound into it.
`default_nettype none
module audio_env (
    input wire        clk,
    input wire        rb_valid, input wire rb_we, input wire [11:0] rb_addr,
    input wire [31:0] rb_wdata, input wire [3:0] rb_wstrb
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    // RATE_RESET = 2 (the FPGA build: 1133) so a sample time comes within cover depth
    audio #(.RATE_RESET(16'd2)) dut (.clk(clk), .rst(init), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(), .rb_rdata(),
        .audio_l(), .audio_r(), .audio_v());
endmodule
