// sdram_wb: the checker for src/Sdram_Controller.bsv (mkSdram_Controller_50), bound into the DUT
// (no RTL changes).  Properties on the ports and the trace port (tr_take: a request leaves the
// request FIFO; tr_chunk: a read chunk enters the response FIFO):
//   pins:      sdram_host_mon (JEDEC init, timing, refresh at tREFI, OE exactly for write beats);
//              the first command no earlier than the power-up pause after reset; init done within
//              INIT_MAX clocks of the pause, and only after the MRS; a REF at least every REF_MAX
//              clocks after init
//   requests:  accepted while fewer than 4 wait; taken in order, only after init, one at a time;
//              a read of bursts F..L or a write of the bursts of its 32-byte half with enabled
//              bytes runs a fixed schedule from the take (t = clocks since it): ACTIVE (row, bank
//              of the line) at 1, READ / WRITE of burst k at 2+8k (bank, column {line[5:2], burst},
//              auto-precharge on the last), nothing else until it ends (read: 5+8K, write: 2+8K;
//              an empty-mask write issues nothing); a write's beats carry its data and byte masks;
//              a read's DQM low from its READ; between requests only REF
//   responses: a read's 2K chunks enter at t = 8+4j, each the four DQ samples before it (the CAS
//              offset of the board's IOB and input registers), first sample in the low halfword;
//              they leave in order on get, which is ready exactly when one waits; never more than
//              8 wait (the response FIFO: SDRAM data cannot be stalled)
//   assumed:   Mem_Controller's request shapes (a write is one aligned 32-byte half, bursts F, F+1
//              with F even; a read F <= L); FV_SPEC_LATE (the spec bmc's and cover's scope only:
//              requests queued during init make deep bmc intractable): no request before init
// Raw_Mem_Req: {write, line[18:0], b_first, b_last, wdata[255:0], wbe[31:0]}.
// The INVARIANTS section names internals for induction only.
`default_nettype none
module sdram_wb #(parameter integer REF_MAX = 150, parameter integer INIT_MAX = 80) (
    input wire         clk, rst_n, input wire [15:0] pwr,
    input wire         put_en, put_rdy, input wire [311:0] put_d,
    input wire         get_en, get_rdy, input wire [63:0] get_d,
    input wire         init_done,
    input wire         cke, cs_n, ras_n, cas_n, we_n, input wire [1:0] ba, input wire [12:0] a,
    input wire [1:0]   dqm, input wire [15:0] dq_out, input wire oe, input wire [15:0] dq_in,
    input wire [312:0] tr_take, input wire [64:0] tr_chunk,
    // internals (induction only)
    input wire [4:0]   st, input wire [15:0] g_wait, g_pwr, g_ref, input wire [2:0] g_beat,
    input wire [1:0]   g_burst, g_last, g_pairs, input wire [3:0] g_bmask, g_iss, g_tak,
    input wire [311:0] g_req, input wire [15:0] g_hw0, g_hw1, g_hw2, g_dqin,
    input wire [2:0]   g_wrbank, input wire [3:0] g_cmd, input wire g_cmdv, g_inited,
    input wire         rq_ne, rq_nf, input wire [311:0] rq_d,
    input wire         sq_ne, sq_nf, input wire [63:0] sq_d,
    // the FIFOs' rings (taps: not in the bind; the cfg connects them after flatten)
    input wire [1:0]   rq_head, rq_tail, input wire rq_re, input wire [311:0] rq_a0, rq_a1, rq_a2,
    input wire [2:0]   sq_head, sq_tail, input wire sq_re,
    input wire [63:0]  sq_a0, sq_a1, sq_a2, sq_a3, sq_a4, sq_a5, sq_a6
);
    wire rst = !rst_n;
    reg  r_q = 1'b1;
    always @(posedge clk) r_q <= rst;

    // ---------------- the pins ----------------
    wire c_nop, c_act, c_rd, c_wr, c_pre, c_ref, c_mrs, seen_cmd, seen_pall, seen_mrs;
    wire [3:0] open_now, ap_now, act_age, ref_age, burst_end, n_ref, wr_beats;
    wire [5:0] po0, po1, po2, po3, ry0, ry1, ry2, ry3;
    wire [8:0] ref_gap; wire [1:0] wr_b, b_now; wire [2:0] wr_beat, beat_now;
    sdram_host_mon #(.HOST_IS_DUT(1), .T_RC(3), .T_RAS(3), .T_RP(1), .T_RRD(2), .T_WR(2), .BL(8),
                     .N_INIT_REF(8), .MODE(13'h0023), .TREFI(390)) mon (
        .clk(clk), .rst(rst), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .a(a), .dqm(dqm), .oe(oe),
        .c_nop(c_nop), .c_act(c_act), .c_rd(c_rd), .c_wr(c_wr), .c_pre(c_pre), .c_ref(c_ref), .c_mrs(c_mrs),
        .open_now(open_now), .ap_now(ap_now),
        .pre_ok0(po0), .pre_ok1(po1), .pre_ok2(po2), .pre_ok3(po3), .ready0(ry0), .ready1(ry1), .ready2(ry2), .ready3(ry3),
        .act_age(act_age), .ref_age(ref_age), .burst_end(burst_end),
        .seen_cmd(seen_cmd), .seen_pall(seen_pall), .seen_mrs(seen_mrs), .n_ref(n_ref), .ref_gap(ref_gap),
        .wr_beats(wr_beats), .wr_b(wr_b), .wr_beat(wr_beat), .b_now(b_now), .beat_now(beat_now));
    reg [14:0] cyc = 15'd0;                       // clocks since reset (saturating)
    always @(posedge clk) cyc <= rst ? 15'd0 : (cyc != 15'h7FFF ? cyc + 15'd1 : cyc);
    reg [15:0] p1 = 0, p2 = 0, p3 = 0, p4 = 0;    // DQ in, 1..4 clocks ago
    always @(posedge clk) begin p1 <= dq_in; p2 <= p1; p3 <= p2; p4 <= p3; end

    // ---------------- the request decode ----------------
    function automatic [3:0] f_mask (input [311:0] r);     // a write's bursts with enabled bytes
        f_mask = r[291] ? {|r[31:16], |r[15:0], 2'b00} : {2'b00, |r[31:16], |r[15:0]};
    endfunction
    function automatic [1:0] f_fs (input [3:0] m);
        f_fs = m[0] ? 2'd0 : m[1] ? 2'd1 : m[2] ? 2'd2 : 2'd3;
    endfunction
    function automatic [1:0] f_ls (input [3:0] m);
        f_ls = m[3] ? 2'd3 : m[2] ? 2'd2 : m[1] ? 2'd1 : 2'd0;
    endfunction
    function automatic [1:0] f_b0 (input [311:0] r);       // first burst issued
        f_b0 = r[311] ? f_fs (f_mask (r)) : r[291:290];
    endfunction
    function automatic [2:0] f_k (input [311:0] r);        // bursts issued
        f_k = r[311] ? (f_mask (r) == 4'd0 ? 3'd0 : {1'b0, f_ls (f_mask (r)) - f_fs (f_mask (r))} + 3'd1)
                     : {1'b0, r[289:288] - r[291:290]} + 3'd1;
    endfunction
    function automatic [6:0] f_end (input [311:0] r);      // t at which it ends
        f_end = r[311] ? 7'd2 + {1'b0, f_k (r), 3'b000} : 7'd5 + {1'b0, f_k (r), 3'b000};
    endfunction

`ifdef FV_SPEC_LATE     // spec bmc scope: no request offered before init (prove has no such limit)
    always @(*) if (put_en) assume (init_done);
