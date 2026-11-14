// spi_wb: the checker for src/AXI4_SPI.bsv (mkAXI4_SPI), bound into the DUT (no RTL changes).
// Properties on the ports and the trace port:
//   AXI side:  axi4_sb_vip (single-beat AXI4, the SPI is the subordinate) and axi4_sb_order
//              (requests handled in order, one response each, in order)
//   decode:    the window init set ([base, lim), offsets below 0x80, DECERR otherwise); a write
//              with any strobe in its 32-bit lane writes the register (the register model below,
//              reset values as documented); reads return it in the lane, the other lane 0
//   FIFOs:     TXDATA queues its byte unless 8 are queued (then dropped; reads FULL); a frame
//              starts with the oldest byte whenever none is running; RXDATA pops the oldest byte
//              (EMPTY when none); a frame pushes its received byte unless DIR or 8 are held
//   frame:     ends 17 (SCKDIV + 1) cycles after its start (SCKDIV, mode, bit order, DIR as
//              when it started); with MISO looped back the byte received is the byte sent
//   wires:     spi_host_mon (CPOL idle, 16 edges, sampling-edge data, MSB / LSB first) on the
//              selected CS; cs_n each cycle from the previous one's state: the selected CS
//              asserted during a frame or a HOLD (from a frame with CSMODE HOLD until CSID,
//              CSMODE or the selected CSDEF bit changes value), CSMODE OFF never; the flash
//              (CS 1) always active low
//   IRQ:       interrupt_req = IE & {RX level > RXMARK, TX level < TXMARK}, a cycle late
//   assumed:   the AXI manager's protocol; nothing on the bus before init; SCKDIV <= 1 while a
//              frame is queued or running (frame length within proof depth)
// The INVARIANTS section names internals for k-induction only.
`default_nettype none
module spi_wb (
    input wire        clk, rst_n, en_init, input wire [63:0] init_base, init_lim,
    input wire        awvalid, awready, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire        wvalid, wready, input wire [63:0] wdata, input wire [7:0] wstrb,
    input wire        bvalid, bready, input wire [3:0] bid, input wire [1:0] bresp,
    input wire        arvalid, arready, input wire [3:0] arid, input wire [63:0] araddr,
    input wire        rvalid, rready, input wire [3:0] rid, input wire [63:0] rdata,
    input wire [1:0]  rresp, input wire rlast, input wire [7:0] awlen, arlen,
    input wire        irq, sclk, mosi, input wire [1:0] cs_n,
    input wire        tr_wr, tr_rd, input wire [8:0] tr_tx_enq, tr_frame_start,
    input wire        tr_frame_end, input wire [8:0] tr_rx_push, tr_rx_pop,
    // internals (induction only)
    input wire [3:0]  i_tx_wp, i_tx_rp, i_rx_wp, i_rx_rp, input wire [63:0] i_v_tx, i_v_rx,
    input wire        i_busy, input wire [4:0] i_edge, input wire [11:0] i_cnt, i_f_div,
    input wire [7:0]  i_sh_tx, i_sh_rx, input wire i_f_pha, i_f_endian, i_f_dir,
    input wire        i_miso0_q, i_miso1_q, i_hold, input wire [3:0] i_hold_gen, i_cs_gen,
    input wire [11:0] i_sckdiv, input wire [1:0] i_sckmode, input wire [31:0] i_csid,
    input wire [1:0]  i_csdef, i_csmode, input wire [31:0] i_delay0, i_delay1,
    input wire        i_endian, i_dir, input wire [1:0] i_proto, input wire [3:0] i_len,
    input wire [2:0]  i_txmark, i_rxmark, input wire i_fctrl, input wire [31:0] i_ffmt,
    input wire [1:0]  i_ie, input wire [63:0] i_base, i_lim,
    input wire        awq_ne, input wire [96:0] awq_d,
    input wire        wq_ne, wq_nf, input wire [72:0] wq_d0, wq_d1,
    input wire        arq_ne, input wire [96:0] arq_d,
    input wire        rq_ne, rq_nf, input wire [70:0] rq_d0, rq_d1,
    input wire        bq_ne, bq_nf, input wire [5:0] bq_d0, bq_d1
);
    wire rst = !rst_n;
    reg  r_q = 1'b1;
    always @(posedge clk) r_q <= rst;
    integer k;

    // ---------------- init ----------------
    reg inited = 1'b0; reg [63:0] m_base, m_lim;
    always @(posedge clk) begin
        if (en_init) begin inited <= 1'b1; m_base <= init_base; m_lim <= init_lim; end
        if (rst) inited <= 1'b0;
    end

    // ---------------- AXI ----------------
    wire aw_hs, w_hs, b_hs, ar_hs, r_hs; wire [3:0] n_aw, n_w, n_ar;
    axi4_sb_vip #(.SUB_IS_DUT(1)) axi (.clk(clk), .rst(rst),
        .awvalid(awvalid), .awready(awready), .awid(awid), .awaddr(awaddr),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bid(bid), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .arid(arid), .araddr(araddr),
        .rvalid(rvalid), .rready(rready), .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .aw_hs(aw_hs), .w_hs(w_hs), .b_hs(b_hs), .ar_hs(ar_hs), .r_hs(r_hs),
        .n_aw(n_aw), .n_w(n_w), .n_ar(n_ar));
    always @(*) begin
        assume (awlen == 8'd0 && arlen == 8'd0);
        if (!inited) assume (!awvalid && !wvalid && !arvalid);
    end
    wire [67:0] aw_h, ar_h; wire [71:0] w_h; wire [3:0] aw_n, w_n, ar_n, b_n, r_n;
    wire [287:0] w_e; wire [23:0] b_e; wire [279:0] r_e; wire [271:0] aw_e, ar_e;
    wire [5:0] b_din; wire [69:0] r_din;
    axi4_sb_order #(.AW(64)) ord (.clk(clk), .rst(rst),
        .aw_hs(aw_hs), .awid(awid), .awaddr(awaddr), .w_hs(w_hs), .wdata(wdata), .wstrb(wstrb),
        .ar_hs(ar_hs), .arid(arid), .araddr(araddr),
        .b_hs(b_hs), .bvalid(bvalid), .bid(bid), .bresp(bresp),
        .r_hs(r_hs), .rvalid(rvalid), .rid(rid), .rdata(rdata), .rresp(rresp),
        .pop_w(tr_wr), .pop_r(tr_rd), .push_b(tr_wr), .b_din(b_din), .push_r(tr_rd), .r_din(r_din),
        .aw_h(aw_h), .ar_h(ar_h), .w_h(w_h), .aw_n(aw_n), .w_n(w_n), .ar_n(ar_n), .b_n(b_n), .r_n(r_n),
        .w_e(w_e), .b_e(b_e), .r_e(r_e), .aw_e(aw_e), .ar_e(ar_e));

    // ---------------- decode ----------------
    wire [63:0] wa = aw_h[63:0], wba = wa - m_base;
    wire        w_ok = wa >= m_base && wa < m_lim && wba[11:7] == 5'd0;
    wire        w_hi = wba[2];
    wire [31:0] w32  = w_hi ? w_h[71:40] : w_h[39:8];
    wire [3:0]  wst  = w_hi ? w_h[7:4] : w_h[3:0];
    wire [6:0]  woff = {wba[6:2], 2'b00};
    wire        wr   = tr_wr && w_ok && wst != 4'd0;
    assign b_din = {aw_h[67:64], w_ok ? 2'b00 : 2'b11};
    wire [63:0] ra = ar_h[63:0], rba = ra - m_base;
    wire        r_ok = ra >= m_base && ra < m_lim && rba[11:7] == 5'd0;
    wire        r_hi = rba[2];
    wire [6:0]  roff = {rba[6:2], 2'b00};

    // ---------------- register model ----------------
    reg [11:0] s_sckdiv = 12'd3; reg [1:0] s_sckmode = 2'd0; reg [31:0] s_csid = 32'd0;
    reg [1:0]  s_csdef = 2'd3, s_csmode = 2'd0; reg [31:0] s_delay0 = 32'h0001_0001, s_delay1 = 32'd1;
    reg [1:0]  s_proto = 2'd0; reg s_endian = 1'b0, s_dir = 1'b0; reg [3:0] s_len = 4'd8;
    reg [2:0]  s_txmark = 3'd0, s_rxmark = 3'd0; reg s_fctrl = 1'b1; reg [31:0] s_ffmt = 32'd0;
    reg [1:0]  s_ie = 2'd0; reg [3:0] m_gen = 4'd0;
    always @(posedge clk) begin
        if (wr) case (woff)
            7'h00: s_sckdiv <= w32[11:0];
            7'h04: s_sckmode <= w32[1:0];
            7'h10: begin s_csid <= w32; if (w32 != s_csid) m_gen <= m_gen + 4'd1; end
            7'h14: begin s_csdef <= w32[1:0]; if (w32[s_csid[0]] != s_csdef[s_csid[0]]) m_gen <= m_gen + 4'd1; end
            7'h18: begin s_csmode <= w32[1:0]; if (w32[1:0] != s_csmode) m_gen <= m_gen + 4'd1; end
            7'h28: s_delay0 <= w32;
            7'h2c: s_delay1 <= w32;
            7'h40: begin s_proto <= w32[1:0]; s_endian <= w32[2]; s_dir <= w32[3]; s_len <= w32[19:16]; end
            7'h50: s_txmark <= w32[2:0];
            7'h54: s_rxmark <= w32[2:0];
            7'h60: s_fctrl <= w32[0];
            7'h64: s_ffmt <= w32;
            7'h70: s_ie <= w32[1:0];
            default: ;
        endcase
        if (rst) begin
            s_sckdiv <= 12'd3; s_sckmode <= 2'd0; s_csid <= 32'd0; s_csdef <= 2'd3; s_csmode <= 2'd0;
            s_delay0 <= 32'h0001_0001; s_delay1 <= 32'd1; s_proto <= 2'd0; s_endian <= 1'b0;
            s_dir <= 1'b0; s_len <= 4'd8; s_txmark <= 3'd0; s_rxmark <= 3'd0; s_fctrl <= 1'b1;
            s_ffmt <= 32'd0; s_ie <= 2'd0; m_gen <= 4'd0;
        end
    end

    // ---------------- FIFOs ----------------
    wire [7:0] tx_h, rx_h; wire [3:0] tx_n, rx_n; wire [63:0] tx_e, rx_e;
    wire tx_push = wr && woff == 7'h48 && tx_n != 4'd8;
    fv_queue #(.W(8), .D(8)) qtx (.clk(clk), .rst(rst), .push(tx_push), .din(w32[7:0]),
        .pop(tr_frame_start[8]), .head(tx_h), .n(tx_n), .full(), .ents(tx_e));
    fv_queue #(.W(8), .D(8)) qrx (.clk(clk), .rst(rst), .push(tr_rx_push[8]), .din(tr_rx_push[7:0]),
        .pop(tr_rx_pop[8]), .head(rx_h), .n(rx_n), .full(), .ents(rx_e));
    wire txwm = tx_n < {1'b0, s_txmark}, rxwm = rx_n > {1'b0, s_rxmark};

    // reads
    reg [31:0] rv;
    always @(*) begin
        case (roff)
            7'h00: rv = {20'd0, s_sckdiv};
            7'h04: rv = {30'd0, s_sckmode};
            7'h10: rv = s_csid;
            7'h14: rv = {30'd0, s_csdef};
            7'h18: rv = {30'd0, s_csmode};
            7'h28: rv = s_delay0;
            7'h2c: rv = s_delay1;
            7'h40: rv = {12'd0, s_len, 12'd0, s_dir, s_endian, s_proto};
            7'h48: rv = {tx_n == 4'd8, 31'd0};
            7'h4c: rv = (rx_n == 4'd0) ? 32'h8000_0000 : {24'd0, rx_h};
            7'h50: rv = {29'd0, s_txmark};
            7'h54: rv = {29'd0, s_rxmark};
            7'h60: rv = {31'd0, s_fctrl};
            7'h64: rv = s_ffmt;
            7'h70: rv = {30'd0, s_ie};
            7'h74: rv = {30'd0, rxwm, txwm};
            default: rv = 32'd0;
        endcase
        if (!r_ok) rv = 32'd0;
    end
    assign r_din = {ar_h[67:64], r_hi ? {rv, 32'd0} : {32'd0, rv}, r_ok ? 2'b00 : 2'b11};

    // ---------------- frames ----------------
    reg m_busy = 1'b0, f_dir = 1'b0; reg [7:0] f_byte; reg [11:0] f_div; reg [16:0] m_t = 17'd0;
    wire start = tr_frame_start[8];
    wire [16:0] f_len = 17'd17 * ({5'd0, f_div} + 17'd1);
    always @(posedge clk) begin
        if (m_busy) m_t <= m_t + 17'd1;
        if (tr_frame_end) m_busy <= 1'b0;
        if (start) begin
            m_busy <= 1'b1;  m_t <= 17'd1;  f_byte <= tr_frame_start[7:0];  f_div <= s_sckdiv;
            f_dir <= s_dir;
        end
        if (rst) m_busy <= 1'b0;
    end
    always @(*) if (inited && (m_busy || tx_n != 4'd0)) assume (s_sckdiv <= 12'd1);

    // ---------------- chip selects ----------------
    reg m_hold = 1'b0; reg [3:0] m_hold_gen = 4'd0;
    wire hold_now  = m_hold && s_csmode == 2'd2 && m_hold_gen == m_gen;
    wire hold_next = hold_now || (start && s_csmode == 2'd2);
    wire busy_next = start || (m_busy && !tr_frame_end);
    wire active    = s_csmode != 2'd3 && (busy_next || hold_next);
    wire [1:0] e_cs = {!(active && s_csid == 32'd1), (active && s_csid == 32'd0) ? !s_csdef[0] : s_csdef[0]};
    reg  [1:0] e_cs_q = 2'b11; reg [31:0] csid_q = 32'd0; reg [1:0] csdef_q = 2'd3, csmode_q = 2'd0;
    reg  e_irq_q = 1'b0;
    always @(posedge clk) begin
        m_hold <= hold_next;
        if (start && s_csmode == 2'd2) m_hold_gen <= m_gen;
        e_cs_q <= e_cs;  csid_q <= s_csid;  csdef_q <= s_csdef;  csmode_q <= s_csmode;
        e_irq_q <= (s_ie[0] && txwm) || (s_ie[1] && rxwm);
        if (rst) begin m_hold <= 1'b0; m_hold_gen <= 4'd0; e_cs_q <= 2'b11; e_irq_q <= 1'b0; end
    end
    wire cs_act = csmode_q == 2'd3 || csid_q > 32'd1 ||
                  (csid_q == 32'd0 && cs_n[0] == !csdef_q[0]) || (csid_q == 32'd1 && !cs_n[1]);

    // ---------------- the wires ----------------
    wire mon_inf, mon_first, mon_pol, mon_pha, mon_lsb, mon_sclk_q, mon_mosi_q;
    wire [4:0] mon_ne; wire [7:0] mon_dec, mon_b; wire [3:0] mon_ndec;
    spi_host_mon #(.HOST_IS_DUT(1)) mon (.clk(clk), .rst(rst), .sclk(sclk), .mosi(mosi), .cs_act(cs_act),
        .start(start), .byte_in(tr_frame_start[7:0]), .pol(s_sckmode[1]), .pha(s_sckmode[0]),
        .lsb(s_endian), .stop(tr_frame_end), .pol_now(s_sckmode[1]),
        .inf(mon_inf), .first(mon_first), .ne(mon_ne), .dec(mon_dec), .ndec(mon_ndec), .f_b(mon_b),
        .f_pol(mon_pol), .f_pha(mon_pha), .f_lsb(mon_lsb), .sclk_q(mon_sclk_q), .mosi_q(mon_mosi_q));

    // ---------------- the spec ----------------
    always @(*) if (!rst && !r_q) begin
        // TX
        assert (tr_tx_enq[8] == tx_push);
        if (tx_push) assert (tr_tx_enq[7:0] == w32[7:0]);
        assert (start == (!m_busy && tx_n != 4'd0));
        if (start) assert (tr_frame_start[7:0] == tx_h);
        // frame end, RX
        assert (tr_frame_end == (m_busy && m_t == f_len));
        assert (tr_rx_push[8] == (tr_frame_end && !f_dir && rx_n != 4'd8));
        if (tr_rx_push[8]) assert (tr_rx_push[7:0] == f_byte);
        assert (tr_rx_pop[8] == (tr_rd && r_ok && roff == 7'h4c && rx_n != 4'd0));
        if (tr_rx_pop[8]) assert (tr_rx_pop[7:0] == rx_h);
        // pins
        assert (cs_n == e_cs_q);
        assert (irq == e_irq_q);
    end

    // ---------------- reachability ----------------
    always @(*) if (!rst) begin
        cover (tr_rx_pop[8]);                                          // a byte read back
        cover (tr_frame_end && mon_pha && mon_pol && mon_lsb);         // mode 3, LSB first
        cover (!cs_n[0] && !m_busy && s_csmode == 2'd2);               // HOLD after a frame
        cover (!cs_n[1] && m_busy);                                    // a flash frame
        cover (bvalid && bresp == 2'b11);                              // DECERR
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    // AXI: the transactor's FIFOs hold the scoreboard's queues (FIFO1 one entry, FIFO2 two)
    wire [3:0] c_aw = awq_ne ? 4'd1 : 4'd0, c_ar = arq_ne ? 4'd1 : 4'd0;
    wire [3:0] c_w  = !wq_ne ? 4'd0 : wq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_b  = !bq_ne ? 4'd0 : bq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_r  = !rq_ne ? 4'd0 : rq_nf ? 4'd1 : 4'd2;
    // frames: the shifters and wires against the frame's byte as it goes out (wire order)
    wire [7:0] wire_b = mon_lsb ? {mon_b[0], mon_b[1], mon_b[2], mon_b[3], mon_b[4], mon_b[5], mon_b[6], mon_b[7]} : mon_b;
    wire [3:0] e_half = i_edge[4:1];
    wire [3:0] e_m1   = e_half - 4'd1;
    wire [3:0] n_cap  = i_f_pha ? ((i_edge == 5'd0) ? 4'd0 : (i_edge[0] ? e_half : e_m1)) : e_half;
    wire [4:0] ne_now = mon_ne + ((!mon_first && sclk != mon_sclk_q) ? 5'd1 : 5'd0);
    wire [3:0] n_smp  = mon_pha ? mon_ne[4:1] : (mon_ne[4:1] + {3'd0, mon_ne[0]});
    wire [16:0] e_t   = 17'd1 + {12'd0, i_edge} * ({5'd0, f_div} + 17'd1) + {5'd0, f_div - i_cnt};
    always @(*) if (!rst && !r_q) begin
        assert (inited);                      // the env's init comes in the cycle after reset
        assert (i_base == m_base && i_lim == m_lim);
        // registers
        assert (i_sckdiv == s_sckdiv && i_sckmode == s_sckmode && i_csid == s_csid && i_csdef == s_csdef
                && i_csmode == s_csmode && i_delay0 == s_delay0 && i_delay1 == s_delay1
                && i_proto == s_proto && i_endian == s_endian && i_dir == s_dir && i_len == s_len
                && i_txmark == s_txmark && i_rxmark == s_rxmark && i_fctrl == s_fctrl
                && i_ffmt == s_ffmt && i_ie == s_ie);
        assert (i_cs_gen == m_gen && i_hold == m_hold && i_hold_gen == m_hold_gen);
        // FIFOs
        assert (tx_n <= 4'd8 && rx_n <= 4'd8);
        assert (tx_n == i_tx_wp - i_tx_rp && rx_n == i_rx_wp - i_rx_rp);
        for (k = 0; k < 8; k = k + 1) begin
            if (k < tx_n) assert (tx_e[8*k +: 8] == i_v_tx[8*((i_tx_rp + k) % 8) +: 8]);
            if (k < rx_n) assert (rx_e[8*k +: 8] == i_v_rx[8*((i_rx_rp + k) % 8) +: 8]);
        end
        // AXI
        assert ((wq_ne || wq_nf) && (rq_ne || rq_nf) && (bq_ne || bq_nf));
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
        // the frame
        assert (i_busy == m_busy && mon_inf == m_busy);
        assert (i_miso0_q == mon_mosi_q && i_miso1_q == mon_mosi_q);
        if (!m_busy) assert (!mon_first);
        if (m_busy) begin
            assert (i_f_div == f_div && i_f_dir == f_dir && i_f_pha == mon_pha && i_f_endian == mon_lsb && f_byte == mon_b);
            assert (f_div <= 12'd1 && i_cnt <= f_div && i_edge <= 5'd16 && m_t == e_t);
            assert (mon_first == (m_t == 17'd1));
            assert (sclk == (mon_pol ^ i_edge[0]));
            if (!mon_first) assert (ne_now == i_edge && mon_ne <= 5'd16);
            if (mon_first) assert (mon_ne == 5'd0 && mon_ndec == 4'd0);
            assert (mon_ndec == n_smp);
            assert ((mon_dec & ((8'd1 << mon_ndec) - 8'd1)) == (wire_b >> (4'd8 - mon_ndec)));
            if (!mon_pha) assert (i_sh_tx == (wire_b << e_half));
            else          assert (i_sh_tx == (wire_b << (e_half + {3'd0, i_edge[0]})));
            if (!mon_pha && i_edge < 5'd16) assert (mosi == wire_b[3'd7 - e_half[2:0]]);
            if (mon_pha && i_edge[0])       assert (mosi == wire_b[3'd7 - e_half[2:0]]);
            if (mon_pha && !i_edge[0] && i_edge != 5'd0) assert (mosi == wire_b[3'd7 - e_m1[2:0]] && mon_mosi_q == mosi);
            if (!mon_pha && i_edge[0]) assert (mon_mosi_q == wire_b[3'd7 - e_half[2:0]]);
            assert ((i_sh_rx & ((8'd1 << n_cap) - 8'd1)) == (wire_b >> (4'd8 - n_cap)));
        end
    end
`endif
endmodule

