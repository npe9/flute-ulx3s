// rb_slice_wb: the checker for src/Rb_Slice.v, bound into the DUT.
//   upstream:   a device answering every request exactly 4 cycles after its take (the downstream
//               device's 2, plus the slice's two registers), never otherwise
//   downstream: a source (valid held with the request stable until ack, dropped the cycle
//               after), against a device that answers in 2 cycles (assumed)
//   transfers:  each upstream request reaches the device unchanged (we, address, data, strobes),
//               one downstream transfer per upstream one, and a read's data comes back unchanged
`default_nettype none
module rb_slice_wb (
    input wire        clk, rst,
    input wire        up_valid, up_we, input wire [31:0] up_addr, up_wdata, input wire [3:0] up_wstrb,
    input wire        up_ack, input wire [31:0] up_rdata,
    input wire        dn_valid, dn_we, input wire [31:0] dn_addr, dn_wdata, input wire [3:0] dn_wstrb,
    input wire        dn_ack, input wire [31:0] dn_rdata,
    // internals
    input wire        busy
);
    wire u_pend, u_we; wire [3:0] u_w; wire [31:0] u_a; wire u_tk;
    regbus_vip #(.DUT_IS_DEST(1), .AW(32), .RD_LAT(4), .WR_LAT(4)) up (.clk(clk), .rst(rst),
        .abandon(1'b0), .valid(up_valid), .we(up_we), .addr(up_addr), .wdata(up_wdata),
        .wstrb(up_wstrb), .ack(up_ack), .rdata(up_rdata), .wr(), .wr_addr(), .wr_data(),
        .wr_strb(), .rd(), .rd_addr(), .rd_data(), .tk(u_tk), .pend(u_pend), .we_q(u_we),
        .w(u_w), .a_q(u_a));
    wire d_pend, d_we; wire [3:0] d_w; wire [31:0] d_a; wire d_tk;
    regbus_vip #(.DUT_IS_DEST(0), .AW(32), .RD_LAT(2), .WR_LAT(2)) dn (.clk(clk), .rst(rst),
        .abandon(1'b0), .valid(dn_valid), .we(dn_we), .addr(dn_addr), .wdata(dn_wdata),
        .wstrb(dn_wstrb), .ack(dn_ack), .rdata(dn_rdata), .wr(), .wr_addr(), .wr_data(),
        .wr_strb(), .rd(), .rd_addr(), .rd_data(), .tk(d_tk), .pend(d_pend), .we_q(d_we),
        .w(d_w), .a_q(d_a));

    // the upstream request in flight, and the read data the device returned
    reg        q_we; reg [31:0] q_a, q_d, q_r; reg [3:0] q_s;
    always @(posedge clk) begin
        if (u_tk) begin q_we <= up_we; q_a <= up_addr; q_d <= up_wdata; q_s <= up_wstrb; end
        if (dn_valid && dn_ack) q_r <= dn_rdata;
    end
    // the downstream take is the upstream request, one cycle after its take
    always @(*) if (!rst && d_tk) begin
        assert (u_pend && u_w == 4'd1);
        assert (dn_we == q_we && dn_addr == q_a && dn_wstrb == q_s);
        if (q_we) assert (dn_wdata == q_d);
    end
    // a downstream request only for an upstream one
    always @(*) if (!rst && dn_valid) assert (u_pend);
    // read data passes unchanged
    always @(*) if (!rst && up_ack && !u_we) assert (up_rdata == q_r);

    always @(*) if (!rst) cover (up_ack && !u_we);
`ifndef FV_NO_INV
    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
    always @(*) if (!rst) begin
        assert (busy == u_pend);
        assert (dn_valid == (u_pend && u_w >= 4'd1 && u_w <= 4'd3));
        assert (!dn_valid || (d_pend || u_w == 4'd1));
        assert (d_pend == (u_pend && (u_w == 4'd2 || u_w == 4'd3)));
        if (d_pend) assert (d_w == u_w - 4'd1);
        if (u_pend) assert (u_we == q_we && u_a == q_a);
        if (d_pend) assert (d_we == q_we && d_a == q_a);
        if (dn_valid) assert (dn_we == q_we && dn_addr == q_a && dn_wstrb == q_s && dn_wdata == q_d);
    end
`endif
endmodule
bind rb_slice rb_slice_wb wb (
    .clk(clk), .rst(rst), .up_valid(up_valid), .up_we(up_we), .up_addr(up_addr),
    .up_wdata(up_wdata), .up_wstrb(up_wstrb), .up_ack(up_ack), .up_rdata(up_rdata),
    .dn_valid(dn_valid), .dn_we(dn_we), .dn_addr(dn_addr), .dn_wdata(dn_wdata),
    .dn_wstrb(dn_wstrb), .dn_ack(dn_ack), .dn_rdata(dn_rdata), .busy(busy));
`default_nettype wire