`endif
    always @(*) if (put_en) begin                           // Mem_Controller's shapes
        if (put_d[311]) assume (put_d[290] == 1'b0 && put_d[289:288] == put_d[291:290] + 2'd1);
        else            assume (put_d[291:290] <= put_d[289:288]);
    end

    // the requests waiting, and the one in progress
    wire take = tr_take[312]; wire [311:0] tk = tr_take[311:0];
    wire [311:0] qh; wire [3:0] qn; wire [312*5-1:0] qe;
    fv_queue #(.W(312), .D(5)) qq (.clk(clk), .rst(rst), .push(put_en), .din(put_d), .pop(take),
        .head(qh), .n(qn), .full(), .ents(qe));
    reg act = 1'b0; reg [6:0] t = 7'd0; reg [311:0] c = 312'd0;
    always @(posedge clk) begin
        if (take) begin act <= f_k (tk) != 3'd0; t <= 7'd1; c <= tk; end
        else if (act) begin t <= t + 7'd1; if (t + 7'd1 == f_end (c)) act <= 1'b0; end
        if (rst) act <= 1'b0;
    end
    wire        c_w = c[311]; wire [18:0] c_line = c[310:292];
    wire [2:0]  c_k = f_k (c);  wire [1:0] c_b0 = f_b0 (c);
    wire [6:0]  tm2 = t - 7'd2;
    wire [3:0]  kk  = tm2[6:3];   wire [2:0] jj = tm2[2:0];
    wire [1:0]  bk  = c_b0 + kk[1:0];
    wire        e_act = act && t == 7'd1;
    wire        e_rw  = act && t >= 7'd2 && jj == 3'd0 && kk < {1'b0, c_k};
    wire        e_beat = act && c_w && t >= 7'd2 && kk < {1'b0, c_k};          // a write beat on DQ
    wire [3:0]  idx = {bk[0], jj};
    wire [6:0]  tm8 = t - 7'd8;
    wire        e_chunk = act && !c_w && t >= 7'd8 && tm8[1:0] == 2'd0 && tm8[6:2] < {1'b0, c_k, 1'b0};

    // the responses waiting
    wire [63:0] rh; wire [3:0] rn; wire [64*9-1:0] re;
    fv_queue #(.W(64), .D(9)) qr (.clk(clk), .rst(rst), .push(tr_chunk[64]), .din(tr_chunk[63:0]),
        .pop(get_en), .head(rh), .n(rn), .full(), .ents(re));

    always @(*) if (!rst && !r_q) begin
        // power-up and init
        if (!c_nop) assert ({1'b0, cyc} > {1'b0, pwr});   // cyc: clocks after the first out of reset
        if ({1'b0, cyc} >= {1'b0, pwr} + INIT_MAX) assert (init_done);
        if (init_done) assert (seen_mrs);
        if (seen_mrs) assert (ref_gap <= REF_MAX);
        // requests
        assert (put_rdy == (qn < 4'd4));
        if (take) assert (qn != 4'd0 && tk == qh && init_done && !act);
        if (act) begin
            assert (c_act == e_act && (c_rd || c_wr) == e_rw && (c_nop || e_act || e_rw));
            if (e_act) assert (a == c_line[18:6] && ba == c_line[1:0]);
            if (e_rw)  assert (c_wr == c_w && ba == c_line[1:0] && a[12:11] == 2'd0 && a[9] == 1'b0
                               && a[8:5] == c_line[5:2] && a[4:3] == bk && a[2:0] == 3'd0
                               && a[10] == (kk == {1'b0, c_k} - 4'd1));
            if (e_beat) assert (dq_out == c[32 + 16*idx +: 16] && dqm == ~{c[2*idx + 1], c[2*idx]});
            if (!c_w && t >= 7'd2) assert (dqm == 2'b00);
        end
        else if (seen_mrs) assert (c_nop || c_ref);
        // responses
        assert (tr_chunk[64] == e_chunk);
        if (tr_chunk[64]) assert (tr_chunk[63:0] == {p1, p2, p3, p4});
        assert (get_rdy == (rn != 4'd0));
        if (get_en) assert (get_d == rh);
        assert (rn <= 4'd8);
    end

    // ---------------- reachability ----------------
    always @(*) if (!rst && seen_mrs) begin
        cover (c_ref);
        cover (tr_chunk[64] && !c_w && c[291:290] == 2'd0 && c[289:288] == 2'd3 && t == 7'd36);   // a full line
        cover (c_wr && a[10] && kk == 4'd1);                                                       // a 2-burst write
        cover (take && tk[311] && f_mask (tk) == 4'd0);                                            // an empty write
        cover (get_en && rn == 4'd6);
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    // Each controller state against the checker's clock count (init) or request model (t, c), the
    // monitor's bank model against them, and both FIFOs against the model queues.
    function automatic f_shape (input [311:0] r);
        f_shape = r[311] ? (r[290] == 1'b0 && r[289:288] == r[291:290] + 2'd1) : (r[291:290] <= r[289:288]);
    endfunction
    wire [16:0] cy = {2'b00, cyc}, pw = {1'b0, pwr}, w17 = {1'b0, g_wait};
    wire [16:0] p12 = ({15'd0, g_pairs} << 3) + ({15'd0, g_pairs} << 2);        // 12 per REF pair
    wire [16:0] sum = {8'd0, ref_gap} + {1'b0, g_ref};                         // ref_gap + refresh count
    wire [1:0]  B   = c_line[1:0];
    wire [6:0]  tl  = 7'd2 + {1'b0, c_k - 3'd1, 3'b000};                       // the last READ / WRITE
    wire [6:0]  ta  = t - tl - 7'd1;                                           // clocks after it, - 1
    wire [6:0]  tm5 = t - 7'd5, tw = t - 7'd1, tm9 = t - 7'd9;
    wire [2:0]  kw  = tw[5:3]; wire [2:0] jw = tw[2:0]; wire [1:0] m = tm5[1:0];
    wire [3:0]  c_m = f_mask (c);
    wire [5:0]  pb  = c_w ? 6'd8 : 6'd7, rb = c_w ? 6'd9 : 6'd8;              // after the last RW
    wire [3:0]  emit = t < 7'd9 ? 4'd0 : {1'b0, tm9[4:2]} + 4'd1;             // its chunks in qr
    wire [3:0]  rem  = (act && !c_w) ? {c_k, 1'b0} - emit : 4'd0;             // and still to come
    wire [23:0] po_v = {po3, po2, po1, po0}, ry_v = {ry3, ry2, ry1, ry0};
    wire [5:0]  poB = po_v[6*B +: 6], ryB = ry_v[6*B +: 6];
    wire        wb_v = g_wrbank[2]; wire [1:0] wb_b = g_wrbank[1:0];
    wire [5:0]  ry_ref = g_wait == 16'd3 ? 6'd2 : g_wait == 16'd2 ? 6'd1 : 6'd0; // after a REF
    integer i;

    // reset's end: everything at its initial value (an induction window may start in reset, and
    // the monitor's bank model has no reset)
    always @(*) if (!rst && r_q) begin
        assert (po_v == 0 && ry_v == 0 && open_now == 0 && ap_now == 0 && act_age == 4'd15
                && ref_age == 4'd15 && burst_end == 0 && wr_beats == 0);
        assert (!seen_cmd && !seen_pall && !seen_mrs && n_ref == 0 && ref_gap == 0);
        assert (cyc == 0 && !act && qn == 0 && rn == 0);
    end

    always @(*) begin i = 0; if (!rst && !r_q) begin
        assert (st <= 5'd18 && st != 5'd10 && st != 5'd11);
        assert (g_inited == (st >= 5'd9) && init_done == g_inited);
        assert (g_ref >= 16'd1 && g_ref <= 16'd98);
        assert (c_nop == !g_cmdv && g_dqin == p1);
        assert ((ap_now & ~open_now) == 0 && burst_end <= 4'd7);
        for (i = 0; i < 4; i = i + 1) assert (po_v[6*i +: 6] <= 6'd8 && ry_v[6*i +: 6] <= 6'd9);
        for (i = 0; i < 5; i = i + 1) if (i < qn) assert (f_shape (qe[312*i +: 312]));
        assert (g_iss - g_tak == rn + rem && {1'b0, rn} + {1'b0, rem} <= 5'd8);
        if (wb_v) assert (st == 5'd9 && !act);

        // init: the clock count of each state (first command at P+1, IDLE at P+60)
        case (st)
        5'd0: assert (cy < pw && {1'b0, g_pwr} == pw - cy);
        5'd1: assert (cy == pw);
        5'd2: assert (g_wait <= 16'd4 && cy == pw + 17'd5 - w17);
        5'd3: assert (cy == pw + 17'd6 + p12);
        5'd4: assert (g_wait <= 16'd4 && cy == pw + 17'd11 + p12 - w17);
        5'd5: assert (cy == pw + 17'd12 + p12);
        5'd6: assert (g_wait <= 16'd4 && cy == pw + 17'd17 + p12 - w17);
        5'd7: assert (cy == pw + 17'd54);
        5'd8: assert (g_wait <= 16'd4 && cy == pw + 17'd59 - w17);
        default: assert (cy >= pw + 17'd60);
        endcase
        if (st <= 5'd8) begin
            assert (!act && open_now == 0 && dqm == 2'b11 && !oe && wr_beats == 0 && burst_end == 0 && act_age == 4'd15);
            assert (g_ref == (cy >= 17'd97 ? 16'd1 : 16'd98 - {1'b0, cyc}));
            if (st <= 5'd2) assert (g_pairs == 2'd0 && n_ref == 4'd0);
            if (st >= 5'd7) assert (g_pairs == 2'd3 && n_ref == 4'd8);
            if (ref_age != 4'd15) assert (ref_gap == {5'd0, ref_age});   // both from the last REF
            if (st == 5'd3) assert (n_ref == {1'b0, g_pairs, 1'b0});
            if (st == 5'd4) assert (n_ref + (g_wait == 16'd4 ? 4'd1 : 4'd0) == {1'b0, g_pairs, 1'b0} + 4'd1);
            if (st == 5'd5) assert (n_ref == {1'b0, g_pairs, 1'b0} + 4'd1);
            if (st == 5'd6) assert (n_ref + (g_wait == 16'd4 ? 4'd1 : 4'd0) == {1'b0, g_pairs, 1'b0} + 4'd2);
            if (st == 5'd2 || st == 5'd4 || st == 5'd6 || st == 5'd8) assert (g_cmdv == (g_wait == 16'd4));
            else assert (!g_cmdv);
            if (st <= 5'd3 || st == 5'd5 || st == 5'd7 || st == 5'd8) assert (ry_v == 0);
        end
        assert (seen_pall == (st >= 5'd3 || (st == 5'd2 && g_wait != 16'd4)) && seen_cmd == seen_pall);
        assert (seen_mrs == (st >= 5'd9 || (st == 5'd8 && g_wait != 16'd4)));
        if (st == 5'd4 || st == 5'd6 || st == 5'd18)
            assert (ry_v == {4{ry_ref}} && (g_wait > 16'd3 || {12'd0, ref_age} == 16'd3 - g_wait));
        if (st <= 5'd2 || (st == 5'd3 && g_pairs == 2'd0)) assert (ref_age == 4'd15);
        else if (st == 5'd3 || st == 5'd5 || st == 5'd7) assert (ref_age == 4'd4);
        else if (st == 5'd8) assert ({12'd0, ref_age} == 16'd9 - g_wait);
        else if (!((st == 5'd4 || st == 5'd6 || st == 5'd18) && g_wait <= 16'd3)) assert (ref_age >= 4'd4);

        // between requests: refresh, or idle with every bank closed (but a write's, for one clock)
        if (st >= 5'd9 && !act) begin
            assert (st == 5'd9 || st == 5'd17 || st == 5'd18);
            assert (wr_beats == 0 && !oe && burst_end == 0 && act_age >= 4'd8);
        end
        if (st == 5'd9 && !act) begin
            assert (sum <= 17'd135 && (g_ref == 16'd1 || sum <= 17'd97));
            if (wb_v) begin
                for (i = 0; i < 4; i = i + 1)
                    if (i == wb_b) assert (open_now[i] && ap_now[i] && po_v[6*i +: 6] == 6'd1 && ry_v[6*i +: 6] == 6'd2);
                    else           assert (!open_now[i] && ry_v[6*i +: 6] == 6'd0);
            end else begin
                assert (open_now == 0);
                for (i = 0; i < 4; i = i + 1) assert (ry_v[6*i +: 6] <= 6'd1);
            end
        end
        if (st == 5'd17) begin
            assert (g_ref == 16'd1 && ref_gap <= 9'd136 && open_now == 0);
            for (i = 0; i < 4; i = i + 1) assert (ry_v[6*i +: 6] <= 6'd1);
        end
        if (st == 5'd18) assert (open_now == 0 && g_wait <= 16'd4
                                 && (g_wait == 16'd4 ? ref_gap <= 9'd137 && g_ref == 16'd98
                                                     : {7'd0, ref_gap} == 16'd3 - g_wait && g_ref == 16'd94 + g_wait));

        // a request in progress: the controller's state at each t, and its bank's
        if (act) begin
            assert (!wb_v && g_req == c && t >= 7'd1 && t < f_end (c) && c_k != 3'd0 && f_shape (c));
            assert (sum <= 17'd97 + {10'd0, t} && (g_ref == 16'd1 || sum <= 17'd97));
            assert ((open_now & ~(4'd1 << B)) == 0);
            for (i = 0; i < 4; i = i + 1)
                if (i != B) assert (ry_v[6*i +: 6] <= (t == 7'd1 ? 6'd1 : 6'd0));
            if (t == 7'd1)     assert (!open_now[B] && ryB == 6'd0 && act_age >= 4'd9);
            else               assert (act_age == (t >= 7'd17 ? 4'd15 : tm2[3:0]));
            if (t >= 7'd2 && t <= tl) assert (open_now[B] && !ap_now[B]);
            if (t > tl) assert (open_now[B] == ({1'b0, ta} < {1'b0, pb}) && ap_now[B] == open_now[B]
                                && poB == ({1'b0, ta} < {1'b0, pb} ? pb - ta[5:0] : 6'd0)
                                && ryB == ({1'b0, ta} < {1'b0, rb} ? rb - ta[5:0] : 6'd0));
            assert (burst_end == ((t >= 7'd3 && t <= tl + 7'd7 && jj != 3'd0) ? 4'd8 - {1'b0, jj} : 4'd0));
            if (c_w) begin
                assert (oe == (t >= 7'd2) && wr_beats == ((t >= 7'd2 && jj != 3'd0) ? 4'd8 - {1'b0, jj} : 4'd0));
                if (t >= 7'd3 && jj != 3'd0) assert (wr_beat == jj && wr_b == bk);
                assert (g_bmask == c_m && g_last == f_ls (c_m));
                if (kw == c_k) assert (st == 5'd16);
                else begin
                    assert (g_burst == c_b0 + kw[1:0]);
                    if (jw == 3'd0) assert (st == 5'd14);
                    else            assert (st == 5'd15 && g_beat == jw);
                end
            end else begin
                assert (!oe && wr_beats == 0 && g_last == c[289:288]);
                if (t == 7'd1) assert (st == 5'd12 && g_burst == c[291:290]);
                else if (t <= 7'd4) assert (st == 5'd13 && g_wait == 16'd5 - {9'd0, t} && g_beat == 3'd0
                                            && g_burst == c[291:290]);
                else begin
                    assert (st == 5'd13 && g_wait == 16'd0 && g_beat == tm5[2:0] && g_burst == c[291:290] + tm5[4:3]);
                    if (m >= 2'd1) assert (g_hw0 == (m == 2'd1 ? p2 : m == 2'd2 ? p3 : p4));
                    if (m >= 2'd2) assert (g_hw1 == (m == 2'd2 ? p2 : p3));
                    if (m == 2'd3) assert (g_hw2 == p2);
                end
            end
        end
    end end

    sizedfifo_inv #(.W(312), .DEPTH(4), .CW(2), .D(5)) rq_inv (.en(!rst && !r_q),
        .hasodata(rq_ne), .ring_empty(rq_re), .not_ring_full(rq_nf), .head(rq_head), .tail(rq_tail),
        .arr({rq_a2, rq_a1, rq_a0}), .dout(rq_d), .n(qn), .ents(qe));
    sizedfifo_inv #(.W(64), .DEPTH(8), .CW(3), .D(9)) sq_inv (.en(!rst && !r_q),
        .hasodata(sq_ne), .ring_empty(sq_re), .not_ring_full(sq_nf), .head(sq_head), .tail(sq_tail),
        .arr({sq_a6, sq_a5, sq_a4, sq_a3, sq_a2, sq_a1, sq_a0}), .dout(sq_d), .n(rn), .ents(re));
`endif
endmodule

