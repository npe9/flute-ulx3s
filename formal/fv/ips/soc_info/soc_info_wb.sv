// soc_info_wb: the checker for src/SoC_Info.bsv (mkSoC_Info), bound into the DUT (no RTL changes).
// Properties on the ports and the trace port, for the build fvgen compiles (the SoC's default
// defines: Accel0, SPI0/2, UART1 and video in; no SYS_CLK_HZ, so mtime ticks at clk_hz):
//   AXI side:  axi4_sb_vip (single-beat AXI4, SoC_Info is the subordinate)
//   window:    the last init's [base, lim); outside it a write is DECERR and changes nothing, a
//              read is DECERR with data 0.
//   registers (32-bit, offset from base; a read returns the whole 64-bit word, offset 4 in the
//   upper lane):
//     0x00 MAGIC 0x464C5331  0x04 VERSION 1  0x08 BUILD_DATE (YYYYMMDD in 20200101..20991231:
//     the build bakes in its date, which the checker cannot know)
//     0x0C FEATURES 0x9F  0x10 CPU_HZ = clk_hz  0x14 TIMER_HZ = clk_hz  0x18 MEMORY_SIZE 32 MiB
//     0x1C DEVICE_COUNT 16  0x20 DEVICE_TABLE 0x100  0x24 RESET_REASON 0
//     0x28 BUSERR_STATUS {resp, master, is_wr, captured}  0x2C BUSERR_COUNT  0x30 / 0x34
//     BUSERR_ADDR lo / hi  0x38 0  0x3C 0 (BUSERR_CLEAR: any write clears count and captured)
//     0x40.. 0x4C PERF_SELECT_0..3 (4 bits; a write sets it from its offset's lane)
//     0x80.. 0x8C PERF_COUNT_0..3 (any write clears it)
//     0x100.. the device ROM: record r (8 words) = type, 1, base, size, irq (0xFF none), flags, 0,
//              0 for the 16 regions below, 0 past them; every other offset reads 0.
//   bus errors: note_err counts (saturating at 2^32-1) and, when nothing is captured, captures
//              the event.  A BUSERR_CLEAR handled in the same cycle wins over the count.
//   perf:      counter i adds 1 per cycle (saturating) when PERF_SELECT_i is 0, or when it is 1..7
//              and that event (retire, imiss, dmiss, ext irq, uart irq, redirect, bus error) was
//              noted in the cycle before; 8..15 freeze it.  A clear in the same cycle wins.
//   handling:  tr_wr takes the write at the head; tr_rd_addr the read at the head, with the window
//              decided then; tr_rd answers the oldest of those, with the registers as they are in
//              that cycle.  Responses in order, B with the write's id, R with the read's and
//              RLAST.  A complete write is handled, and a read moves on, in the first cycle with
//              room for it (two queued reads, two responses).
//   resets:    RST_N clears every register; the reset method (SoC soft reset) drops the requests,
//              queued reads and responses in flight and keeps the registers.
//   assumed:   the manager's protocol; init's window at most 4 GiB with base <= lim, and no request
//              before the first init; the reset method only with no request presented then.
// The INVARIANTS section names internals for k-induction only.
`default_nettype none
module soc_info_wb (
    input wire        clk, rst_n, en_reset, en_init, input wire [63:0] init_base, init_lim,
    input wire [31:0] hz,
    input wire        awvalid, awready, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire        wvalid, wready, input wire [63:0] wdata, input wire [7:0] wstrb,
    input wire        bvalid, bready, input wire [3:0] bid, input wire [1:0] bresp,
    input wire        arvalid, arready, input wire [3:0] arid, input wire [63:0] araddr,
    input wire        rvalid, rready, input wire [3:0] rid, input wire [63:0] rdata,
    input wire [1:0]  rresp, input wire rlast,
    input wire [7:0]  awlen, arlen,
    input wire        en_err, input wire [74:0] err_e,
    input wire        en_retire, en_imiss, en_dmiss, en_ext_irq, en_uart_irq, en_redirect,
    input wire        tr_wr, tr_rd_addr, tr_rd,
    // internals (induction only)
    input wire        awq_ne, input wire [96:0] awq_d,
    input wire        wq_ne, wq_nf, input wire [72:0] wq_d0, wq_d1,
    input wire        arq_ne, input wire [96:0] arq_d,
    input wire        rq_ne, rq_nf, input wire [70:0] rq_d0, rq_d1,
    input wire        bq_ne, bq_nf, input wire [5:0] bq_d0, bq_d1,
    input wire        pq_ne, pq_nf, input wire [68:0] pq_d0, pq_d1,
    input wire [63:0] g_base, g_lim,
    input wire [31:0] g_count, input wire g_valid, g_iswr, input wire [7:0] g_master,
    input wire [1:0]  g_resp, input wire [63:0] g_addr,
    input wire [15:0] g_sel, input wire [127:0] g_cnt, input wire [6:0] g_ev
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
    reg known = 1'b0; reg [63:0] m_base, m_lim;
    always @(posedge clk) if (en_init) begin known <= 1'b1; m_base <= init_base; m_lim <= init_lim; end
    always @(*) begin
        assume (awlen == 8'd0 && arlen == 8'd0);               // single beats (the peripheral fabric)
        if (en_reset) assume (!awvalid && !wvalid && !arvalid);
        if (en_init) assume (init_base <= init_lim && init_lim - init_base <= 64'h1_0000_0000);
        if (!known) assume (!awvalid && !wvalid && !arvalid);
    end
    function inwin (input [63:0] a); inwin = a >= m_base && a < m_lim; endfunction

    // ---------------- the register model ----------------
    reg [31:0] m_count = 32'd0; reg m_valid = 1'b0, m_iswr = 1'b0; reg [7:0] m_master = 8'd0;
    reg [1:0]  m_resp = 2'd0; reg [63:0] m_addr = 64'd0;
    reg [3:0]  m_sel [0:3]; reg [31:0] m_cnt [0:3];
    reg [6:0]  m_ev = 7'd0;                       // the events noted in the cycle before
    integer k;
    initial for (k = 0; k < 4; k = k + 1) begin m_sel[k] = 4'd0; m_cnt[k] = 32'd0; end

    // the register file as software reads it (one instance per 32-bit lane, below)
    wire [15:0]  m_sel_v = {m_sel[3], m_sel[2], m_sel[1], m_sel[0]};
    wire [127:0] m_cnt_v = {m_cnt[3], m_cnt[2], m_cnt[1], m_cnt[0]};

    // accepted requests, in order; reads waiting for their answer (window decided)
    wire [67:0] aw_h; wire [3:0] aw_n; wire [71:0] w_h; wire [3:0] w_n; wire [67:0] ar_h; wire [3:0] ar_n;
    wire [287:0] w_e; wire [68:0] p_h; wire [3:0] p_n; wire [275:0] p_e;
    fv_queue #(.W(68), .D(4)) qaw (.clk(clk), .rst(rst), .push(aw_hs), .din({awid, awaddr}),
        .pop(tr_wr), .head(aw_h), .n(aw_n), .full(), .ents());
    fv_queue #(.W(72), .D(4)) qw (.clk(clk), .rst(rst), .push(w_hs), .din({wdata, wstrb}),
        .pop(tr_wr), .head(w_h), .n(w_n), .full(), .ents(w_e));
    fv_queue #(.W(68), .D(4)) qar (.clk(clk), .rst(rst), .push(ar_hs), .din({arid, araddr}),
        .pop(tr_rd_addr), .head(ar_h), .n(ar_n), .full(), .ents());
    fv_queue #(.W(69), .D(4)) qp (.clk(clk), .rst(rst), .push(tr_rd_addr),
        .din({ar_h[67:64], inwin(ar_h[63:0]), ar_h[63:0] - m_base}),
        .pop(tr_rd), .head(p_h), .n(p_n), .full(), .ents(p_e));

    // the write at the head
    wire        w_in  = inwin(aw_h[63:0]);
    wire [31:0] w_off = aw_h[31:0] - m_base[31:0];
    wire [31:0] w_32  = w_off[2] ? w_h[71:40] : w_h[39:8];
    wire        w_clr = tr_wr && w_in && w_off == 32'd60;
    wire        w_sel = tr_wr && w_in && w_off >= 32'd64 && w_off <= 32'd76;
    wire        w_cc  = tr_wr && w_in && w_off >= 32'd128 && w_off <= 32'd140;
    wire [6:0]  ev    = {en_err, en_redirect, en_uart_irq, en_ext_irq, en_dmiss, en_imiss, en_retire};
    always @(posedge clk) begin
        if (en_err) begin
            if (m_count != 32'hFFFF_FFFF) m_count <= m_count + 32'd1;
            if (!m_valid) begin m_valid <= 1'b1; {m_addr, m_iswr, m_master, m_resp} <= err_e; end
        end
        if (w_clr) begin m_count <= 32'd0; m_valid <= 1'b0; end
        for (k = 0; k < 4; k = k + 1) begin
            if ((m_sel[k] == 4'd0 || (m_sel[k] <= 4'd7 && m_ev[m_sel[k] - 4'd1]))
                && m_cnt[k] != 32'hFFFF_FFFF) m_cnt[k] <= m_cnt[k] + 32'd1;
            if (w_cc && w_off[3:2] == k[1:0]) m_cnt[k] <= 32'd0;
        end
        if (w_sel) m_sel[w_off[3:2]] <= w_32[3:0];
        m_ev <= ev;
        if (!rst_n) begin
            m_count <= 32'd0; m_valid <= 1'b0; m_iswr <= 1'b0; m_master <= 8'd0; m_resp <= 2'd0;
            m_addr <= 64'd0; m_ev <= 7'd0;
            for (k = 0; k < 4; k = k + 1) begin m_sel[k] <= 4'd0; m_cnt[k] <= 32'd0; end
        end
    end

    // expected responses, in order
    wire [31:0] p_wa = p_h[31:0] & 32'hFFFF_FFF8, v_lo, v_hi;
    soc_info_r32 rd_lo (.a(p_wa), .hz(hz), .count(m_count), .valid(m_valid), .iswr(m_iswr), .master(m_master),
        .resp(m_resp), .addr(m_addr), .sel(m_sel_v), .cnt(m_cnt_v), .v(v_lo));
    soc_info_r32 rd_hi (.a(p_wa | 32'd4), .hz(hz), .count(m_count), .valid(m_valid), .iswr(m_iswr),
        .master(m_master), .resp(m_resp), .addr(m_addr), .sel(m_sel_v), .cnt(m_cnt_v), .v(v_hi));
    wire [5:0]  e_b  = {aw_h[67:64], w_in ? 2'b00 : 2'b11};
    // {BUILD_DATE in the low lane (checked as a date, not a value), id, data, resp}
    wire [70:0] e_r  = {p_h[64] && p_wa == 32'h08, p_h[68:65],
                        p_h[64] ? {v_hi, v_lo} : 64'd0, p_h[64] ? 2'b00 : 2'b11};
    wire [5:0]  b_h; wire [3:0] b_n; wire [70:0] r_h; wire [3:0] r_n; wire [23:0] b_e; wire [283:0] r_e;
    fv_queue #(.W(6), .D(4)) qb (.clk(clk), .rst(rst), .push(tr_wr), .din(e_b),
        .pop(b_hs), .head(b_h), .n(b_n), .full(), .ents(b_e));
    fv_queue #(.W(71), .D(4)) qr (.clk(clk), .rst(rst), .push(tr_rd), .din(e_r),
        .pop(r_hs), .head(r_h), .n(r_n), .full(), .ents(r_e));

    function is_date (input [31:0] d); is_date = d >= 32'd20200101 && d <= 32'd20991231; endfunction
    wire r_ok = r_h[70] ? ({rid, rdata[63:32], rresp} == {r_h[69:66], r_h[65:34], r_h[1:0]} && is_date(rdata[31:0]))
                        : {rid, rdata, rresp} == r_h[69:0];

    always @(*) if (!rst && !r_q) begin
        if (tr_wr) assert (aw_n != 4'd0 && w_n != 4'd0);
        if (tr_rd_addr) assert (ar_n != 4'd0);
        if (tr_rd) assert (p_n != 4'd0);
        if (aw_n != 4'd0 && w_n != 4'd0 && b_n < 4'd2) assert (tr_wr);
        if (ar_n != 4'd0 && p_n < 4'd2) assert (tr_rd_addr);
        if (p_n != 4'd0 && r_n < 4'd2) assert (tr_rd);
        if (bvalid) assert (b_n != 4'd0 && {bid, bresp} == b_h);
        if (rvalid) assert (r_n != 4'd0 && r_ok);
    end

    // ---------------- reachability ----------------
    always @(*) if (!rst) begin
        cover (rvalid && rresp == 2'b00 && rdata[31:0] == 32'h464C_5331);   // MAGIC
        cover (rvalid && rresp == 2'b00 && rdata[63:32] == 32'hC000_D000);  // sdh's base, in the ROM
        cover (rvalid && rresp == 2'b00 && rdata[31:0] == 32'd2 && m_valid); // BUSERR_COUNT 2, captured
        cover (bvalid && bresp == 2'b11);                                   // a DECERR write
        cover (m_cnt[1] == 32'd2 && m_sel[1] == 4'd1);                      // two retires counted
    end
    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    wire [3:0] c_aw = awq_ne ? 4'd1 : 4'd0, c_ar = arq_ne ? 4'd1 : 4'd0;
    wire [3:0] c_w  = !wq_ne ? 4'd0 : wq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_b  = !bq_ne ? 4'd0 : bq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_r  = !rq_ne ? 4'd0 : rq_nf ? 4'd1 : 4'd2;
    wire [3:0] c_p  = !pq_ne ? 4'd0 : pq_nf ? 4'd1 : 4'd2;
    // the R FIFO entry against an expected one (BUILD_DATE: as a date)
    function r_eq (input [70:0] e, input [70:0] d);   // d: the FIFO word {id, data, resp, last}
        r_eq = d[0] && (e[70] ? ({d[70:67], d[66:35], d[2:1]} == {e[69:66], e[65:34], e[1:0]} && is_date(d[34:3]))
                             : d[70:1] == e[69:0]);
    endfunction
    // also in reset-method cycles: the transactor, the read queue and the queues above clear at the same edge
    always @(*) if (rst_n) begin
        assert ((wq_ne || wq_nf) && (rq_ne || rq_nf) && (bq_ne || bq_nf) && (pq_ne || pq_nf));
        assert (aw_n == c_aw && ar_n == c_ar && w_n == c_w && b_n == c_b && r_n == c_r && p_n == c_p);
        if (awq_ne) assert (aw_h == {awq_d[96:93], awq_d[92:29]});
        if (arq_ne) assert (ar_h == {arq_d[96:93], arq_d[92:29]});
        if (c_w >= 4'd1) assert (w_e[71:0]   == wq_d0[72:1]);
        if (c_w >= 4'd2) assert (w_e[143:72] == wq_d1[72:1]);
        if (c_b >= 4'd1) assert (b_e[5:0]    == bq_d0);
        if (c_b >= 4'd2) assert (b_e[11:6]   == bq_d1);
        if (c_r >= 4'd1) assert (r_eq(r_e[70:0], rq_d0));
        if (c_r >= 4'd2) assert (r_eq(r_e[141:71], rq_d1));
        if (c_p >= 4'd1) assert (p_e[68:0]   == pq_d0);
        if (c_p >= 4'd2) assert (p_e[137:69] == pq_d1);
        assert (n_aw == aw_n + b_n && n_w == w_n + b_n && n_ar == ar_n + p_n + r_n);
        if (!known) assert (aw_n == 4'd0 && w_n == 4'd0 && ar_n == 4'd0 && b_n == 4'd0 && r_n == 4'd0
                            && p_n == 4'd0 && n_aw == 4'd0 && n_w == 4'd0 && n_ar == 4'd0);
        if (known) assert (g_base == m_base && g_lim == m_lim
                           && m_base <= m_lim && m_lim - m_base <= 64'h1_0000_0000);
        assert (g_count == m_count && g_valid == m_valid && g_iswr == m_iswr && g_master == m_master
                && g_resp == m_resp && g_addr == m_addr && g_ev == m_ev);
        assert (g_sel == m_sel_v && g_cnt == m_cnt_v);
    end
`endif
endmodule

