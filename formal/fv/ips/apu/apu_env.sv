// apu_env: the environment for src/Apu.v -- every bus input free, one reset cycle.  The real tick
// (1563 clocks) for the proofs; FV_MEM (the bounded memory check) uses an 8-clock tick so that
// queued writes are applied within the bound (the deadline is not checked there).
`default_nettype none
module apu_env (
    input wire        clk,
    input wire        rb_valid, input wire rb_we, input wire [31:0] rb_addr,
    input wire [31:0] rb_wdata, input wire [3:0] rb_wstrb
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
`ifdef FV_MEM
    localparam integer T = 8;
`else
    localparam integer T = 1563;
`endif
    apu #(.TICK(T)) dut (.clk(clk), .rst(init), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(), .rb_rdata(), .out_l(), .out_r(),
        .tr_tick(), .tr_busy(), .tr_done(), .tr_level(), .tr_apply(), .tr_apply_a(), .tr_apply_s(),
        .tr_apply_d());
endmodule
`default_nettype wire
