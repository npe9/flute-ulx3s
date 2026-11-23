// vdp_wb: the checker for src/Vdp.v, bound into the DUT (no RTL changes).
//   bus:       the regbus VIP as a destination: every request answered exactly two cycles after
//              its take, never otherwise
//   registers: ID; CTRL [1:0], BG_SCROLL SX [8:0] / SY [23:16], BACKDROP [7:0] by byte lane;
//              STATUS [31:1] zero; other control offsets (outside the sprite table) read 0
//   memories:  a symbolic word of each of the BG map, the pattern RAM and the sprite table reads
//              back the bytes last written to it (byte lanes); VRAM offsets 0x1000-0x7FFF read 0
//   rendering: the render deadline -- a render runs from its start (hc 0 of scanline 2L - 2;
//              L = 0: scanline 523) for at most 629 pixel clocks (324 for the BG pass and sprite scan, 19 per
//              sprite, 1 to finish; 16 sprites), so every render is finished
//              (no line-buffer write left) before the next start, which is when line L is first
//              scanned out (scanline 2L); it writes only the line buffer not on screen, and
//              renders the line the scan counters say
// The pixel clock is the system clock here: the snapshot CDC (rq_t / snap_*) and the overflow
// toggle are reasoned about in src/Vdp.v's header and exercised by sim/vdp_ut, not proved.
// What is drawn (BG, sprites, flips, priority) is checked against sw/vdp/vdp_ref.c by
// sim/vdp_ut, not here.
`default_nettype none
module vdp_wb (
    input wire        clk, rst,
    input wire        rb_valid, rb_we, input wire [31:0] rb_addr, input wire [31:0] rb_wdata,
    input wire [3:0]  rb_wstrb, input wire rb_ack, input wire [31:0] rb_rdata,
    input wire [9:0]  scan_hc, scan_vc,
    input wire        r_start, r_done, input wire [7:0] r_line, input wire r_busy, r_lw, r_lw_buf,
    // internals
    input wire        busy, input wire [1:0] st, input wire [8:0] bx, input wire bv0, bv1, bv2,
    input wire [5:0]  ei, input wire ev, ev1, input wire [4:0] ln_n, dk, dph, input wire pv1,
    input wire [7:0] ln,
    input wire [1:0]  ctrl, input wire [8:0] sx, input wire [7:0] sy, backdrop,
    input wire        pend, pend_we, input wire [2:0] pend_win, input wire [4:0] pend_reg
);
    // ---------------- the bus ----------------
    wire bw, br; wire [31:0] bw_a, br_a, bw_d, br_d; wire [3:0] bw_s;
    regbus_vip #(.DUT_IS_DEST(1), .AW(32), .RD_LAT(2), .WR_LAT(2)) bus (.clk(clk), .rst(rst),
        .abandon(1'b0), .valid(rb_valid), .we(rb_we), .addr(rb_addr), .wdata(rb_wdata),
        .wstrb(rb_wstrb), .ack(rb_ack), .rdata(rb_rdata), .wr(bw), .wr_addr(bw_a),
        .wr_data(bw_d), .wr_strb(bw_s), .rd(br), .rd_addr(br_a), .rd_data(br_d),
        .tk(), .pend(b_pend), .we_q(b_we), .w(b_w), .a_q(b_a));
    wire b_pend, b_we; wire [3:0] b_w; wire [31:0] b_a;

    function is_reg  (input [31:0] a); is_reg  = !a[24] && a[11:5] == 7'd0;  endfunction
    function is_spr  (input [31:0] a); is_spr  = !a[24] && a[11:9] == 3'b010; endfunction
    function is_map  (input [31:0] a); is_map  = a[24] && !a[15] && a[14:12] == 3'd0; endfunction
    function is_pat  (input [31:0] a); is_pat  = a[24] && a[15];              endfunction
    function is_hole (input [31:0] a); is_hole = a[24] && !a[15] && a[14:12] != 3'd0; endfunction

    // ---------------- register model ----------------
    reg [1:0] m_ctrl = 0; reg [8:0] m_sx = 0; reg [7:0] m_sy = 0, m_bd = 0;
    always @(posedge clk) begin
        if (bw && is_reg (bw_a))
            case (bw_a[4:2])
                3'd1: if (bw_s[0]) m_ctrl <= bw_d[1:0];
                3'd2: begin
                          if (bw_s[0]) m_sx[7:0] <= bw_d[7:0];
                          if (bw_s[1]) m_sx[8]   <= bw_d[8];
                          if (bw_s[2]) m_sy      <= bw_d[23:16];
                      end
                3'd3: if (bw_s[0]) m_bd <= bw_d[7:0];
                default: ;
            endcase
        if (rst) begin m_ctrl <= 0; m_sx <= 0; m_sy <= 0; m_bd <= 0; end
    end
    always @(*) if (!rst && br && is_reg (br_a))
        case (br_a[4:2])
            3'd0: assert (br_d == 32'h31504456);
            3'd1: assert (br_d == {30'b0, m_ctrl});
            3'd2: assert (br_d == {8'b0, m_sy, 7'b0, m_sx});
            3'd3: assert (br_d == {24'b0, m_bd});
            3'd4: assert (br_d[31:1] == 31'b0);
            default: assert (br_d == 32'b0);
        endcase
    always @(*) if (!rst && br && !br_a[24] && !is_reg (br_a) && !is_spr (br_a)) assert (br_d == 32'b0);
    always @(*) if (!rst && br && is_hole (br_a)) assert (br_d == 32'b0);

    // ---------------- memory models: one symbolic word each ----------------
    // Bounded only (FV_MEM: the mem check, a BMC): an inductive proof needs the RAM word at the
    // symbolic address as an invariant, and a bind cannot name an array element.
    (* anyconst *) reg [9:0]  w_map;
    (* anyconst *) reg [12:0] w_pat;
    (* anyconst *) reg [6:0]  w_spr;          // {sprite, word}
    reg [31:0] v_map, v_pat, v_spr;
    reg [3:0]  k_map = 0, k_pat = 0, k_spr = 0;  // lanes written since reset
    function hit_map (input [31:0] a); hit_map = is_map (a) && a[11:2] == w_map; endfunction
    function hit_pat (input [31:0] a); hit_pat = is_pat (a) && a[14:2] == w_pat; endfunction
    function hit_spr (input [31:0] a); hit_spr = is_spr (a) && a[8:2] == w_spr;  endfunction
    integer e;
    always @(posedge clk) begin
        for (e = 0; e < 4; e = e + 1)
            if (bw && bw_s[e]) begin
                if (hit_map (bw_a)) begin v_map[8*e +: 8] <= bw_d[8*e +: 8]; k_map[e] <= 1'b1; end
                if (hit_pat (bw_a)) begin v_pat[8*e +: 8] <= bw_d[8*e +: 8]; k_pat[e] <= 1'b1; end
                if (hit_spr (bw_a)) begin v_spr[8*e +: 8] <= bw_d[8*e +: 8]; k_spr[e] <= 1'b1; end
            end
        if (rst) begin k_map <= 0; k_pat <= 0; k_spr <= 0; end
    end
`ifdef FV_MEM
    always @(*) if (!rst && br)
        for (e = 0; e < 4; e = e + 1) begin
            if (hit_map (br_a) && k_map[e]) assert (br_d[8*e +: 8] == v_map[8*e +: 8]);
            if (hit_pat (br_a) && k_pat[e]) assert (br_d[8*e +: 8] == v_pat[8*e +: 8]);
            if (hit_spr (br_a) && k_spr[e]) assert (br_d[8*e +: 8] == v_spr[8*e +: 8]);
        end
