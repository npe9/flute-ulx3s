// uart_pins_wb: the checker for src/Uart_Pins.bsv (mkUART_Pins, 8N1, C clocks per bit; instances in
// Uart_Pins_Fv.bsv), bound into the DUT (no RTL changes).  Properties on the ports and trace port:
//   TX:  put queues bytes (16 deep: put is ready below 16).  A byte leaves the queue (tr_tx_load) at
//        once when no frame is on TXD, else at the clock after the frame's last; from the next clock
//        TXD carries its frame (uart_tx_mon: start, the byte LSB first, stop, C clocks per bit), so
//        frames back to back have a stop bit of C+1 clocks.  tx_busy: a frame is on TXD;
//        tr_tx_done: its last clock.  TXD is 1 otherwise.
//   RX:  the receiver sees RXD three clocks late (s: rxd through the input flop and a two-flop
//        synchronizer).  In idle, s low is a start edge (tr_rx_start).  The start is sampled H+1
//        clocks later (H = C/2, truncated): high is a glitch (tr_rx_glitch, back to idle).  Then 8
//        data samples, then the stop sample, each C clocks after the one before (tr_rx_bit: the
//        sample).  The byte is the data samples, the first in bit 0.  Stop high: tr_rx_byte; the
//        byte enters the RX queue (16 deep) unless it is full, when it is dropped (tr_rx_ovf).  Stop
//        low: tr_rx_ferr, nothing queued.  Idle again at the clock after the stop sample.
//        get: ready when the queue has a byte, the head.  rx_overflow / rx_frame_err: sticky since
//        reset (a drop / a framing error).  No tolerance claim: RXD is any sequence and the
//        samples are at the times above, whatever the line's bit time.
//   assumed:  put / get only when ready.
// The INVARIANTS section names internals for k-induction only.
`ifndef UP_C
`ifdef FV_CPB434
`define UP_TOP mkUART_Pins_434
`define UP_C 434
`elsif FV_CPB50
`define UP_TOP mkUART_Pins_50
`define UP_C 50
`elsif FV_CPB5
`define UP_TOP mkUART_Pins_5
`define UP_C 5
`else
`define UP_TOP mkUART_Pins_4
`define UP_C 4
`endif
`endif
`default_nettype none
module uart_pins_wb #(parameter integer C = 4) (
    input wire        clk, rst_n,
    input wire        put_en, put_rdy, input wire [7:0] put_d,
    input wire        get_en, get_rdy, input wire [7:0] get_d,
    input wire        txd, rxd, tx_busy, rx_overflow, rx_frame_err,
    input wire [8:0]  tr_tx_load, input wire tr_tx_done, tr_rx_start, tr_rx_glitch,
    input wire [1:0]  tr_rx_bit, input wire [8:0] tr_rx_byte, input wire tr_rx_ferr, tr_rx_ovf,
    // internals (induction only)
    input wire        g_rx_in, g_rx_meta, g_rx_sync, input wire [1:0] g_rx_state,
    input wire [15:0] g_rx_cnt, input wire [2:0] g_rx_bit, input wire [7:0] g_rx_sh,
    input wire [15:0] g_tx_cnt, input wire [3:0] g_tx_bit, input wire [9:0] g_tx_sh,
    input wire        tq_ne, tq_nf, tq_ring_empty, input wire [3:0] tq_head, tq_tail, input wire [7:0] tq_d,
    input wire        rq_ne, rq_nf, rq_ring_empty, input wire [3:0] rq_head, rq_tail, input wire [7:0] rq_d,
    input wire [7:0]  tq_a0, tq_a1, tq_a2, tq_a3, tq_a4, tq_a5, tq_a6, tq_a7, tq_a8, tq_a9, tq_a10,
                      tq_a11, tq_a12, tq_a13, tq_a14,
    input wire [7:0]  rq_a0, rq_a1, rq_a2, rq_a3, rq_a4, rq_a5, rq_a6, rq_a7, rq_a8, rq_a9, rq_a10,
                      rq_a11, rq_a12, rq_a13, rq_a14
);
    localparam integer H = C / 2;
    wire rst = !rst_n;
    always @(*) begin
        if (put_en) assume (put_rdy);
        if (get_en) assume (get_rdy);
    end

    // ---------------- TX ----------------
    wire [7:0] tq_h; wire [4:0] tq_n; wire [127:0] tq_e;
    fv_queue #(.W(8), .D(16), .NW(5)) qt (.clk(clk), .rst(rst), .push(put_en), .din(put_d),
        .pop(tr_tx_load[8]), .head(tq_h), .n(tq_n), .full(), .ents(tq_e));
    wire t_act, t_last, t_exp; wire [3:0] t_seg; wire [15:0] t_cnt; wire [9:0] t_sh;
    uart_tx_mon #(.C(C)) mon (.clk(clk), .rst(rst), .en(rst_n), .txd(txd),
        .start(tr_tx_load[8]), .byte_in(tr_tx_load[7:0]),
        .act(t_act), .seg(t_seg), .cnt(t_cnt), .sh(t_sh), .last(t_last), .exp(t_exp));
    always @(*) if (rst_n) begin
        assert (put_rdy == (tq_n < 5'd16));
        assert (tr_tx_load[8] == (!t_act && tq_n != 5'd0));
        if (tr_tx_load[8]) assert (tr_tx_load[7:0] == tq_h);
        assert (tx_busy == t_act);
        assert (tr_tx_done == t_last);
    end

    // ---------------- RX ----------------
    reg s0 = 1'b1, s1 = 1'b1, s = 1'b1;          // rxd as the receiver sees it
    reg r_act = 1'b0; reg [3:0] r_seg = 4'd0; reg [15:0] r_cnt = 16'd0; reg [7:0] r_b = 8'd0;
    reg m_ovf = 1'b0, m_ferr = 1'b0;
    wire [15:0] r_len = (r_seg == 4'd0) ? H + 1 : C;
    wire r_samp  = r_act && r_cnt == r_len - 16'd1;
    wire e_start = !r_act && !s;
    wire e_glit  = r_samp && r_seg == 4'd0 && s;
    wire e_bit   = r_samp && r_seg >= 4'd1 && r_seg <= 4'd8;
    wire e_stop  = r_samp && r_seg == 4'd9;
    wire e_byte  = e_stop && s, e_ferr = e_stop && !s;
    wire [7:0] rq_h; wire [4:0] rq_n; wire [127:0] rq_e;
    wire e_ovf   = e_byte && rq_n == 5'd16;
    fv_queue #(.W(8), .D(16), .NW(5)) qr (.clk(clk), .rst(rst), .push(e_byte && !e_ovf), .din(r_b),
        .pop(get_en), .head(rq_h), .n(rq_n), .full(), .ents(rq_e));
    always @(posedge clk) begin
        s0 <= rxd; s1 <= s0; s <= s1;
        if (r_act) begin
            if (r_samp) begin
                r_cnt <= 16'd0;
                if (e_glit || e_stop) r_act <= 1'b0; else r_seg <= r_seg + 4'd1;
            end else r_cnt <= r_cnt + 16'd1;
        end
        if (e_start) begin r_act <= 1'b1; r_seg <= 4'd0; r_cnt <= 16'd0; end
        if (e_bit) r_b <= {s, r_b[7:1]};
        if (e_ovf) m_ovf <= 1'b1;
        if (e_ferr) m_ferr <= 1'b1;
        if (!rst_n) begin
            s0 <= 1'b1; s1 <= 1'b1; s <= 1'b1; r_act <= 1'b0; r_seg <= 4'd0; r_cnt <= 16'd0;
            r_b <= 8'd0; m_ovf <= 1'b0; m_ferr <= 1'b0;
        end
    end
    always @(*) if (rst_n) begin
        assert (tr_rx_start == e_start && tr_rx_glitch == e_glit);
        assert (tr_rx_bit[1] == e_bit); if (e_bit) assert (tr_rx_bit[0] == s);
        assert (tr_rx_byte[8] == e_byte); if (e_byte) assert (tr_rx_byte[7:0] == r_b);
        assert (tr_rx_ferr == e_ferr && tr_rx_ovf == e_ovf);
        assert (rx_overflow == m_ovf && rx_frame_err == m_ferr);
        assert (get_rdy == (rq_n != 5'd0));
        if (get_rdy) assert (get_d == rq_h);
    end

    // ---------------- reachability ----------------
    reg p_done = 1'b0; always @(posedge clk) p_done <= tr_tx_done;
    always @(*) if (rst_n) begin
        cover (tr_tx_done);                                   // a TX frame
        cover (p_done && tr_tx_load[8]);                      // TX back to back
        cover (tr_rx_byte[8] && tr_rx_byte[7:0] == 8'hA5);    // a byte received
        cover (tr_rx_glitch);                                 // a start glitch
        cover (tr_rx_ferr);                                   // a framing error
        cover (rq_n == 5'd2);                                 // two bytes waiting
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    always @(*) if (rst_n) begin
        assert (g_rx_in == s0 && g_rx_meta == s1 && g_rx_sync == s);
        assert (g_rx_sh == r_b);
        if (!r_act) assert (g_rx_state == 2'd0);
        else begin
            assert (r_seg <= 4'd9 && r_cnt < r_len && g_rx_cnt == r_cnt);
            if (r_seg == 4'd0) assert (g_rx_state == 2'd1);
            else if (r_seg <= 4'd8) assert (g_rx_state == 2'd2 && {1'b0, g_rx_bit} == r_seg - 4'd1);
            else assert (g_rx_state == 2'd3);
        end
        if (t_act) assert (g_tx_bit == t_seg && g_tx_cnt == t_cnt && g_tx_sh == t_sh);
    end
    sizedfifo_inv #(.W(8), .DEPTH(16), .CW(4), .D(16), .NW(5)) tq_inv (.en(rst_n),
        .hasodata(tq_ne), .ring_empty(tq_ring_empty), .not_ring_full(tq_nf), .head(tq_head),
        .tail(tq_tail), .arr({tq_a14, tq_a13, tq_a12, tq_a11, tq_a10, tq_a9, tq_a8, tq_a7, tq_a6,
        tq_a5, tq_a4, tq_a3, tq_a2, tq_a1, tq_a0}), .dout(tq_d), .n(tq_n), .ents(tq_e));
    sizedfifo_inv #(.W(8), .DEPTH(16), .CW(4), .D(16), .NW(5)) rq_inv (.en(rst_n),
        .hasodata(rq_ne), .ring_empty(rq_ring_empty), .not_ring_full(rq_nf), .head(rq_head),
        .tail(rq_tail), .arr({rq_a14, rq_a13, rq_a12, rq_a11, rq_a10, rq_a9, rq_a8, rq_a7, rq_a6,
        rq_a5, rq_a4, rq_a3, rq_a2, rq_a1, rq_a0}), .dout(rq_d), .n(rq_n), .ents(rq_e));
`endif
endmodule

bind `UP_TOP uart_pins_wb #(.C(`UP_C)) wb (
    .clk(CLK), .rst_n(RST_N),
    .put_en(EN_put_put), .put_rdy(RDY_put_put), .put_d(put_put),
    .get_en(EN_get_get), .get_rdy(RDY_get_get), .get_d(get_get),
    .txd(txd), .rxd(rxd_v), .tx_busy(tx_busy), .rx_overflow(rx_overflow), .rx_frame_err(rx_frame_err),
    .tr_tx_load(tr_tx_load), .tr_tx_done(tr_tx_done), .tr_rx_start(tr_rx_start),
    .tr_rx_glitch(tr_rx_glitch), .tr_rx_bit(tr_rx_bit), .tr_rx_byte(tr_rx_byte),
    .tr_rx_ferr(tr_rx_ferr), .tr_rx_ovf(tr_rx_ovf),
    .g_rx_in(m_rg_rx_in), .g_rx_meta(m_rg_rx_meta), .g_rx_sync(m_rg_rx_sync),
    .g_rx_state(m_rg_rx_state), .g_rx_cnt(m_rg_rx_cnt), .g_rx_bit(m_rg_rx_bit), .g_rx_sh(m_rg_rx_sh),
    .g_tx_cnt(m_rg_tx_cnt), .g_tx_bit(m_rg_tx_bit), .g_tx_sh(m_rg_tx_sh),
    .tq_ne(\m_f_tx$EMPTY_N ), .tq_nf(\m_f_tx$FULL_N ), .tq_d(\m_f_tx$D_OUT ),
    .rq_ne(\m_f_rx$EMPTY_N ), .rq_nf(\m_f_rx$FULL_N ), .rq_d(\m_f_rx$D_OUT ),
    .tq_ring_empty(), .tq_head(), .tq_tail(), .rq_ring_empty(), .rq_head(), .rq_tail(),   // taps
    .tq_a0(), .tq_a1(), .tq_a2(), .tq_a3(), .tq_a4(), .tq_a5(), .tq_a6(), .tq_a7(), .tq_a8(),
    .tq_a9(), .tq_a10(), .tq_a11(), .tq_a12(), .tq_a13(), .tq_a14(),
    .rq_a0(), .rq_a1(), .rq_a2(), .rq_a3(), .rq_a4(), .rq_a5(), .rq_a6(), .rq_a7(), .rq_a8(),
    .rq_a9(), .rq_a10(), .rq_a11(), .rq_a12(), .rq_a13(), .rq_a14());
`default_nettype wire
