// jtagg_dtm_wb: the checker for src/JtaggDtm.bsv (mkJtaggDtm), bound into the DUT.  The RISC-V
// debug transport (debug spec 0.13.2, DTM version 1, abits 7) behind the ECP5 JTAGG primitive.
// Properties on the ports and the trace port:
//   pins:     {JCE2, JCE1, JRSTN, JUPDATE, JSHIFT, JTDI, JTCK}.  A rising JTCK edge acts in the
//             TAP state it leaves (the pins just before it): JRSTN low (Test-Logic-Reset) forgets
//             the selected register; JCE1 / JCE2 with JSHIFT low (Capture-DR, IR ER1 / ER2)
//             selects and loads dmi / dtmcs; JSHIFT (Shift-DR) shifts the selected register right,
//             JTDI (as it is after the edge) in at its top bit (dmi 41 bits, dtmcs 32); JUPDATE
//             (Update-DR) acts on the selected register and deselects it.  The DTM acts 3 clocks
//             after the edge reaches the pins (tr_capture / tr_shift / tr_update then).  On each
//             falling edge in Shift-DR (JSHIFT with JCE1 or JCE2) tdo, as it was in the clock
//             before, is the register's bit 0 as the preceding rising edge left it.
//   dmi:      {address[40:34], data[33:2], op[1:0]}.  Capture loads the address of the last
//             request, the data of the last response and op = dmistat, or 3 while a request is
//             in flight; that busy capture also sets dmistat to 3 (sticky), so the scan's own
//             update is ignored ("the data scanned into dmi in this access will be ignored").
//             An update with dmistat non-zero (or a request in flight) is ignored (tr_ignored);
//             otherwise op 1 / 2 sends a read (10) / write (11) of arg1 = address, arg2 = data on
//             client.request, op 0 / 3 nothing.  One request at a time.
//   dtmcs:    version 1, abits 7, dmistat [11:10], idle 1 [14:12], the rest 0.  An update with
//             dmireset [16] or dmihardreset [17] clears dmistat (a request in flight still
//             completes: Flute's debug module answers every request).
//   response: taken (tr_rsp) in the first clock after client.response.put in which the DTM is
//             not acting on an edge; its data becomes dmi's data; a non-ok status sets dmistat
//             to 2 unless it is already set.  client.response always takes the one outstanding.
//   assumed:  TCK well below the system clock: each JTCK phase lasts at least TH (high) / TL
//             (low) clocks, and JTDI holds for a clock after a rising edge (it is TDI registered
//             on that edge).  The other pins are free: the DTM reads them only just before an
//             edge.  client.request taken only
//             when ready; a response only to a request taken and not yet answered.
// The INVARIANTS section names internals for k-induction only.
// JT_TH / JT_TL: the minimum JTCK high / low phases in clocks.  5 / 1 is the least the DTM needs:
// with a 4-clock high phase the falling edge comes before tdo has the shifted bit (prove fails).
`ifndef JT_TH
`define JT_TH 5
`endif
`ifndef JT_TL
`define JT_TL 1
`endif
`default_nettype none
module jtagg_dtm_wb #(parameter integer TH = 5, parameter integer TL = 1) (
    input wire         clk, rst_n,
    input wire [6:0]   pins, input wire tdo,
    input wire         req_en, req_rdy, input wire [135:0] req_d,
    input wire         rsp_en, rsp_rdy, input wire [71:0] rsp_d,
    input wire [2:0]   tr_capture, input wire [1:0] tr_shift, input wire [43:0] tr_update,
    input wire         tr_ignored, tr_rsp,
    // internals (induction only)
    input wire [6:0]   g_m, g_s, g_p, g_q,
    input wire [40:0]  g_dr, input wire [1:0] g_sel, g_stat, input wire [6:0] g_addr,
    input wire [31:0]  g_data, input wire g_flight,
    input wire         rq_ne, rq_nf, input wire [135:0] rq_d,
    input wire         rs_ne, rs_nf, input wire [71:0] rs_d
);
    localparam [6:0] PIN0 = 7'b0010000;            // the DTM's reset view: JRSTN high, the rest low
    wire rst = !rst_n;
    // pin history: hk = the pins k clocks ago
    reg [6:0] h1 = PIN0, h2 = PIN0, h3 = PIN0, h4 = PIN0;
    always @(posedge clk) begin
        h1 <= rst ? PIN0 : pins; h2 <= rst ? PIN0 : h1; h3 <= rst ? PIN0 : h2; h4 <= rst ? PIN0 : h3;
    end

    // ---------------- the environment ----------------
    reg [7:0] ph = 8'hFF;                          // clocks JTCK has held its level, saturating
    always @(posedge clk) ph <= rst ? 8'hFF : (pins[0] != h1[0]) ? 8'd0 : (ph == 8'hFF ? ph : ph + 8'd1);
    wire tog = pins[0] != h1[0], rise_p = tog && pins[0];
    reg m_out = 1'b0, m_rw = 1'b0;                 // a request taken and unanswered; a response put, not taken
    always @(*) if (!rst) begin
        if (tog) assume (ph >= (h1[0] ? TH - 1 : TL - 1));
        if (h1[0] && !h2[0]) assume (pins[1] == h1[1]);   // JTDI holds a clock past the edge
        if (req_en) assume (req_rdy);
        if (rsp_en) assume (m_out && !m_rw);
    end

    // ---------------- the specification ----------------
    // the edge the DTM acts on now: on the pins 3 clocks ago; the state it leaves: 4 clocks ago
    wire rise_d = h3[0] && !h4[0];
    wire l_rstn = h4[4], l_upd = h4[3], l_sh = h4[2], l_ce1 = h4[5], l_ce2 = h4[6], b = h3[1];
    reg [1:0]  m_sel = 2'd0, m_stat = 2'd0;
    reg [40:0] m_dr = 41'd0;
    reg [6:0]  m_addr = 7'd0;
    reg [31:0] m_data = 32'd0;
    reg        m_flight = 1'b0, m_rq = 1'b0, m_wr = 1'b0;
    reg [6:0]  q_a = 7'd0; reg [31:0] q_d = 32'd0;
    reg [71:0] m_rsp = 72'd0;
    wire ev_tlr = rise_d && !l_rstn;
    wire ev_cap = rise_d && l_rstn && (l_ce1 || l_ce2) && !l_sh;
    wire ev_sh  = rise_d && l_rstn && l_sh && m_sel != 2'd0;
    wire ev_up  = rise_d && l_rstn && !l_sh && !(l_ce1 || l_ce2) && l_upd && m_sel != 2'd0;
    wire take   = m_rw && !rise_d;                 // the response taken now
    wire [31:0] dtmcs = {14'd0, 1'b0, 1'b0, 1'b0, 3'd1, m_stat, 6'd7, 4'd1};
    wire busy_up = m_sel == 2'd1 && (m_stat != 2'd0 || m_flight);
    wire cs_clr  = ev_up && m_sel == 2'd2 && (m_dr[16] || m_dr[17]);   // dmireset / dmihardreset
    wire issue   = ev_up && m_sel == 2'd1 && !busy_up && (m_dr[1:0] == 2'd1 || m_dr[1:0] == 2'd2);
    always @(posedge clk) begin
        if (rst) begin
            m_sel <= 2'd0; m_stat <= 2'd0; m_dr <= 41'd0; m_addr <= 7'd0; m_data <= 32'd0;
            m_flight <= 1'b0; m_rq <= 1'b0; m_out <= 1'b0; m_rw <= 1'b0;
        end else begin
            if (ev_tlr) m_sel <= 2'd0;
            if (ev_cap) begin
                m_sel <= l_ce1 ? 2'd1 : 2'd2;
                if (l_ce1) begin
                    m_dr <= {m_addr, m_data, m_flight ? 2'd3 : m_stat};
                    if (m_flight && m_stat == 2'd0) m_stat <= 2'd3;
                end else
                    m_dr <= {9'd0, dtmcs};
            end
            if (ev_sh) m_dr <= (m_sel == 2'd1) ? {b, m_dr[40:1]} : {9'd0, b, m_dr[31:1]};
            if (ev_up) m_sel <= 2'd0;
            if (cs_clr) m_stat <= 2'd0;
            if (ev_up && busy_up && m_stat == 2'd0) m_stat <= 2'd3;
            if (issue) begin
                m_rq <= 1'b1; m_wr <= m_dr[1:0] == 2'd2; q_a <= m_dr[40:34]; q_d <= m_dr[33:2];
                m_addr <= m_dr[40:34]; m_flight <= 1'b1;
            end
            if (req_en) begin m_rq <= 1'b0; m_out <= 1'b1; end
            if (rsp_en) begin m_out <= 1'b0; m_rw <= 1'b1; m_rsp <= rsp_d; end
            if (take) begin
                m_rw <= 1'b0; m_flight <= 1'b0; m_data <= m_rsp[31:0];
                if (m_rsp[71:64] != 8'd0 && m_stat == 2'd0) m_stat <= 2'd2;
            end
        end
    end
    // tdo as the TAP takes it, the clock before a falling edge on the pins: bit 0 of the register
    // as the preceding rising edge left it (that edge acted on, not pending in the next 3 clocks)
    wire pend = (pins[0] && !h1[0]) || (h1[0] && !h2[0]) || (h2[0] && !h3[0]) || (h3[0] && !h4[0]);
    reg tdo_ok = 1'b1;
    always @(posedge clk) tdo_ok <= tdo == m_dr[0] && !pend;
    wire fall_sh = !pins[0] && h1[0] && h1[2] && (h1[5] || h1[6]);
    always @(*) if (!rst) begin
        // a Maybe's value bits are don't-care while it is Invalid
        assert (tr_capture[2] == ev_cap && (!ev_cap || tr_capture[1:0] == (l_ce1 ? 2'd1 : 2'd2)));
        assert (tr_shift[1] == ev_sh && (!ev_sh || tr_shift[0] == b));
        assert (tr_update[43] == ev_up && (!ev_up || tr_update[42:0] == {m_sel, m_dr}));
        assert (tr_ignored == (ev_up && busy_up));
        assert (tr_rsp == take);
        assert (req_rdy == m_rq);
        if (m_rq) begin
            assert (req_d[135:128] == (m_wr ? 8'd11 : 8'd10) && req_d[127:64] == {57'd0, q_a});
            if (m_wr) assert (req_d[63:0] == {32'd0, q_d});
        end
        if (m_out) assert (rsp_rdy);
        if (fall_sh) assert (tdo_ok);
        assert (!(m_rq && (m_out || m_rw)) && !(m_out && m_rw));    // one request at a time
        assert (m_flight == (m_rq || m_out || m_rw));
    end

    // covers (cover checks only; prove / bmc ignore them)
    reg [2:0] n_sh = 3'd0;
    always @(posedge clk) if (ev_sh && n_sh != 3'd7) n_sh <= n_sh + 3'd1;
    always @(*) if (!rst) begin
`ifdef FV_TAP
        // a real TAP walk: Test-Logic-Reset, an IR scan to ER1 / ER2, Capture-DR
        cover (ev_cap && l_ce1);
        cover (ev_cap && l_ce2);
