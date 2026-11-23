// apu_wb: the checker for src/Apu.v, bound into the DUT (no RTL changes).
//   bus:       the regbus VIP as a destination: every request answered exactly two cycles after
//              its take, never otherwise
//   registers: ID; CTRL [0] and MASTER [7:0] (reset 64) as last written (byte lane 0); TICKS =
//              the samples output so far; STATUS [10:0] = the writes queued; the other control
//              offsets, the unmapped pages and the wave RAM read 0
//   tick:      a tick every TICK clocks exactly
//   deadline:  the sequencer is idle at every tick: the drain of the writes queued before it plus
//              the eight voices and the mix always finish within the tick (at most one write per
//              3 bus clocks: 2 clocks each to apply, 12 per voice, 1 to mix)
//   queue:     never full (no write is ever lost: the queue holds 1024, a tick's writes < 522);
//              every write taken before a tick is applied before that tick's sample, and none
//              taken after it
//   output:    out_l / out_r change only with tr_done
//   FV_MEM (bounded): a symbolic voice register word reads back as written (byte lanes, masks);
//              a symbolic write is applied unchanged, in order
// What the voices compute is checked against sw/apu/apu_ref.c by sim/apu_ut, not here.
`default_nettype none
module apu_wb #(parameter integer TICK = 1563) (
    input wire        clk, rst,
    input wire        rb_valid, rb_we, input wire [31:0] rb_addr, input wire [31:0] rb_wdata,
    input wire [3:0]  rb_wstrb, input wire rb_ack, input wire [31:0] rb_rdata,
    input wire [15:0] out_l, out_r,
    input wire        tr_tick, tr_busy, tr_done, input wire [10:0] tr_level,
    input wire        tr_apply, input wire [15:0] tr_apply_a, input wire [3:0] tr_apply_s,
    input wire [31:0] tr_apply_d,
    // internals
    input wire [1:0]  st, input wire [10:0] tc, dn, level, input wire dph, input wire [2:0] v,
    input wire [3:0]  k, input wire [9:0] wp, rp, input wire pend, pend_we,
    input wire [15:0] pend_a, input wire ctrl_sh, input wire [7:0] master_sh,
    input wire [31:0] ticks
);
    // ---------------- the bus ----------------
    wire bw, br, b_tk; wire [31:0] bw_a, br_a, bw_d, br_d; wire [3:0] bw_s;
    wire b_pend, b_we; wire [3:0] b_w; wire [31:0] b_a;
    regbus_vip #(.DUT_IS_DEST(1), .AW(32), .RD_LAT(2), .WR_LAT(2)) bus (.clk(clk), .rst(rst),
        .abandon(1'b0), .valid(rb_valid), .we(rb_we), .addr(rb_addr), .wdata(rb_wdata),
        .wstrb(rb_wstrb), .ack(rb_ack), .rdata(rb_rdata), .wr(bw), .wr_addr(bw_a),
        .wr_data(bw_d), .wr_strb(bw_s), .rd(br), .rd_addr(br_a), .rd_data(br_d),
        .tk(b_tk), .pend(b_pend), .we_q(b_we), .w(b_w), .a_q(b_a));

    // ---------------- register model ----------------
    reg m_ctrl = 0; reg [7:0] m_master = 8'd64;
    reg [15:0] n_done = 0;                    // samples output before this cycle
    reg [10:0] lvl_q = 0;
    always @(posedge clk) begin
        if (bw && !bw_a[15] && bw_a[11:2] == 10'h001 && bw_s[0]) m_ctrl   <= bw_d[0];
        if (bw && !bw_a[15] && bw_a[11:2] == 10'h002 && bw_s[0]) m_master <= bw_d[7:0];
        if (tr_done) n_done <= n_done + 16'd1;
        lvl_q <= tr_level;
        if (rst) begin m_ctrl <= 0; m_master <= 8'd64; n_done <= 0; end
    end
    always @(*) if (!rst && br) begin
        if (br_a[15] || (br_a[11:8] != 4'h0 && br_a[11:8] != 4'h1)) assert (br_d == 32'd0);
        if (!br_a[15] && br_a[11:8] == 4'h0)
            case (br_a[7:2])
                6'd0: assert (br_d == 32'h31555041);
                6'd1: assert (br_d == {31'd0, m_ctrl});
                6'd2: assert (br_d == {24'd0, m_master});
                6'd3: assert (br_d[15:0] == n_done);
                6'd4: begin assert (br_d[10:0] == lvl_q); assert (br_d[15:11] == 0 && br_d[31:24] == 0); end
                default: assert (br_d == 32'd0);
            endcase
    end

    // ---------------- the tick, the deadline, the queue ----------------
    reg [10:0] cnt = 0;                       // clocks since the last tick (or reset)
    reg [10:0] nw = 0;                        // writes taken since the last tick
    reg [10:0] d0 = 0;                        // writes taken before the last tick, after the one before
    reg        seen = 0;
    reg [15:0] tkc = 0, apc = 0, tk_at = 0;   // writes taken, applied; taken before the last tick
    wire       wt = b_tk && rb_we;
    always @(posedge clk) begin
        cnt <= tr_tick ? 11'd0 : cnt + 11'd1;
        if (tr_tick) begin nw <= wt ? 11'd1 : 11'd0; d0 <= nw; seen <= 1'b1; tk_at <= tkc; end
        else if (wt) nw <= nw + 11'd1;
        if (wt) tkc <= tkc + 16'd1;
        if (tr_apply) apc <= apc + 16'd1;
        if (rst) begin cnt <= 0; nw <= 0; d0 <= 0; seen <= 0; tkc <= 0; apc <= 0; tk_at <= 0; end
    end
    always @(*) if (!rst) begin
        assert (tr_tick == (cnt == TICK - 1));
        assert (tr_level < 11'd1024);
`ifndef FV_MEM                                 // (the 8-clock tick misses ticks while busy)
        if (tr_done) assert (apc == tk_at);
        if (tr_tick) assert (!tr_busy);
        if (tr_apply) assert (apc != tk_at);
