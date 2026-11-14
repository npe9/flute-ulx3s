// regbus_wb: the checker for src/AXI4_RegBus.bsv (mkAXI4_RegBus_W), bound into the DUT (no RTL
// changes).  Properties on the ports and the trace port:
//   AXI side:  axi4_sb_vip (single-beat AXI4, the bridge is the subordinate)
//   bus side:  regbus_vip as the source (any device latency; the watchdog abandons a request)
//   bridge:    requests leave in AXI order, one at a time: a write's AW and W together, its word
//              address, its 32-bit lane and that lane's strobes; a write with no strobes in its lane
//              is answered OKAY at once without a bus request; rb_valid from the cycle after the
//              start until the cycle after it completes; it completes at the device's ack, or when
//              the watchdog (tr_wdog, the cycles since the start) reaches its limit with SLVERR
//              (reads 0); responses leave in the order they were made, B with the write's id, R
//              with the read's id and the word in its lane (the other lane 0), RLAST set
//   assumed:   the manager's and the device's protocols; the reset method only with no request
//              presented on either side in that cycle (it resets the whole SoC)
// The INVARIANTS section names internals for k-induction only.
`default_nettype none
module regbus_wb (
    input wire        clk, rst_n, en_reset, input wire [7:0] wd,
    input wire        awvalid, awready, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire        wvalid, wready, input wire [63:0] wdata, input wire [7:0] wstrb,
    input wire        bvalid, bready, input wire [3:0] bid, input wire [1:0] bresp,
    input wire        arvalid, arready, input wire [3:0] arid, input wire [63:0] araddr,
    input wire        rvalid, rready, input wire [3:0] rid, input wire [63:0] rdata,
    input wire [1:0]  rresp, input wire rlast,
    input wire [7:0]  awlen, arlen,
    input wire        rb_valid, rb_we, input wire [31:0] rb_addr, rb_wdata, input wire [3:0] rb_wstrb,
    input wire        ack, input wire [31:0] ack_rdata,
    input wire        tr_start, tr_skip, tr_we, tr_done, tr_timeout, input wire [7:0] tr_wdog,
    // internals (induction only)
    input wire        awq_ne, input wire [96:0] awq_d,
    input wire        wq_ne, wq_nf, input wire [72:0] wq_d0, wq_d1,
    input wire        arq_ne, input wire [96:0] arq_d,
    input wire        rq_ne, rq_nf, input wire [70:0] rq_d0, rq_d1,
    input wire        bq_ne, bq_nf, input wire [5:0] bq_d0, bq_d1,
    input wire [1:0]  st, input wire [31:0] g_addr, g_wdata, input wire [3:0] g_wstrb,
    input wire        g_hi, input wire [3:0] g_id
);
    wire rst = !rst_n || en_reset;
    reg  r_q = 1'b1;
    always @(posedge clk) r_q <= rst;

    // ---------------- the two protocols ----------------
    wire aw_hs, w_hs, b_hs, ar_hs, r_hs; wire [3:0] n_aw, n_w, n_ar;
    axi4_sb_vip #(.SUB_IS_DUT(1)) axi (.clk(clk), .rst(rst),
        .awvalid(awvalid), .awready(awready), .awid(awid), .awaddr(awaddr),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bid(bid), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .arid(arid), .araddr(araddr),
        .rvalid(rvalid), .rready(rready), .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .aw_hs(aw_hs), .w_hs(w_hs), .b_hs(b_hs), .ar_hs(ar_hs), .r_hs(r_hs),
        .n_aw(n_aw), .n_w(n_w), .n_ar(n_ar));
    wire b_tk, b_pend, b_we; wire [3:0] b_w; wire [31:0] b_a;
    regbus_vip #(.DUT_IS_DEST(0), .AW(32), .ANY_LAT(1)) bus (.clk(clk), .rst(rst), .abandon(tr_timeout),
        .valid(rb_valid), .we(rb_we), .addr(rb_addr), .wdata(rb_wdata), .wstrb(rb_wstrb), .ack(ack),
        .rdata(ack_rdata), .wr(), .wr_addr(), .wr_data(), .wr_strb(), .rd(), .rd_addr(), .rd_data(),
        .tk(b_tk), .pend(b_pend), .we_q(b_we), .w(b_w), .a_q(b_a));
    always @(*) begin
        assume (awlen == 8'd0 && arlen == 8'd0);               // single beats (the peripheral fabric)
        if (en_reset) assume (!awvalid && !wvalid && !arvalid && !ack);
    end

    // ---------------- the bridge ----------------
    // accepted requests, in order
    wire [35:0] aw_h; wire [3:0] aw_n;
    wire [71:0] w_h;  wire [3:0] w_n;
    wire [35:0] ar_h; wire [3:0] ar_n;
    wire pop_w = (tr_start || tr_skip) && tr_we, pop_r = tr_start && !tr_we;
    fv_queue #(.W(36), .D(4)) qaw (.clk(clk), .rst(rst), .push(aw_hs), .din({awid, awaddr[31:0]}),
        .pop(pop_w), .head(aw_h), .n(aw_n), .full(), .ents());
    wire [287:0] w_e;
    fv_queue #(.W(72), .D(4)) qw (.clk(clk), .rst(rst), .push(w_hs), .din({wdata, wstrb}),
        .pop(pop_w), .head(w_h), .n(w_n), .full(), .ents(w_e));
    fv_queue #(.W(36), .D(4)) qar (.clk(clk), .rst(rst), .push(ar_hs), .din({arid, araddr[31:0]}),
        .pop(pop_r), .head(ar_h), .n(ar_n), .full(), .ents());
    wire [31:0] h_addr = pop_w ? aw_h[31:0] : ar_h[31:0];
    wire        h_hi   = h_addr[2];
    wire [3:0]  h_id   = pop_w ? aw_h[35:32] : ar_h[35:32];
    wire [31:0] h_data = h_hi ? w_h[71:40] : w_h[39:8];
    wire [3:0]  h_strb = h_hi ? w_h[7:4] : w_h[3:0];

    // the request on the bus
    reg act = 1'b0, c_we; reg [31:0] c_addr, c_data; reg [3:0] c_strb, c_id; reg c_hi;
    reg [7:0] m_wd = 8'd0;
    always @(posedge clk) begin
        if (tr_start) begin
            act <= 1'b1;  c_we <= tr_we;  c_addr <= {h_addr[31:2], 2'b00};  c_hi <= h_hi;  c_id <= h_id;
            c_data <= h_data;  c_strb <= h_strb;  m_wd <= 8'd0;
        end else if (act && !tr_done) m_wd <= m_wd + 8'd1;
        if (tr_done) act <= 1'b0;
        if (rst) act <= 1'b0;
    end

    // expected responses, in order
    wire [5:0]  e_b  = tr_skip ? {aw_h[35:32], 2'b00} : {c_id, tr_timeout ? 2'b10 : 2'b00};
    wire [31:0] e_v  = tr_timeout ? 32'd0 : ack_rdata;
    wire [69:0] e_r  = {c_id, c_hi ? {e_v, 32'd0} : {32'd0, e_v}, tr_timeout ? 2'b10 : 2'b00};
    wire [5:0]  b_h; wire [3:0] b_n; wire [69:0] r_h; wire [3:0] r_n; wire [23:0] b_e; wire [279:0] r_e;
    fv_queue #(.W(6), .D(4)) qb (.clk(clk), .rst(rst), .push(tr_skip || (tr_done && c_we)), .din(e_b),
        .pop(b_hs), .head(b_h), .n(b_n), .full(), .ents(b_e));
    fv_queue #(.W(70), .D(4)) qr (.clk(clk), .rst(rst), .push(tr_done && !c_we), .din(e_r),
        .pop(r_hs), .head(r_h), .n(r_n), .full(), .ents(r_e));

    always @(*) if (!rst && !r_q) begin
        // starts: one at a time, in order, with the request at the head
        if (tr_start || tr_skip) assert (!act);
        if (tr_skip) assert (tr_we);
        if (pop_w) assert (aw_n != 4'd0 && w_n != 4'd0 && tr_skip == (h_strb == 4'd0));
        if (pop_r) assert (ar_n != 4'd0);
        // the bus request
        assert (rb_valid == act);
        if (act) assert (rb_we == c_we && rb_addr == c_addr && (!c_we || (rb_wdata == c_data && rb_wstrb == c_strb)));
        // completion: the ack, or the watchdog at its limit
        if (act) assert (tr_wdog == m_wd);
        assert (tr_done == (act && (ack || tr_wdog == wd)));
        assert (tr_timeout == (tr_done && !ack));
        // responses
        if (bvalid) assert (b_n != 4'd0 && {bid, bresp} == b_h);
        if (rvalid) assert (r_n != 4'd0 && {rid, rdata, rresp} == r_h);
    end

    // ---------------- reachability ----------------
    always @(*) if (!rst) begin
        cover (rb_valid && rb_we && ack);
        cover (rb_valid && !rb_we && ack);
        cover (bvalid && bresp == 2'b10);                          // a watchdog SLVERR
        cover (rvalid && rdata[63:32] != 0 && rdata[31:0] == 0);   // the upper lane
        cover (bvalid && b_n == 4'd2);                             // two responses waiting
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    // the transactor's FIFOs (FIFO1: one entry; FIFO2: two, d0 the head) hold the queues above
    wire [3:0] c_aw = awq_ne ? 4'd1 : 4'd0, c_ar = arq_ne ? 4'd1 : 4'd0;
    wire [3:0] c_w  = !wq_ne ? 4'd0 : wq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_b  = !bq_ne ? 4'd0 : bq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_r  = !rq_ne ? 4'd0 : rq_nf ? 4'd1 : 4'd2;
    wire [3:0] in_w = (act && c_we) ? 4'd1 : 4'd0, in_r = (act && !c_we) ? 4'd1 : 4'd0;
    always @(*) if (!rst && !r_q) begin
        assert ((wq_ne || wq_nf) && (rq_ne || rq_nf) && (bq_ne || bq_nf));   // FIFO2: never empty and full
        assert (aw_n == c_aw && ar_n == c_ar && w_n == c_w && b_n == c_b && r_n == c_r);
        if (awq_ne) assert (aw_h == {awq_d[96:93], awq_d[60:29]});
        if (arq_ne) assert (ar_h == {arq_d[96:93], arq_d[60:29]});
        if (c_w >= 4'd1) assert (w_e[71:0]   == wq_d0[72:1]);
        if (c_w >= 4'd2) assert (w_e[143:72] == wq_d1[72:1]);
        if (c_b >= 4'd1) assert (b_e[5:0]    == bq_d0);
        if (c_b >= 4'd2) assert (b_e[11:6]   == bq_d1);
        if (c_r >= 4'd1) assert (r_e[69:0]   == rq_d0[70:1] && rq_d0[0]);
        if (c_r >= 4'd2) assert (r_e[139:70] == rq_d1[70:1] && rq_d1[0]);
        // the request in progress
        assert ((st != 2'd0) == act && st != 2'd3);
        if (act) assert ((st == 2'd1) == c_we && g_addr == c_addr && (c_we || g_hi == c_hi) && g_id == c_id
                         && (!c_we || (g_wdata == c_data && g_wstrb == c_strb)) && m_wd <= wd);
        // the VIPs' counts
        assert (n_aw == aw_n + in_w + b_n && n_w == w_n + in_w + b_n && n_ar == ar_n + in_r + r_n);
        if (act) assert (c_we ? c_b <= 4'd1 : c_r <= 4'd1);     // a request starts with room for its answer
        assert (b_pend == (act && m_wd != 8'd0));
        if (b_pend) assert (b_we == c_we && b_a == c_addr);
    end
`endif
endmodule