`endif

    // ---------------- the render deadline ----------------
    // dd: pixel clocks since the latest render start at or before this scan position (starts:
    // hc 0 of scanlines 523, 0, 2, 4, ... 476); 0 at a start itself
    wire [9:0] vc = scan_vc, hc = scan_hc;
    wire [19:0] dd = (vc >= 10'd523) ? (vc - 10'd523) * 20'd800 + hc
                     : (vc <= 10'd477) ? vc[0] * 20'd800 + hc
                     : (vc - 10'd476) * 20'd800 + hc;
    // the line those starts render, and the line buffer on screen (src/Vdp.v's front)
    wire [7:0] cur_line = (vc >= 10'd523) ? 8'd0 : (vc <= 10'd477) ? vc[8:1] + 8'd1 : 8'd239;
    wire       front    = (vc < 10'd480) ? vc[1] : 1'b1;
    localparam [19:0] T_BG = 20'd324;          // the sprite pass's first cycle
    always @(*) if (!rst) begin
        // the properties
        if (dd == 20'd0) assert (!r_busy && !r_lw);  // at a start the previous render is over
        if (r_busy) assert (dd >= 20'd1 && dd <= 20'd629 && r_line == cur_line && r_line[0] != front);
        if (r_lw) assert (dd >= 20'd2 && dd <= 20'd630 && r_line == cur_line && r_lw_buf == r_line[0]
                          && r_lw_buf != front);
        if (r_start) assert (dd == 20'd1 && r_busy && r_line == cur_line);
        if (r_done) assert (!r_busy);
    end
    // reachability: a render that drew a sprite; FV_C16 (cover16): the longest render, 16 sprites
    // with the last pixel opaque (~110 setup cycles, the snapshot lead, then 630)
`ifdef FV_C16
    always @(*) if (!rst) cover (r_done && dd == 20'd630);
`else
    always @(*) if (!rst) cover (r_done && dd >= 20'd344);
`endif

`ifndef FV_NO_INV
    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
    always @(*) if (!rst) begin
        // the bus side
        assert (ctrl == m_ctrl && sx == m_sx && sy == m_sy && backdrop == m_bd);
        assert (pend == (b_pend && b_w == 4'd1));
        if (b_pend) assert (b_w <= 4'd2 && (rb_ack == (b_w == 4'd2)));
        if (pend) assert (pend_we == b_we
                          && pend_win == (b_a[24] ? (is_pat (b_a) ? 3'd2 : (is_map (b_a) ? 3'd1 : 3'd4))
                                                  : (is_spr (b_a) ? 3'd3 : 3'd0))
                          && pend_reg == (b_a[11:9] == 3'b000 && b_a[8:5] == 4'd0 ? b_a[6:2] : 5'd31));
        if (!b_pend) assert (!rb_ack);
        // the pixel side
        assert (st != 2'd3);
        if (!busy) assert (st == 2'd0 && !bv0 && !bv1 && !bv2 && !ev && !ev1 && !pv1);
        if (st != 2'd0) assert (busy);
        if (st == 2'd1) begin
            assert (dd >= 20'd1 && dd <= 20'd323 && ln_n <= 5'd16);
            assert (bv0 == (dd <= 20'd320) && bv1 == (dd >= 20'd2 && dd <= 20'd321)
                    && bv2 == (dd >= 20'd3 && dd <= 20'd322));
            assert (ev == (dd <= 20'd64) && ev1 == (dd >= 20'd2 && dd <= 20'd65));
            if (bv0) assert (dd == bx + 20'd1);
            if (ev) assert (dd == ei + 20'd1);
            assert (!pv1);
        end
        if (st == 2'd2) assert (dk >= 5'd1 && dk <= ln_n && ln_n <= 5'd16 && dph <= 5'd18 &&
                                dd == T_BG + 20'd19 * (ln_n - dk) + dph && !bv0 && !bv1 && !bv2 && !ev && !ev1
                                && (!pv1 || dph >= 5'd4 || (dph == 5'd0 && dk != ln_n)));
        if (st == 2'd0 && busy) assert (ln_n >= 5'd1 && ln_n <= 5'd16 && !bv0 && !bv1 && !bv2 && !ev && !ev1
                                        && (dd == T_BG + 20'd19 * ln_n || dd == T_BG + 20'd19 * ln_n + 20'd1)
                                        && (!pv1 || dd == T_BG + 20'd19 * ln_n));
        if (r_lw && !busy) assert (dd <= T_BG + 20'd19 * ln_n + 20'd2 && (ln_n != 5'd0 || dd <= 20'd325));
    end
`endif
endmodule

bind vdp vdp_wb wb (
    .clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
    .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata), .scan_hc(scan_hc), .scan_vc(scan_vc),
    .r_start(r_start), .r_done(r_done), .r_line(r_line), .r_busy(r_busy), .r_lw(r_lw), .r_lw_buf(r_lw_buf),
    .busy(busy), .st(st), .bx(bx), .bv0(bv0), .bv1(bv1), .bv2(bv2), .ei(ei), .ev(ev), .ev1(ev1),
    .ln_n(ln_n), .dk(dk), .dph(dph), .pv1(pv1), .ln(ln),
    .ctrl(ctrl), .sx(sx), .sy(sy), .backdrop(backdrop), .pend(pend), .pend_we(pend_we),
    .pend_win(pend_win), .pend_reg(pend_reg));
`default_nettype wire
