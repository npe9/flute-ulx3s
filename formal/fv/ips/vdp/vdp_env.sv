// vdp_env: the environment for src/Vdp.v -- every bus input free, one reset cycle, the pixel
// clock tied to the system clock, and the scan counters of src/Video_DVI.v (800 x 525, video on)
// starting at an arbitrary position.  No checking here: the checker (vdp_wb.sv) is bound in.
`default_nettype none
module vdp_env (
    input wire        clk,
    input wire        rb_valid, input wire rb_we, input wire [31:0] rb_addr,
    input wire [31:0] rb_wdata, input wire [3:0] rb_wstrb
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    reg [9:0] hc, vc;                       // no initial value: any start position
    always @(*) assume (hc < 10'd800 && vc < 10'd525);
    always @(posedge clk)
        if (hc == 10'd799) begin hc <= 10'd0; vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1; end
        else hc <= hc + 10'd1;
    vdp dut (.clk(clk), .rst(init), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(), .rb_rdata(),
        .pclk(clk), .scan_hc(hc), .scan_vc(vc), .scan_on(1'b1), .idx(),
        .r_start(), .r_line(), .r_done());
endmodule
`default_nettype wire