bind mkAXI4_RegBus_W regbus_wb wb (
    .clk(CLK), .rst_n(RST_N), .en_reset(EN_reset), .wd(wdog_max),
    .awvalid(slave_awvalid), .awready(slave_awready), .awid(slave_awid), .awaddr(slave_awaddr),
    .wvalid(slave_wvalid), .wready(slave_wready), .wdata(slave_wdata), .wstrb(slave_wstrb),
    .bvalid(slave_bvalid), .bready(slave_bready), .bid(slave_bid), .bresp(slave_bresp),
    .arvalid(slave_arvalid), .arready(slave_arready), .arid(slave_arid), .araddr(slave_araddr),
    .rvalid(slave_rvalid), .rready(slave_rready), .rid(slave_rid), .rdata(slave_rdata),
    .rresp(slave_rresp), .rlast(slave_rlast), .awlen(slave_awlen), .arlen(slave_arlen),
    .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb),
    .ack(rb_ack_ack), .ack_rdata(rb_ack_rdata),
    .tr_start(tr_start), .tr_skip(tr_skip), .tr_we(tr_we), .tr_done(tr_done), .tr_timeout(tr_timeout),
    .tr_wdog(tr_wdog),
    .awq_ne(\slave_xactor_f_wr_addr$EMPTY_N ), .awq_d(\slave_xactor_f_wr_addr$D_OUT ),
    .wq_ne(\slave_xactor_f_wr_data$EMPTY_N ), .wq_nf(\slave_xactor_f_wr_data$FULL_N ),
    .wq_d0(\slave_xactor_f_wr_data$D_OUT ), .wq_d1(),
    .arq_ne(\slave_xactor_f_rd_addr$EMPTY_N ), .arq_d(\slave_xactor_f_rd_addr$D_OUT ),
    .rq_ne(\slave_xactor_f_rd_data$EMPTY_N ), .rq_nf(\slave_xactor_f_rd_data$FULL_N ),
    .rq_d0(\slave_xactor_f_rd_data$D_OUT ), .rq_d1(),
    .bq_ne(\slave_xactor_f_wr_resp$EMPTY_N ), .bq_nf(\slave_xactor_f_wr_resp$FULL_N ),
    .bq_d0(\slave_xactor_f_wr_resp$D_OUT ), .bq_d1(),     // the d1 ports: taps (regbus.cfg)
    .st(rg_state), .g_addr(rg_addr), .g_wdata(rg_wdata), .g_wstrb(rg_wstrb), .g_hi(rg_hi), .g_id(rg_id));
`default_nettype wire
