// uart_dmi_wb: the checker for src/Uart_DMI_Bridge.bsv (mkUart_DMI_Bridge_P; instances in
// Uart_DMI_Bridge_Fv.bsv), bound into the DUT (no RTL changes).  Properties on the ports and trace:
//   console:  the bytes put (from the UART receiver) reach the console in order, except the magic
//             DB 53 44 4D 01 02 03 04 and what follows it while armed.  A partial match that fails
//             (a mismatching byte, or no byte for TM clocks) gives its prefix back in place, then
//             the mismatching byte unless it is 0xDB (which starts a new match).  Each byte, or
//             prefix (+ byte), is one token owed to the console; a token is dropped (tr_drop) only
//             when 16 are owed.  A byte is fed (tr_feed) into the console FIFO (32) on every clock
//             one is owed, the FIFO has room and no byte is put; get returns them in order.
//   armed:    6-byte requests [op, addr, data (big-endian)].  'r' / 'w': a DMI read / write, as a
//             Control_Req {10 / 11, addr, data for 'w' else 0} on client.request; armed again
//             when the response is taken (tr_dmi_done, response (0, result[31:0])).  'q': disarm,
//             response (0, 0).  Other ops: response (2, 0), still armed.
//   timeouts: a partial match times out (tr_timeout, its prefix owed) on the first clock it has
//             had no byte for TM clocks, no byte is put and a token has room; armed, after TF
//             clocks without a byte (or since the DMI response) and no byte put: disarm.
//   responses: each on dbg_tx as DB, status, data[31:24] .. data[7:0]; dbg_tx_pending holds
//             from its first byte to its last and only while a response is owed.
//   assumed:  bytes put at least G clocks apart (the UART receiver: a frame is 10 bit times, >= 250
//             clocks in the SoC; G = 5 covers those; cover: G = 1, FV_G1, for depth); gets only when ready; the host protocol
//             (scripts/dmi.py): a request starts only when the previous one's response has been
//             taken; the debug server answers each request once, after taking it.
// The INVARIANTS section names internals for k-induction only.
`ifndef UD_TOP
`ifdef FV_REAL
`define UD_TOP mkUart_DMI_Bridge_Real
`define UD_TF 50000000
`define UD_TM 500000
`else
`define UD_TOP mkUart_DMI_Bridge_Fv
`define UD_TF 24
`define UD_TM 10
`endif
`endif
`ifndef UD_G
`ifdef FV_G1
`define UD_G 1
`else
`define UD_G 5
`endif
`endif
`default_nettype none
module uart_dmi_wb #(parameter integer TF = 24, parameter integer TM = 10, parameter integer G = 5) (
    input wire         clk, rst_n,
    input wire         put_en, input wire [7:0] put_b,
    input wire         con_en, con_rdy, input wire [7:0] con_d,
    input wire         dbg_en, dbg_rdy, input wire [7:0] dbg_d, input wire dbg_pending,
    input wire         req_en, req_rdy, input wire [135:0] req_d,
    input wire         rsp_en, rsp_rdy, input wire [71:0] rsp_d,
    input wire [8:0]   tr_feed, input wire tr_drop, tr_rsp_lost, tr_timeout, tr_dmi_done,
    // internals (induction only)
    input wire [2:0]   g_state, input wire [3:0] g_sync, input wire [2:0] g_cnt, input wire [7:0] g_op,
    input wire [6:0]   g_addr, input wire [31:0] g_data, input wire [1:0] g_dmi_op,
    input wire [39:0]  g_dmi_rsp, input wire g_dmi_rsp_v, input wire [3:0] g_feed_pos,
    input wire [25:0]  g_idle, input wire [40:0] g_rsp_req, input wire [2:0] g_tx_cnt,
    input wire [47:0]  g_tx_shift,
    input wire        rp_ne, rp_nf, rp_re, input wire [3:0] rp_head, rp_tail, input wire [12:0] rp_d,
    input wire [12:0] rp_a0, rp_a1, rp_a2, rp_a3, rp_a4, rp_a5, rp_a6, rp_a7, rp_a8, rp_a9, rp_a10, rp_a11, rp_a12, rp_a13, rp_a14,
    input wire        cs_ne, cs_nf, cs_re, input wire [4:0] cs_head, cs_tail, input wire [7:0] cs_d,
    input wire [7:0] cs_a0, cs_a1, cs_a2, cs_a3, cs_a4, cs_a5, cs_a6, cs_a7, cs_a8, cs_a9, cs_a10, cs_a11, cs_a12, cs_a13, cs_a14, cs_a15, cs_a16, cs_a17, cs_a18, cs_a19, cs_a20, cs_a21, cs_a22, cs_a23, cs_a24, cs_a25, cs_a26, cs_a27, cs_a28, cs_a29, cs_a30,
    input wire        dt_ne, dt_nf, dt_re, input wire [2:0] dt_head, dt_tail, input wire [7:0] dt_d,
    input wire [7:0] dt_a0, dt_a1, dt_a2, dt_a3, dt_a4, dt_a5, dt_a6,
    input wire        fr_ne, fr_nf, fr_re, input wire [1:0] fr_head, fr_tail, input wire [39:0] fr_d,
    input wire [39:0] fr_a0, fr_a1, fr_a2,
    input wire        aq_ne, aq_nf, input wire [40:0] aq_d,
    input wire        ar_ne, ar_nf, input wire [135:0] ar_d,
    input wire        as_ne, as_nf, input wire [71:0] as_d,
    input wire [6:0]  a_addr, input wire [31:0] a_data, input wire [1:0] a_op
);
    wire rst = !rst_n;
    localparam [63:0] MAG = {8'h04, 8'h03, 8'h02, 8'h01, 8'h4D, 8'h44, 8'h53, 8'hDB};
    function [7:0] mag (input [3:0] i); mag = MAG[8*i[2:0] +: 8]; endfunction
    localparam [1:0] HUNT = 2'd0, MAGIC = 2'd1, FRAME = 2'd2, BUSY = 2'd3;
    reg [1:0] mode = HUNT; reg [3:0] k = 4'd0; reg [2:0] cnt = 3'd0;
    reg [7:0] op = 8'd0, addr = 8'd0; reg [31:0] data = 32'd0;
    reg [31:0] idle = 32'd0;                     // clocks since the last byte (or DMI response)

    // ---------------- the environment ----------------
    reg [1:0] out_n = 2'd0;                      // requests taken, not yet answered
    reg [3:0] gap = 4'd15;                       // clocks since the last byte put (saturating)
    reg [1:0] pr = 2'd0;                         // requests (frames) whose response is not yet taken
    reg [2:0] ti = 3'd0;                         // bytes of the head response taken
    wire frame_end = put_en && mode == FRAME && cnt == 3'd5;
    always @(posedge clk) begin
        out_n <= out_n + (req_en ? 2'd1 : 2'd0) - (rsp_en ? 2'd1 : 2'd0);
        gap <= put_en ? 4'd0 : (gap == 4'd15 ? gap : gap + 4'd1);
        pr <= pr + (frame_end ? 2'd1 : 2'd0) - ((dbg_en && ti == 3'd5) ? 2'd1 : 2'd0);
        if (rst) begin out_n <= 2'd0; gap <= 4'd15; pr <= 2'd0; end
    end
    always @(*) begin
        if (put_en) assume (gap >= G - 1);
        if (put_en && (mode == BUSY || (mode == FRAME && cnt == 3'd0))) assume (pr == 2'd0);
        if (con_en) assume (con_rdy);
        if (dbg_en) assume (dbg_rdy);
        if (req_en) assume (req_rdy);
        if (rsp_en) assume (rsp_rdy && out_n != 2'd0);
    end

    // ---------------- the model ----------------
    // the console: owed tokens {prefix length, has byte, byte}, in order; p: bytes of the head fed
    wire [12:0] o_h; wire [4:0] o_n; wire [207:0] o_e; reg [3:0] p = 4'd0;
    wire [3:0] h_k = o_h[12:9]; wire h_has = o_h[8];
    wire [7:0] h_byte = (p < h_k) ? mag(p) : o_h[7:0];
    wire h_last = (p + 4'd1) == h_k + (h_has ? 4'd1 : 4'd0);
    reg  want; reg [12:0] o_din;
    wire o_push = want && o_n < 5'd16;
    fv_queue #(.W(13), .D(16), .NW(5)) qo (.clk(clk), .rst(rst), .push(o_push), .din(o_din),
        .pop(tr_feed[8] && h_last), .head(o_h), .n(o_n), .full(), .ents(o_e));
    wire [7:0] c_h; wire [5:0] c_n; wire [255:0] c_e;
    fv_queue #(.W(8), .D(32), .NW(6)) qc (.clk(clk), .rst(rst), .push(tr_feed[8]), .din(tr_feed[7:0]),
        .pop(con_en), .head(c_h), .n(c_n), .full(), .ents(c_e));
    // requests, DMI responses, response records
    reg  q_push; reg [135:0] q_din;
    wire [135:0] q_h; wire [3:0] q_n;
    fv_queue #(.W(136), .D(2)) qq (.clk(clk), .rst(rst), .push(q_push), .din(q_din),
        .pop(req_en), .head(q_h), .n(q_n), .full(), .ents());
    wire [31:0] d_h; wire [3:0] d_n;
    fv_queue #(.W(32), .D(2)) qd (.clk(clk), .rst(rst), .push(rsp_en), .din(rsp_d[31:0]),
        .pop(tr_dmi_done), .head(d_h), .n(d_n), .full(), .ents());
    reg  r_push; reg [39:0] r_din;
    wire [39:0] r_h; wire [3:0] r_n;
    fv_queue #(.W(40), .D(2)) qr (.clk(clk), .rst(rst), .push(r_push), .din(r_din),
        .pop(dbg_en && ti == 3'd5), .head(r_h), .n(r_n), .full(), .ents());
    wire [47:0] r_bytes = {8'hDB, r_h};
    wire [7:0] r_byte = r_bytes[8*(5 - ti) +: 8];

    wire to_magic = !put_en && mode == MAGIC && idle >= TM - 1 && o_n < 5'd16;
    wire to_frame = !put_en && mode == FRAME && idle >= TF - 1;
    reg [1:0] n_mode; reg [3:0] n_k; reg [2:0] n_cnt; reg [7:0] n_op, n_addr; reg [31:0] n_data;
    reg n_idle0;
    always @(*) begin
        n_mode = mode; n_k = k; n_cnt = cnt; n_op = op; n_addr = addr; n_data = data; n_idle0 = 1'b0;
        want = 1'b0; o_din = 13'd0; q_push = 1'b0; q_din = 136'd0; r_push = 1'b0; r_din = 40'd0;
        if (put_en) begin
            n_idle0 = 1'b1;
            case (mode)
            HUNT:  if (put_b == mag(4'd0)) begin n_mode = MAGIC; n_k = 4'd1; end
                   else begin want = 1'b1; o_din = {4'd0, 1'b1, put_b}; end
            MAGIC: if (put_b == mag(k)) begin
                       if (k == 4'd7) begin n_mode = FRAME; n_cnt = 3'd0; n_k = 4'd0; end else n_k = k + 4'd1;
                   end else begin
                       want = 1'b1; o_din = {k, put_b != mag(4'd0), put_b};
                       if (put_b == mag(4'd0)) n_k = 4'd1; else begin n_mode = HUNT; n_k = 4'd0; end
                   end
            FRAME: begin
                       if (cnt == 3'd0) n_op = put_b;
                       else if (cnt == 3'd1) n_addr = put_b;
                       else n_data = {data[23:0], put_b};
                       n_cnt = cnt + 3'd1;
                       if (cnt == 3'd5) begin
                           n_cnt = 3'd0;
                           if (op == 8'h72 || op == 8'h77) begin
                               n_mode = BUSY; q_push = 1'b1;
                               q_din = {op == 8'h72 ? 8'd10 : 8'd11, 57'd0, addr[6:0],
                                        op == 8'h77 ? {32'd0, data[23:0], put_b} : 64'd0};
                           end else begin
                               r_push = 1'b1; r_din = {op == 8'h71 ? 8'h00 : 8'h02, 32'd0};
                               if (op == 8'h71) begin n_mode = HUNT; n_k = 4'd0; end
                           end
                       end
                   end
            default: ;
            endcase
        end else if (to_magic) begin
            n_mode = HUNT; n_k = 4'd0; want = 1'b1; o_din = {k, 1'b0, 8'd0};
        end else if (to_frame) begin
            n_mode = HUNT; n_k = 4'd0;
        end else if (mode == BUSY && tr_dmi_done) begin
            n_mode = FRAME; n_cnt = 3'd0; n_idle0 = 1'b1; r_push = 1'b1; r_din = {8'h00, d_h};
        end
    end
    always @(posedge clk) begin
        mode <= n_mode; k <= n_k; cnt <= n_cnt; op <= n_op; addr <= n_addr; data <= n_data;
        idle <= (n_idle0 || n_mode == HUNT || n_mode == BUSY) ? 32'd0
              : (idle == 32'hFFFF_FFFF ? idle : idle + 32'd1);
        if (tr_feed[8]) p <= h_last ? 4'd0 : p + 4'd1;
        if (dbg_en) ti <= (ti == 3'd5) ? 3'd0 : ti + 3'd1;
        if (rst) begin mode <= HUNT; k <= 4'd0; cnt <= 3'd0; idle <= 32'd0; p <= 4'd0; ti <= 3'd0; end
    end

    // ---------------- properties ----------------
    always @(*) if (rst_n) begin
        assert (tr_feed[8] == (o_n != 5'd0 && c_n < 6'd32 && !put_en));
        if (tr_feed[8]) assert (tr_feed[7:0] == h_byte);
        assert (con_rdy == (c_n != 6'd0));
        if (con_rdy) assert (con_d == c_h);
        assert (tr_drop == (want && o_n == 5'd16));
        assert (tr_timeout == (to_magic || to_frame));
        assert (!tr_rsp_lost);
        if (req_rdy) assert (q_n != 4'd0 && req_d == q_h);
        if (tr_dmi_done) assert (mode == BUSY && d_n != 4'd0 && !put_en);
        if (dbg_rdy) assert (r_n != 4'd0 && dbg_d == r_byte);
        if (ti != 3'd0) assert (dbg_pending);
        if (dbg_pending) assert (r_n != 4'd0);
    end
    // progress: the request reaches client.request, the response comes back, its bytes go out
    reg [3:0] w_req = 4'd0, w_done = 4'd0, w_tx = 4'd0;
    always @(posedge clk) begin
        w_req  <= (q_n != 4'd0 && !req_rdy) ? w_req + 4'd1 : 4'd0;
        w_done <= (d_n != 4'd0 && !tr_dmi_done) ? w_done + 4'd1 : 4'd0;
        w_tx   <= (r_n != 4'd0 && !dbg_rdy) ? w_tx + 4'd1 : 4'd0;
        if (rst) begin w_req <= 4'd0; w_done <= 4'd0; w_tx <= 4'd0; end
    end
    always @(*) if (rst_n) assert (w_req < 4'd6 && w_done < 4'd6 && w_tx < 4'd6);

    // ---------------- reachability ----------------
    always @(*) if (rst_n) begin
        cover (tr_timeout && mode == MAGIC);                 // a partial match released
        cover (tr_timeout && mode == FRAME);                 // armed, idle: disarmed
        cover (tr_dmi_done);                                 // a DMI round trip
        cover (dbg_en && ti == 3'd5 && r_h[39:32] == 8'h00); // a response sent
        cover (tr_feed[8] && tr_feed[7:0] == 8'hDB);         // a 0xDB given back to the console
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    wire [25:0] lim_m = TM - 1, lim_f = TF - 1;
    wire [2:0] busy_n = (aq_ne ? 3'd1 : 3'd0) + (ar_ne ? 3'd1 : 3'd0) + (as_ne ? 3'd1 : 3'd0);
    // the response record's place: one of four
    wire rec_req = g_rsp_req[40], rec_dmi = g_dmi_rsp_v, rec_f = fr_ne, rec_tx = g_tx_cnt != 3'd0 || dt_ne;
    wire [2:0] dt_n = (r_n != 4'd0 && rec_tx) ? 3'd6 - g_tx_cnt - ti : 3'd0;
    reg [63:0] dt_e; integer j;
    always @(*) begin
        dt_e = 64'd0;
        for (j = 0; j < 6; j = j + 1) if (j < 6 - ti) dt_e[8*j +: 8] = r_bytes[8*(5 - ti - j) +: 8];
    end
    integer i;
    always @(*) if (rst_n) begin
        i = 0;
        // mode
        if (mode == HUNT)  assert (g_state == 3'd0 && g_idle == 26'd0);
        if (mode == MAGIC) assert (g_state == 3'd1 && g_sync == k && k >= 4'd1 && k <= 4'd7
                                   && g_idle == (idle > lim_m ? lim_m : idle[25:0]));
        if (mode == FRAME) assert (g_state == 3'd2 && g_cnt == cnt && cnt <= 3'd5
                                   && g_idle == (idle > lim_f ? lim_f : idle[25:0]) && idle <= lim_f);
        if (mode == BUSY)  assert (g_state >= 3'd3 && g_state <= 3'd5 && g_idle == 26'd0);
        if (mode != MAGIC) assert (k == 4'd0);
        if (mode == FRAME && cnt >= 3'd1) assert (g_op == op);
        if (mode == FRAME && cnt >= 3'd2) assert (g_addr == addr[6:0]);
        if (mode == FRAME && cnt == 3'd3) assert (g_data[7:0] == data[7:0]);
        if (mode == FRAME && cnt == 3'd4) assert (g_data[15:0] == data[15:0]);
        if (mode == FRAME && cnt == 3'd5) assert (g_data[23:0] == data[23:0]);
        // the console path
        assert (g_feed_pos == p);
        if (o_n != 5'd0) assert (p < h_k + (h_has ? 4'd1 : 4'd0)); else assert (p == 4'd0);
        for (i = 0; i < 16; i = i + 1)
            if (i < o_n) assert (o_e[13*i+9 +: 4] <= 4'd7 && (o_e[13*i+9 +: 4] != 4'd0 || o_e[13*i+8]));
        // the DMI path: one request in flight
        assert (out_n <= 2'd1 && q_n <= 4'd1 && d_n <= 4'd1 && r_n <= 4'd1 && pr <= 2'd1);
        if (mode == BUSY) begin
            assert ({2'd0, q_n} + {2'd0, out_n} + {2'd0, d_n} == 4'd1 && r_n == 4'd0 && pr == 2'd1);
            assert (g_addr == addr[6:0] && g_data == data && g_dmi_op == (op == 8'h72 ? 2'd1 : 2'd2));
            assert (q_n == 4'd0 || q_h == {op == 8'h72 ? 8'd10 : 8'd11, 57'd0, addr[6:0],
                                           op == 8'h77 ? {32'd0, data} : 64'd0});
            assert (op == 8'h72 || op == 8'h77);
            if (g_state == 3'd3) assert (q_n == 4'd1 && busy_n == 3'd0);
            if (g_state == 3'd4) assert (q_n == 4'd1 && busy_n == 3'd0 && a_addr == g_addr
                                         && a_data == g_data && a_op == g_dmi_op);
            if (g_state == 3'd5) assert ({1'b0, busy_n} + {2'd0, out_n} == 4'd1
                                         && (q_n == 4'd1) == (aq_ne || ar_ne) && d_n == {3'd0, as_ne});
        end else
            assert (q_n == 4'd0 && out_n == 2'd0 && d_n == 4'd0 && busy_n == 3'd0);
        assert (aq_nf && ar_nf && as_nf);
        if (aq_ne) assert (aq_d == {g_addr, g_data, g_dmi_op});
        if (ar_ne) assert (ar_d == q_h);
        if (as_ne) assert (as_d[31:0] == d_h);
        // the response record
        assert ({2'd0, rec_req} + {2'd0, rec_dmi} + {2'd0, rec_f} + {2'd0, rec_tx} == {2'd0, r_n[0]});
        if (mode != BUSY) assert (r_n == {2'd0, pr});
        if (mode == FRAME && cnt != 3'd0) assert (pr == 2'd0);   // a request starts after the response
        if (rec_req) assert (g_rsp_req[39:0] == r_h && ti == 3'd0);
        if (rec_dmi) assert (g_dmi_rsp == r_h && ti == 3'd0);
        if (rec_f)   assert (fr_d == r_h && ti == 3'd0);
        if (g_tx_cnt != 3'd0) assert (g_tx_shift == r_bytes << (8 * (6 - g_tx_cnt)) && ti <= 3'd6 - g_tx_cnt);
        if (r_n == 4'd0) assert (ti == 3'd0);
        assert (ti <= 3'd5 && g_tx_cnt <= 3'd6);
        // the progress counters, by where the request / record is
        assert (w_done == 4'd0);
        if (q_n == 4'd0) assert (w_req == 4'd0);
        if (g_state == 3'd3) assert (w_req == 4'd0);
        if (g_state == 3'd4) assert (w_req <= 4'd1);
        if (aq_ne) assert (w_req <= 4'd2);
        if (ar_ne) assert (w_req <= 4'd3);
        if (r_n == 4'd0) assert (w_tx == 4'd0);
        if (rec_req || rec_dmi) assert (w_tx <= 4'd1);
        if (rec_f) assert (w_tx <= 4'd2);
        if (rec_tx && !dt_ne) assert (w_tx <= 4'd3);
    end
    sizedfifo_inv #(.W(13), .DEPTH(16), .CW(4), .D(16), .NW(5)) rp_inv (.en(rst_n),
        .hasodata(rp_ne), .ring_empty(rp_re), .not_ring_full(rp_nf), .head(rp_head), .tail(rp_tail),
        .arr({rp_a14, rp_a13, rp_a12, rp_a11, rp_a10, rp_a9, rp_a8, rp_a7, rp_a6, rp_a5, rp_a4, rp_a3, rp_a2, rp_a1, rp_a0}), .dout(rp_d), .n(o_n), .ents(o_e));
    sizedfifo_inv #(.W(8), .DEPTH(32), .CW(5), .D(32), .NW(6)) cs_inv (.en(rst_n),
        .hasodata(cs_ne), .ring_empty(cs_re), .not_ring_full(cs_nf), .head(cs_head), .tail(cs_tail),
        .arr({cs_a30, cs_a29, cs_a28, cs_a27, cs_a26, cs_a25, cs_a24, cs_a23, cs_a22, cs_a21, cs_a20, cs_a19, cs_a18, cs_a17, cs_a16, cs_a15, cs_a14, cs_a13, cs_a12, cs_a11, cs_a10, cs_a9, cs_a8, cs_a7, cs_a6, cs_a5, cs_a4, cs_a3, cs_a2, cs_a1, cs_a0}), .dout(cs_d), .n(c_n), .ents(c_e));
    sizedfifo_inv #(.W(8), .DEPTH(8), .CW(3), .D(8), .NW(3)) dt_inv (.en(rst_n),
        .hasodata(dt_ne), .ring_empty(dt_re), .not_ring_full(dt_nf), .head(dt_head), .tail(dt_tail),
        .arr({dt_a6, dt_a5, dt_a4, dt_a3, dt_a2, dt_a1, dt_a0}), .dout(dt_d), .n(dt_n), .ents(dt_e));
    sizedfifo_inv #(.W(40), .DEPTH(4), .CW(2), .D(4), .NW(1)) fr_inv (.en(rst_n),
        .hasodata(fr_ne), .ring_empty(fr_re), .not_ring_full(fr_nf), .head(fr_head), .tail(fr_tail),
        .arr({fr_a2, fr_a1, fr_a0}), .dout(fr_d), .n(rec_f), .ents({120'd0, r_h}));
`endif
endmodule

