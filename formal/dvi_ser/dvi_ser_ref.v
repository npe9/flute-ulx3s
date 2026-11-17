// Reference: src/Video_DVI.v dvi_ser before lx49 (one shared load decode), for the
// equivalence proof in formal/dvi_ser/equiv.ys.  Not built into the SoC.
`default_nettype none
module dvi_ser_ref (
    input  wire       sclk,         // 5x pixel clock (125 MHz), same PLL as the pixel clock
    input  wire       ptog,
    input  wire [9:0] tmds_r,
    input  wire [9:0] tmds_g,
    input  wire [9:0] tmds_b,
    output wire [3:0] gpdi_dp       // [0] blue, [1] green, [2] red, [3] clock
);
    reg       t1 = 0, t2 = 0;
    reg [2:0] ph = 0;
    reg [9:0] sr = 0, sg = 0, sb = 0, sc = 0;
    always @(posedge sclk) begin
        t1 <= ptog;
        t2 <= t1;
        ph <= (t1 != t2) ? 3'd0 : ph + 1;
        if (ph == 3'd1) begin
            sr <= tmds_r; sg <= tmds_g; sb <= tmds_b; sc <= 10'b0000011111;
        end else begin
            sr <= sr >> 2; sg <= sg >> 2; sb <= sb >> 2; sc <= sc >> 2;
        end
    end
    ODDRX1F ddr_b (.D0(sb[0]), .D1(sb[1]), .SCLK(sclk), .RST(1'b0), .Q(gpdi_dp[0]));
    ODDRX1F ddr_g (.D0(sg[0]), .D1(sg[1]), .SCLK(sclk), .RST(1'b0), .Q(gpdi_dp[1]));
    ODDRX1F ddr_r (.D0(sr[0]), .D1(sr[1]), .SCLK(sclk), .RST(1'b0), .Q(gpdi_dp[2]));
    ODDRX1F ddr_c (.D0(sc[0]), .D1(sc[1]), .SCLK(sclk), .RST(1'b0), .Q(gpdi_dp[3]));
endmodule
