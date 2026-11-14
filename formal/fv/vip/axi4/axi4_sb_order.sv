// axi4_sb_order: the in-order scoreboard of a single-beat AXI4 subordinate that handles one
// request at a time.  It queues accepted requests (AW, W, AR: from axi4_sb_vip's handshakes) until
// the DUT takes them (pop_w: an AW with its W; pop_r: an AR), and the responses the IP checker
// says the DUT made (push_b / push_r, with what they must carry) until they leave on B / R, and
// asserts each B / R beat is the oldest response owed on its channel.
// The heads (aw_h, w_h, ar_h) are the request the DUT is taking, for the IP checker's decode.
// Entries: AW / AR {id, addr[AW-1:0]}, W {data, strb}, B {id, resp}, R {id, data, resp}.
// ents / counts are outputs for invariants (D entries each, head first).
`default_nettype none
module axi4_sb_order #(parameter integer IW = 4, parameter integer AW = 32, parameter integer DW = 64,
                       parameter integer D = 4) (
    input  wire               clk, rst,
    input  wire               aw_hs, input wire [IW-1:0] awid, input wire [AW-1:0] awaddr,
    input  wire               w_hs, input wire [DW-1:0] wdata, input wire [DW/8-1:0] wstrb,
    input  wire               ar_hs, input wire [IW-1:0] arid, input wire [AW-1:0] araddr,
    input  wire               b_hs, bvalid, input wire [IW-1:0] bid, input wire [1:0] bresp,
    input  wire               r_hs, rvalid, input wire [IW-1:0] rid, input wire [DW-1:0] rdata,
    input  wire [1:0]         rresp,
    input  wire               pop_w, pop_r,
    input  wire               push_b, input wire [IW+1:0] b_din,
    input  wire               push_r, input wire [IW+DW+1:0] r_din,
    output wire [IW+AW-1:0]   aw_h, ar_h,
    output wire [DW+DW/8-1:0] w_h,
    output wire [3:0]         aw_n, w_n, ar_n, b_n, r_n,
    output wire [(DW+DW/8)*D-1:0]  w_e,
    output wire [(IW+2)*D-1:0]     b_e,
    output wire [(IW+DW+2)*D-1:0]  r_e,
    output wire [(IW+AW)*D-1:0]    aw_e, ar_e
);
    wire [IW+1:0] b_h; wire [IW+DW+1:0] r_h;
    fv_queue #(.W(IW+AW), .D(D)) qaw (.clk(clk), .rst(rst), .push(aw_hs), .din({awid, awaddr}),
        .pop(pop_w), .head(aw_h), .n(aw_n), .full(), .ents(aw_e));
    fv_queue #(.W(DW+DW/8), .D(D)) qw (.clk(clk), .rst(rst), .push(w_hs), .din({wdata, wstrb}),
        .pop(pop_w), .head(w_h), .n(w_n), .full(), .ents(w_e));
    fv_queue #(.W(IW+AW), .D(D)) qar (.clk(clk), .rst(rst), .push(ar_hs), .din({arid, araddr}),
        .pop(pop_r), .head(ar_h), .n(ar_n), .full(), .ents(ar_e));
    fv_queue #(.W(IW+2), .D(D)) qb (.clk(clk), .rst(rst), .push(push_b), .din(b_din),
        .pop(b_hs), .head(b_h), .n(b_n), .full(), .ents(b_e));
    fv_queue #(.W(IW+DW+2), .D(D)) qr (.clk(clk), .rst(rst), .push(push_r), .din(r_din),
        .pop(r_hs), .head(r_h), .n(r_n), .full(), .ents(r_e));
    reg r_q = 1'b1;
    always @(posedge clk) r_q <= rst;
    always @(*) if (!rst && !r_q) begin
        if (pop_w) assert (aw_n != 4'd0 && w_n != 4'd0);
        if (pop_r) assert (ar_n != 4'd0);
        if (bvalid) assert (b_n != 4'd0 && {bid, bresp} == b_h);
        if (rvalid) assert (r_n != 4'd0 && {rid, rdata, rresp} == r_h);
        assert (aw_n < D && w_n < D && ar_n < D && b_n < D && r_n < D);   // the queues suffice
    end
endmodule
`default_nettype wire
