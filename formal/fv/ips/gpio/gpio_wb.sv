// gpio_wb: the checker for src/AXI4_GPIO.bsv (mkAXI4_GPIO), bound into the DUT (no RTL changes).
// Properties on the ports and the trace port:
//   AXI side:  axi4_sb_vip (single-beat AXI4, the GPIO is the subordinate)
//   registers: the window is the last init's [base, lim); an access outside it, or at an offset
//              of 8 or more, is DECERR (reads 0, writes nothing).  Offset 0 is LED (8 bits, lane 0,
//              written when strobe 0 is set); offset 4 is BTN (read only, BTN1 as sampled the cycle
//              before, in the upper 32-bit lane); other offsets in the window read 0 and ignore
//              writes, OKAY.  leds is LED.  Resets: RST_N clears LED and BTN; the reset method
//              (SoC soft reset) drops the requests and responses in flight and keeps LED.
//   handling:  tr_wr / tr_rd take the write (AW and W) / read at the head of the accepted ones, in
//              order; the response enters the B / R stream in that order, B with the write's id,
//              R with the read's id and RLAST.  A complete write (read) is handled in the first
//              cycle in which fewer than two of its responses wait.
//   master:    never issues a request; no interrupt.
//   assumed:   the manager's protocol; init's window at most 4 GiB with base <= lim, and no request
//              before the first init; the reset method only with no request presented in that
//              cycle (it resets the whole SoC).
// The INVARIANTS section names internals for k-induction only.
`default_nettype none
module gpio_wb (
    input wire        clk, rst_n, en_reset, en_init, input wire [63:0] init_base, init_lim,
    input wire        awvalid, awready, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire        wvalid, wready, input wire [63:0] wdata, input wire [7:0] wstrb,
    input wire        bvalid, bready, input wire [3:0] bid, input wire [1:0] bresp,
    input wire        arvalid, arready, input wire [3:0] arid, input wire [63:0] araddr,
    input wire        rvalid, rready, input wire [3:0] rid, input wire [63:0] rdata,
    input wire [1:0]  rresp, input wire rlast,
    input wire [7:0]  awlen, arlen,
    input wire        m_awvalid, m_wvalid, m_arvalid, irq,
    input wire [7:0]  leds, input wire btn1,
    input wire        tr_wr, tr_rd,
    // internals (induction only)
    input wire        awq_ne, input wire [96:0] awq_d,
    input wire        wq_ne, wq_nf, input wire [72:0] wq_d0, wq_d1,
    input wire        arq_ne, input wire [96:0] arq_d,
    input wire        rq_ne, rq_nf, input wire [70:0] rq_d0, rq_d1,
    input wire        bq_ne, bq_nf, input wire [5:0] bq_d0, bq_d1,
    input wire [63:0] g_base, g_lim, input wire [7:0] g_leds, input wire g_btn
);
    wire rst = !rst_n || en_reset;
    reg  r_q = 1'b1;
    always @(posedge clk) r_q <= rst;

    // ---------------- the protocol and the environment ----------------
    wire aw_hs, w_hs, b_hs, ar_hs, r_hs; wire [3:0] n_aw, n_w, n_ar;
    axi4_sb_vip #(.SUB_IS_DUT(1)) axi (.clk(clk), .rst(rst),
        .awvalid(awvalid), .awready(awready), .awid(awid), .awaddr(awaddr),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bid(bid), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .arid(arid), .araddr(araddr),
        .rvalid(rvalid), .rready(rready), .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .aw_hs(aw_hs), .w_hs(w_hs), .b_hs(b_hs), .ar_hs(ar_hs), .r_hs(r_hs),
        .n_aw(n_aw), .n_w(n_w), .n_ar(n_ar));
    // the window: the last init's
    reg known = 1'b0; reg [63:0] m_base, m_lim;
    always @(posedge clk) if (en_init) begin known <= 1'b1; m_base <= init_base; m_lim <= init_lim; end
    always @(*) begin
        assume (awlen == 8'd0 && arlen == 8'd0);               // single beats (the peripheral fabric)
        if (en_reset) assume (!awvalid && !wvalid && !arvalid);
        if (en_init) assume (init_base <= init_lim && init_lim - init_base <= 64'h1_0000_0000);
        if (!known) assume (!awvalid && !wvalid && !arvalid);
    end

    // ---------------- the registers ----------------
    reg [7:0] m_leds = 8'd0; reg m_btn = 1'b0;
    function [2:0] dec (input [63:0] a);           // {decerr, LED, BTN}
        reg [63:0] off;
        begin
            off = a - m_base;
            if (a < m_base || a >= m_lim || off >= 64'd8) dec = 3'b100;
            else dec = {1'b0, off[2:0] == 3'd0, off[2:0] == 3'd4};
        end
    endfunction

    // accepted requests, in order
    wire [67:0] aw_h; wire [3:0] aw_n; wire [71:0] w_h; wire [3:0] w_n; wire [67:0] ar_h; wire [3:0] ar_n;
    wire [287:0] w_e;
    fv_queue #(.W(68), .D(4)) qaw (.clk(clk), .rst(rst), .push(aw_hs), .din({awid, awaddr}),
        .pop(tr_wr), .head(aw_h), .n(aw_n), .full(), .ents());
    fv_queue #(.W(72), .D(4)) qw (.clk(clk), .rst(rst), .push(w_hs), .din({wdata, wstrb}),
        .pop(tr_wr), .head(w_h), .n(w_n), .full(), .ents(w_e));
    fv_queue #(.W(68), .D(4)) qar (.clk(clk), .rst(rst), .push(ar_hs), .din({arid, araddr}),
        .pop(tr_rd), .head(ar_h), .n(ar_n), .full(), .ents());
    wire [2:0] wd = dec(aw_h[63:0]), rd = dec(ar_h[63:0]);
    always @(posedge clk) begin
        if (tr_wr && wd[1] && w_h[0]) m_leds <= w_h[15:8];
        m_btn <= btn1;
        if (!rst_n) begin m_leds <= 8'd0; m_btn <= 1'b0; end
    end

    // expected responses, in order
    wire [5:0]  e_b = {aw_h[67:64], wd[2] ? 2'b11 : 2'b00};
    wire [63:0] e_v = rd[1] ? {56'd0, m_leds} : rd[0] ? {31'd0, m_btn, 32'd0} : 64'd0;
    wire [69:0] e_r = {ar_h[67:64], e_v, rd[2] ? 2'b11 : 2'b00};
    wire [5:0]  b_h; wire [3:0] b_n; wire [69:0] r_h; wire [3:0] r_n; wire [23:0] b_e; wire [279:0] r_e;
    fv_queue #(.W(6), .D(4)) qb (.clk(clk), .rst(rst), .push(tr_wr), .din(e_b),
        .pop(b_hs), .head(b_h), .n(b_n), .full(), .ents(b_e));
    fv_queue #(.W(70), .D(4)) qr (.clk(clk), .rst(rst), .push(tr_rd), .din(e_r),
        .pop(r_hs), .head(r_h), .n(r_n), .full(), .ents(r_e));

    always @(*) if (!rst && !r_q) begin
        if (tr_wr) assert (aw_n != 4'd0 && w_n != 4'd0);
        if (tr_rd) assert (ar_n != 4'd0);
        if (aw_n != 4'd0 && w_n != 4'd0 && b_n < 4'd2) assert (tr_wr);
        if (ar_n != 4'd0 && r_n < 4'd2) assert (tr_rd);
        if (bvalid) assert (b_n != 4'd0 && {bid, bresp} == b_h);
        if (rvalid) assert (r_n != 4'd0 && {rid, rdata, rresp} == r_h);
    end
    always @(*) if (rst_n) begin
        assert (leds == m_leds);
        assert (!m_awvalid && !m_wvalid && !m_arvalid && !irq);
    end

    // ---------------- reachability ----------------
    always @(*) if (!rst) begin
        cover (leds != 8'd0);                                       // an LED write landed
        cover (rvalid && rresp == 2'b00 && rdata[32]);              // BTN reads 1
        cover (rvalid && rresp == 2'b00 && rdata[7:0] != 8'd0);     // LED reads back
        cover (bvalid && bresp == 2'b11);                           // a DECERR write
        cover (bvalid && b_n == 4'd2);                              // two responses waiting
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    // the transactor's FIFOs (FIFO1: one entry; FIFO2: two, d0 the head) hold the queues above
    wire [3:0] c_aw = awq_ne ? 4'd1 : 4'd0, c_ar = arq_ne ? 4'd1 : 4'd0;
    wire [3:0] c_w  = !wq_ne ? 4'd0 : wq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_b  = !bq_ne ? 4'd0 : bq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_r  = !rq_ne ? 4'd0 : rq_nf ? 4'd1 : 4'd2;
    // also in reset-method cycles: the transactor and the queues above clear at the same edge
    always @(*) if (rst_n) begin
        assert ((wq_ne || wq_nf) && (rq_ne || rq_nf) && (bq_ne || bq_nf));   // FIFO2: never empty and full
        assert (aw_n == c_aw && ar_n == c_ar && w_n == c_w && b_n == c_b && r_n == c_r);
        if (awq_ne) assert (aw_h == {awq_d[96:93], awq_d[92:29]});
        if (arq_ne) assert (ar_h == {arq_d[96:93], arq_d[92:29]});
        if (c_w >= 4'd1) assert (w_e[71:0]   == wq_d0[72:1]);
        if (c_w >= 4'd2) assert (w_e[143:72] == wq_d1[72:1]);
        if (c_b >= 4'd1) assert (b_e[5:0]    == bq_d0);
        if (c_b >= 4'd2) assert (b_e[11:6]   == bq_d1);
        if (c_r >= 4'd1) assert (r_e[69:0]   == rq_d0[70:1] && rq_d0[0]);
        if (c_r >= 4'd2) assert (r_e[139:70] == rq_d1[70:1] && rq_d1[0]);
        assert (n_aw == aw_n + b_n && n_w == w_n + b_n && n_ar == ar_n + r_n);
        if (!known) assert (aw_n == 4'd0 && w_n == 4'd0 && ar_n == 4'd0 && b_n == 4'd0 && r_n == 4'd0
                            && n_aw == 4'd0 && n_w == 4'd0 && n_ar == 4'd0);
    end
    always @(*) if (rst_n) begin
        if (known) assert (g_base == m_base && g_lim == m_lim
                           && m_base <= m_lim && m_lim - m_base <= 64'h1_0000_0000);
        assert (g_leds == m_leds && g_btn == m_btn);
    end
`endif
endmodule