`else
        cover (issue);
        cover (take && m_rsp[71:64] != 8'd0);
        cover (ev_cap && l_ce1 && m_flight);
        cover (ev_up && m_sel == 2'd2 && m_dr[16]);
        cover (fall_sh && n_sh == 3'd3);
`endif
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    always @(*) if (!rst) begin
        assert (g_m == h1 && g_s == h2 && g_p == h3 && g_q == h4);
        assert (g_sel == m_sel && g_stat == m_stat && g_addr == m_addr && g_data == m_data);
        assert (g_flight == m_flight);
        assert (m_sel == 2'd2 ? g_dr[40:32] == 9'd0 && g_dr[31:0] == m_dr[31:0] : g_dr == m_dr);
        assert (m_sel != 2'd2 || m_dr[40:32] == 9'd0);
        assert (m_sel != 2'd3 && m_stat != 2'd1);                   // dmistat 1 is reserved
        if (m_stat == 2'd2) assert (!m_flight);                     // failed: nothing starts
        assert (rq_nf && rs_nf);                                   // the FIFO2s hold at most one
        assert (rq_ne == m_rq && rs_ne == m_rw);
        if (m_rq) assert (rq_d[135:128] == (m_wr ? 8'd11 : 8'd10) && rq_d[127:64] == {57'd0, q_a}
                          && (!m_wr || rq_d[63:0] == {32'd0, q_d}));
        if (m_rw) assert (rs_d == m_rsp);
        if (m_flight) assert (m_addr == q_a);
        // the pins' history: they change only with a rising JTCK; ph counts the level's age
        if (h2[0] && !h3[0]) assert (h1[1] == h2[1]);
        if (h3[0] && !h4[0]) assert (h2[1] == h3[1]);
        if (ph == 8'd0) assert (h1[0] != h2[0]);
        if (ph == 8'd1) assert (h1[0] == h2[0] && h2[0] != h3[0]);
        if (ph == 8'd2) assert (h1[0] == h2[0] && h2[0] == h3[0] && h3[0] != h4[0]);
        if (ph >= 8'd3) assert (h1[0] == h2[0] && h2[0] == h3[0] && h3[0] == h4[0]);
    end
`endif
endmodule

bind mkJtaggDtm jtagg_dtm_wb #(.TH(`JT_TH), .TL(`JT_TL)) wb (
    .clk(CLK), .rst_n(RST_N), .pins(pins_v), .tdo(tdo),
    .req_en(EN_client_request_get), .req_rdy(RDY_client_request_get), .req_d(client_request_get),
    .rsp_en(EN_client_response_put), .rsp_rdy(RDY_client_response_put), .rsp_d(client_response_put),
    .tr_capture(tr_capture), .tr_shift(tr_shift), .tr_update(tr_update),
    .tr_ignored(tr_ignored), .tr_rsp(tr_rsp),
    .g_m(rg_m), .g_s(rg_s), .g_p(rg_p), .g_q(rg_q), .g_dr(rg_dr), .g_sel(rg_sel), .g_stat(rg_stat),
    .g_addr(rg_addr), .g_data(rg_data), .g_flight(rg_flight),
    .rq_ne(\f_req$EMPTY_N ), .rq_nf(\f_req$FULL_N ), .rq_d(\f_req$D_OUT ),
    .rs_ne(\f_rsp$EMPTY_N ), .rs_nf(\f_rsp$FULL_N ), .rs_d(\f_rsp$D_OUT ));
`default_nettype wire
