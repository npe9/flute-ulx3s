// sim/vdp_ut/vdp_tb.v: src/Vdp.v with the scan counters video_fb gives it (800 x 525, the same
// stage-0 timing as src/Video_DVI.v), and those counters delayed to stage 2 so the bench can
// pair each idx with its pixel.
module vdp_tb (
    input  wire        clk, rst, pclk,
    input  wire        rb_valid, rb_we,
    input  wire [31:0] rb_addr, rb_wdata,
    input  wire [3:0]  rb_wstrb,
    output wire        rb_ack,
    output wire [31:0] rb_rdata,
    output wire [7:0]  idx,
    output reg  [9:0]  hc2, vc2,       // the counters of the pixel idx belongs to
    output wire [9:0]  hc0, vc0,
    output wire        r_start, r_done,
    output wire [7:0]  r_line
);
    reg [9:0] hc = 0, vc = 0;
    always @(posedge pclk) begin
        if (hc == 799) begin hc <= 0; vc <= (vc == 524) ? 10'd0 : vc + 1; end
        else hc <= hc + 1;
    end
    reg [9:0] hc1 = 0, vc1 = 0;
    always @(posedge pclk) begin hc1 <= hc; vc1 <= vc; hc2 <= hc1; vc2 <= vc1; end
    assign hc0 = hc; assign vc0 = vc;
    vdp dut (
        .clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr),
        .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata),
        .pclk(pclk), .scan_hc(hc), .scan_vc(vc), .scan_on(1'b1), .idx(idx),
        .r_start(r_start), .r_line(r_line), .r_done(r_done)
    );
endmodule