bind mkAXI4_GPIO gpio_wb wb (
    .clk(CLK), .rst_n(RST_N), .en_reset(EN_reset), .en_init(EN_init),
    .init_base(init_addr_base), .init_lim(init_addr_lim),
    .awvalid(slave_awvalid), .awready(slave_awready), .awid(slave_awid), .awaddr(slave_awaddr),
    .wvalid(slave_wvalid), .wready(slave_wready), .wdata(slave_wdata), .wstrb(slave_wstrb),
    .bvalid(slave_bvalid), .bready(slave_bready), .bid(slave_bid), .bresp(slave_bresp),
    .arvalid(slave_arvalid), .arready(slave_arready), .arid(slave_arid), .araddr(slave_araddr),
    .rvalid(slave_rvalid), .rready(slave_rready), .rid(slave_rid), .rdata(slave_rdata),
    .rresp(slave_rresp), .rlast(slave_rlast), .awlen(slave_awlen), .arlen(slave_arlen),
    .m_awvalid(master_awvalid), .m_wvalid(master_wvalid), .m_arvalid(master_arvalid), .irq(interrupt_req),
    .leds(leds), .btn1(btn1_v), .tr_wr(tr_wr), .tr_rd(tr_rd),
    .awq_ne(\slave_xactor_f_wr_addr$EMPTY_N ), .awq_d(\slave_xactor_f_wr_addr$D_OUT ),
    .wq_ne(\slave_xactor_f_wr_data$EMPTY_N ), .wq_nf(\slave_xactor_f_wr_data$FULL_N ),
    .wq_d0(\slave_xactor_f_wr_data$D_OUT ), .wq_d1(),
    .arq_ne(\slave_xactor_f_rd_addr$EMPTY_N ), .arq_d(\slave_xactor_f_rd_addr$D_OUT ),
    .rq_ne(\slave_xactor_f_rd_data$EMPTY_N ), .rq_nf(\slave_xactor_f_rd_data$FULL_N ),
    .rq_d0(\slave_xactor_f_rd_data$D_OUT ), .rq_d1(),
    .bq_ne(\slave_xactor_f_wr_resp$EMPTY_N ), .bq_nf(\slave_xactor_f_wr_resp$FULL_N ),
    .bq_d0(\slave_xactor_f_wr_resp$D_OUT ), .bq_d1(),     // the d1 ports: taps (gpio.cfg)
    .g_base(rg_addr_base), .g_lim(rg_addr_lim), .g_leds(rg_leds), .g_btn(rg_btn1));
`default_nettype wire
