// video_env: the environment for src/Video_DVI.v -- the DUT with every input free and one reset
// cycle, the pixel RAM shrunk to 36 words in 8-word banks (5 banks, a partial last one: the same
// bank muxes and decode as the 38400-word part), and one clock for both domains (as the
// Verilator benches run it).  No checking here: the checker (video_wb.sv) is bound into the DUT.
`default_nettype none
module video_env (
    input wire        clk,
    input wire        rb_valid, input wire rb_we, input wire [31:0] rb_addr,
    input wire [31:0] rb_wdata, input wire [3:0] rb_wstrb
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    video_fb #(.FB_WORDS(36), .BANK_BITS(3)) dut (.clk(clk), .rst(init), .rb_valid(rb_valid),
        .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(),
        .rb_rdata(), .pclk(clk), .tmds_r(), .tmds_g(), .tmds_b(), .ptog(), .dbg_rgb(), .dbg_de(),
        .dbg_hs(), .dbg_vs(), .tr_fb_wr(), .tr_fb_word(), .tr_fb_data(), .tr_fb_strb(), .tr_pal_wr(),
        .tr_pal_idx(), .tr_pal_data(), .tr_frame(), .tr_pix_de(), .tr_pix_x(), .tr_pix_y(), .tr_pix_rgb());
endmodule
`default_nettype wire
