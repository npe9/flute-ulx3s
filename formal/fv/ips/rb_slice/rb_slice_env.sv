// rb_slice_env: the environment for src/Rb_Slice.v -- the upstream request and the downstream
// device's answer free (their rules are assumed by the checker's VIPs), one reset cycle.
`default_nettype none
module rb_slice_env (
    input wire        clk,
    input wire        up_valid, input wire up_we, input wire [31:0] up_addr,
    input wire [31:0] up_wdata, input wire [3:0] up_wstrb,
    input wire        dn_ack, input wire [31:0] dn_rdata
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    rb_slice dut (.clk(clk), .rst(init), .up_valid(up_valid), .up_we(up_we), .up_addr(up_addr),
        .up_wdata(up_wdata), .up_wstrb(up_wstrb), .up_ack(), .up_rdata(),
        .dn_valid(), .dn_we(), .dn_addr(), .dn_wdata(), .dn_wstrb(), .dn_ack(dn_ack),
        .dn_rdata(dn_rdata));
endmodule
`default_nettype wire