// soc_info_r32: the 32-bit register at offset a as software reads it, from the checker's model
module soc_info_r32 (
    input wire [31:0] a, hz, count, input wire valid, iswr, input wire [7:0] master,
    input wire [1:0] resp, input wire [63:0] addr, input wire [15:0] sel, input wire [127:0] cnt,
    output reg [31:0] v
);
    // the device ROM: {type, base, size, irq, flags} per record, in ROM order (record 0 in the
    // low bits).  A vector, not a case: yosys's proc_rom turned the case form into a wrong ROM.
    localparam [16*160-1:0] TAB = {
        {32'd1,  32'h8000_0000, 32'h0200_0000, 32'hFF, 32'd1},   // 15 sdram
        {32'd0,  32'h0000_1000, 32'h0000_1000, 32'hFF, 32'd1},   // 14 boot_rom
        {32'd3,  32'hC000_0000, 32'h0000_0080, 32'd0,  32'd1},   // 13 uart0
        {32'd4,  32'hC000_2000, 32'h0000_1000, 32'd1,  32'd1},   // 12 gpio
        {32'd2,  32'h0200_0000, 32'h0000_C000, 32'hFF, 32'd2},   // 11 clint
        {32'd5,  32'h0C00_0000, 32'h0040_0000, 32'hFF, 32'd4},   // 10 plic
        {32'd6,  32'hC000_3000, 32'h0000_1000, 32'hFF, 32'd1},   //  9 soc_info
        {32'd7,  32'hC000_4000, 32'h0000_1000, 32'd2,  32'd1},   //  8 spi0
        {32'd12, 32'hC000_A000, 32'h0000_1000, 32'd3,  32'd1},   //  7 spi2
        {32'd13, 32'hC000_7000, 32'h0000_0080, 32'd4,  32'd1},   //  6 uart1
        {32'd8,  32'hC001_0000, 32'h0000_1000, 32'hFF, 32'd1},   //  5 video
        {32'd8,  32'hC100_0000, 32'h0004_0000, 32'hFF, 32'd1},   //  4 video_fb
        {32'd9,  32'hC000_6000, 32'h0000_1000, 32'hFF, 32'd1},   //  3 i2c0
        {32'd10, 32'hC000_8000, 32'h0000_1000, 32'hFF, 32'd1},   //  2 gpio1
        {32'd11, 32'hC000_9000, 32'h0000_1000, 32'hFF, 32'd1},   //  1 audio
        {32'd14, 32'hC000_D000, 32'h0000_1000, 32'hFF, 32'd1}    //  0 sdh
    };
    wire [31:0]  ri  = (a - 32'h100) >> 2;          // u32 index into the ROM
    wire [31:0]  rec = ri >> 3;
    wire [159:0] rr  = rec < 32'd16 ? TAB[rec[3:0]*160 +: 160] : 160'd0;
    reg  [31:0]  rf;
    always @(*) begin
        rf = 32'd0;
        if (rec < 32'd16)
            case (ri[2:0])
                3'd0: rf = rr[159:128];  3'd1: rf = 32'd1;  3'd2: rf = rr[127:96];
                3'd3: rf = rr[95:64];    3'd4: rf = rr[63:32];  3'd5: rf = rr[31:0];
                default: rf = 32'd0;
            endcase
    end
    always @(*) begin
            v = 32'd0;
            case (a)
                32'h00: v = 32'h464C_5331;  32'h04: v = 32'd1;
                32'h08: v = 32'd0;          32'h0C: v = 32'h9F;      // 0x08: see e_r
                32'h10: v = hz;             32'h14: v = hz;
                32'h18: v = 32'h0200_0000;  32'h1C: v = 32'd16;
                32'h20: v = 32'h100;        32'h24: v = 32'd0;
                32'h28: v = {14'd0, resp, master, 6'd0, iswr, valid};
                32'h2C: v = count;
                32'h30: v = addr[31:0];   32'h34: v = addr[63:32];
                32'h40: v = {28'd0, sel[3:0]};  32'h44: v = {28'd0, sel[7:4]};
                32'h48: v = {28'd0, sel[11:8]};  32'h4C: v = {28'd0, sel[15:12]};
                32'h80: v = cnt[31:0];  32'h84: v = cnt[63:32];  32'h88: v = cnt[95:64];  32'h8C: v = cnt[127:96];
                default: if (a >= 32'h100) v = rf;
            endcase
    end
endmodule

bind mkSoC_Info soc_info_wb wb (
    .clk(CLK), .rst_n(RST_N), .en_reset(EN_reset), .en_init(EN_init),
    .init_base(init_addr_base), .init_lim(init_addr_lim), .hz(clk_hz),
    .awvalid(slave_awvalid), .awready(slave_awready), .awid(slave_awid), .awaddr(slave_awaddr),
    .wvalid(slave_wvalid), .wready(slave_wready), .wdata(slave_wdata), .wstrb(slave_wstrb),
    .bvalid(slave_bvalid), .bready(slave_bready), .bid(slave_bid), .bresp(slave_bresp),
    .arvalid(slave_arvalid), .arready(slave_arready), .arid(slave_arid), .araddr(slave_araddr),
    .rvalid(slave_rvalid), .rready(slave_rready), .rid(slave_rid), .rdata(slave_rdata),
    .rresp(slave_rresp), .rlast(slave_rlast), .awlen(slave_awlen), .arlen(slave_arlen),
    .en_err(EN_note_err), .err_e(note_err_e),
    .en_retire(EN_note_retire), .en_imiss(EN_note_imiss), .en_dmiss(EN_note_dmiss),
    .en_ext_irq(EN_note_ext_irq), .en_uart_irq(EN_note_uart_irq), .en_redirect(EN_note_redirect),
    .tr_wr(tr_wr), .tr_rd_addr(tr_rd_addr), .tr_rd(tr_rd),
    .awq_ne(\slave_xactor_f_wr_addr$EMPTY_N ), .awq_d(\slave_xactor_f_wr_addr$D_OUT ),
    .wq_ne(\slave_xactor_f_wr_data$EMPTY_N ), .wq_nf(\slave_xactor_f_wr_data$FULL_N ),
    .wq_d0(\slave_xactor_f_wr_data$D_OUT ), .wq_d1(),
    .arq_ne(\slave_xactor_f_rd_addr$EMPTY_N ), .arq_d(\slave_xactor_f_rd_addr$D_OUT ),
    .rq_ne(\slave_xactor_f_rd_data$EMPTY_N ), .rq_nf(\slave_xactor_f_rd_data$FULL_N ),
    .rq_d0(\slave_xactor_f_rd_data$D_OUT ), .rq_d1(),
    .bq_ne(\slave_xactor_f_wr_resp$EMPTY_N ), .bq_nf(\slave_xactor_f_wr_resp$FULL_N ),
    .bq_d0(\slave_xactor_f_wr_resp$D_OUT ), .bq_d1(),
    .pq_ne(\f_rd_pending$EMPTY_N ), .pq_nf(\f_rd_pending$FULL_N ), .pq_d0(\f_rd_pending$D_OUT ),
    .pq_d1(),                                             // the d1 ports: taps (soc_info.cfg)
    .g_base(rg_addr_base), .g_lim(rg_addr_lim),
    .g_count(rg_err_count), .g_valid(rg_err_valid), .g_iswr(rg_err_iswr), .g_master(rg_err_master),
    .g_resp(rg_err_resp), .g_addr(rg_err_addr), .g_sel(rg_perf_select), .g_cnt(rg_perf_count),
    .g_ev({rg_ev_buserr, rg_ev_redirect, rg_ev_uart_irq, rg_ev_ext_irq, rg_ev_dmiss, rg_ev_imiss, rg_ev_retire}));
`default_nettype wire