bind mkAXI4_SPI spi_wb wb (
    .clk(CLK), .rst_n(RST_N), .en_init(EN_init), .init_base(init_addr_base), .init_lim(init_addr_lim),
    .awvalid(slave_awvalid), .awready(slave_awready), .awid(slave_awid), .awaddr(slave_awaddr),
    .wvalid(slave_wvalid), .wready(slave_wready), .wdata(slave_wdata), .wstrb(slave_wstrb),
    .bvalid(slave_bvalid), .bready(slave_bready), .bid(slave_bid), .bresp(slave_bresp),
    .arvalid(slave_arvalid), .arready(slave_arready), .arid(slave_arid), .araddr(slave_araddr),
    .rvalid(slave_rvalid), .rready(slave_rready), .rid(slave_rid), .rdata(slave_rdata),
    .rresp(slave_rresp), .rlast(slave_rlast), .awlen(slave_awlen), .arlen(slave_arlen),
    .irq(interrupt_req), .sclk(sclk), .mosi(mosi), .cs_n(cs_n),
    .tr_wr(tr_wr), .tr_rd(tr_rd), .tr_tx_enq(tr_tx_enq), .tr_frame_start(tr_frame_start),
    .tr_frame_end(tr_frame_end), .tr_rx_push(tr_rx_push), .tr_rx_pop(tr_rx_pop),
    .i_tx_wp(rg_tx_wp), .i_tx_rp(rg_tx_rp), .i_rx_wp(rg_rx_wp), .i_rx_rp(rg_rx_rp),
    .i_v_tx({v_tx_7, v_tx_6, v_tx_5, v_tx_4, v_tx_3, v_tx_2, v_tx_1, v_tx_0}),
    .i_v_rx({v_rx_7, v_rx_6, v_rx_5, v_rx_4, v_rx_3, v_rx_2, v_rx_1, v_rx_0}),
    .i_busy(rg_busy), .i_edge(rg_edge), .i_cnt(rg_cnt), .i_f_div(rg_f_div), .i_sh_tx(rg_sh_tx),
    .i_sh_rx(rg_sh_rx), .i_f_pha(rg_f_pha), .i_f_endian(rg_f_endian), .i_f_dir(rg_f_dir),
    .i_miso0_q(rg_miso0_q), .i_miso1_q(rg_miso1_q), .i_hold(rg_hold), .i_hold_gen(rg_hold_gen),
    .i_cs_gen(rg_cs_gen), .i_sckdiv(rg_sckdiv), .i_sckmode(rg_sckmode), .i_csid(rg_csid),
    .i_csdef(rg_csdef), .i_csmode(rg_csmode), .i_delay0(rg_delay0), .i_delay1(rg_delay1),
    .i_endian(rg_fmt_endian), .i_dir(rg_fmt_dir), .i_proto(rg_fmt_proto), .i_len(rg_fmt_len),
    .i_txmark(rg_txmark), .i_rxmark(rg_rxmark), .i_fctrl(rg_fctrl), .i_ffmt(rg_ffmt), .i_ie(rg_ie),
    .i_base(rg_addr_base), .i_lim(rg_addr_lim),
    .awq_ne(\slave_xactor_f_wr_addr$EMPTY_N ), .awq_d(\slave_xactor_f_wr_addr$D_OUT ),
    .wq_ne(\slave_xactor_f_wr_data$EMPTY_N ), .wq_nf(\slave_xactor_f_wr_data$FULL_N ),
    .wq_d0(\slave_xactor_f_wr_data$D_OUT ), .wq_d1(),
    .arq_ne(\slave_xactor_f_rd_addr$EMPTY_N ), .arq_d(\slave_xactor_f_rd_addr$D_OUT ),
    .rq_ne(\slave_xactor_f_rd_data$EMPTY_N ), .rq_nf(\slave_xactor_f_rd_data$FULL_N ),
    .rq_d0(\slave_xactor_f_rd_data$D_OUT ), .rq_d1(),
    .bq_ne(\slave_xactor_f_wr_resp$EMPTY_N ), .bq_nf(\slave_xactor_f_wr_resp$FULL_N ),
    .bq_d0(\slave_xactor_f_wr_resp$D_OUT ), .bq_d1());     // the d1 ports: taps (spi.cfg)
`default_nettype wire
