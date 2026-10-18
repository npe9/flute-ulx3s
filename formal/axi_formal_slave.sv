// Minimal AXI4 slave for formal: accepts one read burst at a time and
// answers with unconstrained data; accepts writes (AW/W in any order) and
// returns OKAY.  Protocol-correct enough for Flute's L1 cache adapters
// (in-order per ID, rlast on beat arlen, no errors).  Set STALL=1 to let
// the solver insert arbitrary ready/valid stalls.
module axi_formal_slave #(
    parameter ID_W = 4, DATA_W = 64, ADDR_W = 64, STALL = 0
) (
    input  wire               clock, reset,
    input  wire               awvalid, output wire              awready,
    input  wire [ID_W-1:0]    awid,    input  wire [ADDR_W-1:0] awaddr, input wire [7:0] awlen,
    input  wire               wvalid,  output wire              wready,
    input  wire               wlast,
    output wire               bvalid,  input  wire              bready,
    output wire [ID_W-1:0]    bid,     output wire [1:0]        bresp,
    input  wire               arvalid, output wire              arready,
    input  wire [ID_W-1:0]    arid,    input  wire [ADDR_W-1:0] araddr, input wire [7:0] arlen,
    output wire               rvalid,  input  wire              rready,
    output wire [ID_W-1:0]    rid,     output wire [DATA_W-1:0] rdata,
    output wire [1:0]         rresp,   output wire              rlast
);
    (* keep *) `rvformal_rand_reg [DATA_W-1:0] rand_rdata;
    (* keep *) `rvformal_rand_reg               rand_stall_ar, rand_stall_r, rand_stall_aw, rand_stall_w, rand_stall_b;
    wire st_ar = STALL ? rand_stall_ar : 1'b0;
    wire st_r  = STALL ? rand_stall_r  : 1'b0;
    wire st_aw = STALL ? rand_stall_aw : 1'b0;
    wire st_w  = STALL ? rand_stall_w  : 1'b0;
    wire st_b  = STALL ? rand_stall_b  : 1'b0;

    // ---- read channel: one burst in flight ----
    reg            rd_busy;
    reg [ID_W-1:0] rd_id;
    reg [7:0]      rd_len, rd_beat;
    assign arready = !rd_busy && !st_ar;
    assign rvalid  = rd_busy && !st_r;
    assign rid     = rd_id;
    assign rdata   = rand_rdata;
    assign rresp   = 2'b00;
    assign rlast   = rd_busy && (rd_beat == rd_len);
    always @(posedge clock) begin
        if (reset) begin
            rd_busy <= 0; rd_beat <= 0; rd_id <= 0; rd_len <= 0;
        end else begin
            if (arvalid && arready) begin
                rd_busy <= 1; rd_id <= arid; rd_len <= arlen; rd_beat <= 0;
            end
            if (rvalid && rready) begin
                if (rd_beat == rd_len) rd_busy <= 0;
                else rd_beat <= rd_beat + 1;
            end
        end
    end

    // ---- write channel: AW and W may arrive in either order ----
    reg            aw_seen, w_seen, b_pend;
    reg [ID_W-1:0] wr_id;
    assign awready = !aw_seen && !b_pend && !st_aw;
    assign wready  = !w_seen  && !b_pend && !st_w;
    assign bvalid  = b_pend && !st_b;
    assign bid     = wr_id;
    assign bresp   = 2'b00;
    always @(posedge clock) begin
        if (reset) begin
            aw_seen <= 0; w_seen <= 0; b_pend <= 0; wr_id <= 0;
        end else begin
            if (awvalid && awready) begin aw_seen <= 1; wr_id <= awid; end
            if (wvalid && wready && wlast) w_seen <= 1;
            if ((aw_seen || (awvalid && awready)) && (w_seen || (wvalid && wready && wlast)) && !b_pend) begin
                b_pend <= 1; aw_seen <= 0; w_seen <= 0;
            end
            if (bvalid && bready) b_pend <= 0;
        end
    end
endmodule