`endif
    end
    // the output only changes with tr_done
    reg [15:0] ol_q = 0, or_q = 0;
    always @(posedge clk) begin ol_q <= out_l; or_q <= out_r; end
    reg past = 0; always @(posedge clk) past <= !rst;
    always @(*) if (!rst && past && !tr_done) assert (out_l == ol_q && out_r == or_q);

    always @(*) if (!rst) cover (tr_done && seen && d0 >= 11'd2);   // a sample after two writes

`ifdef FV_MEM
    // ---------------- a symbolic voice register word, and a symbolic queued write ----------------
    (* anyconst *) reg [5:0] w_i;             // {voice, register}
    reg [31:0] m_w = 0; reg m_ok = 0;         // m_ok: all four lanes written since reset
    reg [3:0]  m_seen = 0;
    always @(posedge clk) begin
        if (bw && !bw_a[15] && bw_a[11:8] == 4'h1 && bw_a[7:2] == w_i) begin
            if (bw_s[0]) m_w[7:0]   <= bw_d[7:0];
            if (bw_s[1]) m_w[15:8]  <= bw_d[15:8];
            if (bw_s[2]) m_w[23:16] <= bw_d[23:16];
            if (bw_s[3]) m_w[31:24] <= bw_d[31:24];
            m_seen <= m_seen | bw_s;
        end
        if (rst) m_seen <= 0;
    end
    wire [31:0] mask = (w_i[2:0] == 3'd0) ? 32'h337 : (w_i[2:0] == 3'd3) ? 32'hFFFFFFFF :
                       (w_i[2:0] == 3'd4 || w_i[2:0] == 3'd5) ? 32'h7FFF : 32'hFFFF;
    always @(*) if (!rst && br && !br_a[15] && br_a[11:8] == 4'h1 && br_a[7:2] == w_i && w_i[2:0] != 3'd7
                    && m_seen == 4'hF)
        assert (br_d == (m_w & mask));
    // j: the first or second write (within the bound: writes are at least 4 clocks apart, and the
    // 8-clock tick's drain then waits out the voice loop, so later ones are applied past it)
    (* anyconst *) reg j;
    reg [13:0] j_a; reg [3:0] j_s; reg [31:0] j_d;
    always @(posedge clk) if (wt && tkc == {15'd0, j}) begin j_a <= rb_addr[15:2]; j_s <= rb_wstrb; j_d <= rb_wdata; end
    always @(*) if (!rst && tr_apply && apc == {15'd0, j})
        assert (tr_apply_a[15:2] == j_a && tr_apply_s == j_s && tr_apply_d == j_d);
    always @(*) if (!rst) cover (tr_apply && apc == 16'd1);   // the second write applied
`endif

`ifndef FV_NO_INV
    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
    wire [15:0] c16 = {5'd0, cnt}, n16 = {5'd0, nw}, d16 = {5'd0, d0}, dn16 = {5'd0, dn};
    always @(*) if (!rst) begin
        assert (c16 + {5'd0, tc} == TICK - 1);
        assert (level == nw + ((st == 2'd1) ? dn : 11'd0));
        assert (wp - rp == level[9:0]);
        assert (tkc - apc == {5'd0, level});
        assert (tk_at - apc == ((st == 2'd1) ? dn16 : 16'd0));
        assert (!(pend && rb_ack));
        assert (pend == (b_pend && b_w == 4'd1));
        if (pend) assert (pend_we == b_we && pend_a == b_a[15:0]);
        if (pend)        assert (3 * n16 <= c16 + 3);
        else if (rb_ack) assert (3 * n16 <= c16 + 2);
        else             assert (3 * n16 <= c16 + 1);
        assert (3 * d16 <= TICK + 2);
        if (st != 2'd1) assert (!dph);
        if (!seen) assert (st == 2'd0 && d0 == 0 && tk_at == 0 && apc == 0);
        case (st)
            2'd1: begin assert (dn >= 11'd1 && dn <= d0 && v == 0 && k == 0);
                        assert (c16 == 2 * (d16 - dn16) + {15'd0, dph}); end
            2'd2: begin assert (k <= 4'd11); assert (c16 == 2 * d16 + 12 * {13'd0, v} + {12'd0, k}); end
            2'd3: assert (c16 == 2 * d16 + 96);
            default: if (seen) assert (c16 >= 2 * d16 + 97);
        endcase
        assert (ctrl_sh == m_ctrl && master_sh == m_master);
        assert (ticks[15:0] == n_done + {15'd0, tr_done});
        if (tr_done) assert (st == 2'd0);
    end
`endif
endmodule
bind apu apu_wb #(.TICK(TICK)) wb (
    .clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
    .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata), .out_l(out_l), .out_r(out_r),
    .tr_tick(tr_tick), .tr_busy(tr_busy), .tr_done(tr_done), .tr_level(tr_level),
    .tr_apply(tr_apply), .tr_apply_a(tr_apply_a), .tr_apply_s(tr_apply_s), .tr_apply_d(tr_apply_d),
    .st(st), .tc(tc), .dn(dn), .level(level), .dph(dph), .v(v), .k(k), .wp(wp), .rp(rp),
    .pend(pend), .pend_we(pend_we), .pend_a(pend_a), .ctrl_sh(ctrl_sh), .master_sh(master_sh),
    .ticks(ticks));
`default_nettype wire