bind mkSdram_Controller_50 sdram_wb wb (
    .clk(CLK), .rst_n(RST_N), .pwr(t_powerup),
    .put_en(EN_mem_server_request_put), .put_rdy(RDY_mem_server_request_put), .put_d(mem_server_request_put),
    .get_en(EN_mem_server_response_get), .get_rdy(RDY_mem_server_response_get), .get_d(mem_server_response_get),
    .init_done(init_done), .cke(sdram_cke), .cs_n(sdram_cs_n), .ras_n(sdram_ras_n), .cas_n(sdram_cas_n),
    .we_n(sdram_we_n), .ba(sdram_ba), .a(sdram_a), .dqm(sdram_dqm), .dq_out(sdram_dq_out), .oe(sdram_dq_oe),
    .dq_in(sdram_dq_in_v), .tr_take(tr_take), .tr_chunk(tr_chunk),
    .st(m_rg_state), .g_wait(m_rg_wait), .g_pwr(m_rg_pwrcnt), .g_ref(m_rg_ref_cnt), .g_beat(m_rg_beat),
    .g_burst(m_rg_burst), .g_last(m_rg_burst_last), .g_pairs(m_rg_init_pairs), .g_bmask(m_rg_bmask),
    .g_iss(m_rg_chunks_issued), .g_tak(m_rg_chunks_taken), .g_req(m_rg_req),
    .g_hw0(m_rg_hw_0), .g_hw1(m_rg_hw_1), .g_hw2(m_rg_hw_2), .g_dqin(m_rg_dq_in),
    .g_wrbank(m_rg_wr_bank), .g_cmd(m_rg_cmd), .g_cmdv(m_rg_cmd_valid), .g_inited(m_rg_inited),
    .rq_ne(\m_f_reqs$EMPTY_N ), .rq_nf(\m_f_reqs$FULL_N ), .rq_d(\m_f_reqs$D_OUT ),
    .sq_ne(\m_f_rsps$EMPTY_N ), .sq_nf(\m_f_rsps$FULL_N ), .sq_d(\m_f_rsps$D_OUT ));
`default_nettype wire