bind `UD_TOP uart_dmi_wb #(.TF(`UD_TF), .TM(`UD_TM), .G(`UD_G)) wb (
    .clk(CLK), .rst_n(RST_N),
    .put_en(EN_rx_from_uart_put), .put_b(rx_from_uart_put),
    .con_en(EN_rx_to_console_get), .con_rdy(RDY_rx_to_console_get), .con_d(rx_to_console_get),
    .dbg_en(EN_dbg_tx_get), .dbg_rdy(RDY_dbg_tx_get), .dbg_d(dbg_tx_get), .dbg_pending(dbg_tx_pending),
    .req_en(EN_client_request_get), .req_rdy(RDY_client_request_get), .req_d(client_request_get),
    .rsp_en(EN_client_response_put), .rsp_rdy(RDY_client_response_put), .rsp_d(client_response_put),
    .tr_feed(tr_feed), .tr_drop(tr_drop), .tr_rsp_lost(tr_rsp_lost),
    .tr_timeout(tr_timeout), .tr_dmi_done(tr_dmi_done),
    .g_state(m_rg_state), .g_sync(m_rg_sync_idx), .g_cnt(m_rg_cnt), .g_op(m_rg_op), .g_addr(m_rg_addr),
    .g_data(m_rg_data), .g_dmi_op(m_rg_dmi_op), .g_dmi_rsp(m_rg_dmi_rsp), .g_dmi_rsp_v(m_rg_dmi_rsp_v),
    .g_feed_pos(m_rg_feed_pos), .g_idle(m_rg_idle_cnt), .g_rsp_req(m_rg_rsp_req),
    .g_tx_cnt(m_rg_tx_cnt), .g_tx_shift(m_rg_tx_shift),
    .rp_ne(\m_f_replay$EMPTY_N ), .rp_nf(\m_f_replay$FULL_N ), .rp_d(\m_f_replay$D_OUT ), .rp_re(), .rp_head(), .rp_tail(),
    .rp_a0(), .rp_a1(), .rp_a2(), .rp_a3(), .rp_a4(), .rp_a5(), .rp_a6(), .rp_a7(), .rp_a8(), .rp_a9(), .rp_a10(), .rp_a11(), .rp_a12(), .rp_a13(), .rp_a14(),
    .cs_ne(\m_f_console$EMPTY_N ), .cs_nf(\m_f_console$FULL_N ), .cs_d(\m_f_console$D_OUT ), .cs_re(), .cs_head(), .cs_tail(),
    .cs_a0(), .cs_a1(), .cs_a2(), .cs_a3(), .cs_a4(), .cs_a5(), .cs_a6(), .cs_a7(), .cs_a8(), .cs_a9(), .cs_a10(), .cs_a11(), .cs_a12(), .cs_a13(), .cs_a14(), .cs_a15(), .cs_a16(), .cs_a17(), .cs_a18(), .cs_a19(), .cs_a20(), .cs_a21(), .cs_a22(), .cs_a23(), .cs_a24(), .cs_a25(), .cs_a26(), .cs_a27(), .cs_a28(), .cs_a29(), .cs_a30(),
    .dt_ne(\m_f_dbg_tx$EMPTY_N ), .dt_nf(\m_f_dbg_tx$FULL_N ), .dt_d(\m_f_dbg_tx$D_OUT ), .dt_re(), .dt_head(), .dt_tail(),
    .dt_a0(), .dt_a1(), .dt_a2(), .dt_a3(), .dt_a4(), .dt_a5(), .dt_a6(),
    .fr_ne(\m_f_rsp$EMPTY_N ), .fr_nf(\m_f_rsp$FULL_N ), .fr_d(\m_f_rsp$D_OUT ), .fr_re(), .fr_head(), .fr_tail(),
    .fr_a0(), .fr_a1(), .fr_a2(),
    .aq_ne(), .aq_nf(), .aq_d(),
    .ar_ne(), .ar_nf(), .ar_d(),
    .as_ne(), .as_nf(), .as_d(),
    .a_addr(), .a_data(), .a_op());   // taps (uart_dmi.cfg)

`default_nettype wire
