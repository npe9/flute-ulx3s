// axi4_sb_vip: single-beat AXI4 (every AxLEN = 0, as the peripheral fabric issues) at one
// interface, in the style of the YosysHQ AXI4 FVIP (formal/axi4_fvip: one module, a role parameter
// picks which side's rules are assumed and which asserted; the vendored FVIP is the full-protocol
// reference, this is the subset a single-beat slave needs, small enough for k-induction).
//   manager (source) rules: AWVALID / WVALID / ARVALID held, payload stable, until READY; no
//     VALID during reset.
//   subordinate (destination) rules: BVALID / RVALID held, payload stable, until READY; RLAST on
//     every R beat; a B only once both its AW and W have been accepted, an R only for an accepted
//     AR (in counts: at most MAXOUT outstanding of each); no VALID during reset.
// SUB_IS_DUT=1: the DUT is the subordinate (manager rules assumed, subordinate rules asserted).
// The reset input is the AXI reset (here: the bridge's RST_N low, or its reset method).
// Outputs: the handshakes and outstanding counts, for the IP checker and its invariants.
`default_nettype none
module axi4_sb_vip #(parameter integer SUB_IS_DUT = 1, parameter integer IW = 4,
                     parameter integer AW = 64, parameter integer DW = 64,
                     parameter integer MAXOUT = 7) (
    input  wire          clk, rst,
    input  wire          awvalid, awready, input wire [IW-1:0] awid, input wire [AW-1:0] awaddr,
    input  wire          wvalid, wready, input wire [DW-1:0] wdata, input wire [DW/8-1:0] wstrb,
    input  wire          bvalid, bready, input wire [IW-1:0] bid, input wire [1:0] bresp,
    input  wire          arvalid, arready, input wire [IW-1:0] arid, input wire [AW-1:0] araddr,
    input  wire          rvalid, rready, input wire [IW-1:0] rid, input wire [DW-1:0] rdata,
    input  wire [1:0]    rresp, input wire rlast,
    output wire          aw_hs, w_hs, b_hs, ar_hs, r_hs,
    output reg  [3:0]    n_aw, n_w, n_ar        // accepted and not yet answered
);
    initial begin n_aw = 4'd0; n_w = 4'd0; n_ar = 4'd0; end
    assign aw_hs = awvalid && awready;  assign w_hs = wvalid && wready;  assign b_hs = bvalid && bready;
    assign ar_hs = arvalid && arready;  assign r_hs = rvalid && rready;
    reg r_q = 1'b1;
    reg awp = 1'b0, wp = 1'b0, arp = 1'b0, bp = 1'b0, rp = 1'b0;      // waiting for READY
    reg [IW-1:0] awid_q, arid_q, bid_q, rid_q; reg [AW-1:0] awaddr_q, araddr_q;
    reg [DW-1:0] wdata_q, rdata_q; reg [DW/8-1:0] wstrb_q; reg [1:0] bresp_q, rresp_q; reg rlast_q;
    always @(posedge clk) begin
        r_q <= rst;
        awp <= awvalid && !awready;  wp <= wvalid && !wready;  arp <= arvalid && !arready;
        bp  <= bvalid && !bready;    rp <= rvalid && !rready;
        awid_q <= awid; awaddr_q <= awaddr; wdata_q <= wdata; wstrb_q <= wstrb; arid_q <= arid;
        araddr_q <= araddr; bid_q <= bid; bresp_q <= bresp; rid_q <= rid; rdata_q <= rdata;
        rresp_q <= rresp; rlast_q <= rlast;
        n_aw <= n_aw + (aw_hs ? 4'd1 : 4'd0) - (b_hs ? 4'd1 : 4'd0);
        n_w  <= n_w  + (w_hs  ? 4'd1 : 4'd0) - (b_hs ? 4'd1 : 4'd0);
        n_ar <= n_ar + (ar_hs ? 4'd1 : 4'd0) - (r_hs ? 4'd1 : 4'd0);
        if (rst) begin awp <= 1'b0; wp <= 1'b0; arp <= 1'b0; bp <= 1'b0; rp <= 1'b0;
                       n_aw <= 4'd0; n_w <= 4'd0; n_ar <= 4'd0; end
    end
    // manager
    wire m_aw  = !awp || (awvalid && awid == awid_q && awaddr == awaddr_q);
    wire m_w   = !wp  || (wvalid && wdata == wdata_q && wstrb == wstrb_q);
    wire m_ar  = !arp || (arvalid && arid == arid_q && araddr == araddr_q);
    wire m_rst = !rst || (!awvalid && !wvalid && !arvalid);
    wire m_out = n_aw < MAXOUT && n_w < MAXOUT && n_ar < MAXOUT;      // a bounded manager
    // subordinate
    wire s_b    = !bp || (bvalid && bid == bid_q && bresp == bresp_q);
    wire s_r    = !rp || (rvalid && rid == rid_q && rdata == rdata_q && rresp == rresp_q && rlast == rlast_q);
    wire s_last = !rvalid || rlast;
    wire s_bown = !bvalid || (n_aw != 4'd0 && n_w != 4'd0);
    wire s_rown = !rvalid || n_ar != 4'd0;
    wire s_rst  = !rst || (!bvalid && !rvalid);
    generate if (SUB_IS_DUT) begin : sub
        always @(*) begin
            assume (m_rst);
            if (!rst) begin assume (m_aw); assume (m_w); assume (m_ar); assume (m_out); end
        end
        always @(*) if (!rst && !r_q) begin
            assert (s_b); assert (s_r); assert (s_last); assert (s_bown); assert (s_rown);
        end
    end else begin : mgr
        always @(*) if (!rst && !r_q) begin
            assert (m_aw); assert (m_w); assert (m_ar);
        end
        always @(*) if (!rst) begin
            assume (s_b); assume (s_r); assume (s_last); assume (s_bown); assume (s_rown);
        end
    end endgenerate
endmodule
`default_nettype wire
