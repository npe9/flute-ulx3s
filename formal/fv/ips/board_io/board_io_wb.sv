// board_io_wb: the checker for src/Board_IO.v, bound into the DUT (no RTL changes).
// Properties on the ports and the trace port, against the register model generated from
// board_io.regs and the I2C host monitor (vip/i2c/i2c_host_mon.sv), which checks the wires
// against the trace:
//   bus:     the regbus VIP (one ack per request, one cycle after it), the register model
//   gpio1:   BTN, SW, the ESP32 TX level and the HDMI CEC/HPD/Utility levels read the pins through
//            two flops (PWR inverted); ESP32 EN/STRAP and CEC_LOW drive their pins from what was
//            last written (released through reset); POWER and RECONF are set only by their magic
//            words (all four lanes), held until reset, and drive their pins
//   i2c0:    a command starts exactly when software writes CR with EN set, no command in progress
//            and one of STA/STO/RD/WR, with those flags and the TXR last written; it is abandoned
//            (and held lines released) exactly when EN is clear during it or with a line held; the engine acts (trace) only during a command
//            with EN set; SR reads {RxACK, busy, AL, 0, 0, 0, TIP, done flag}: TIP from a start to
//            its end, the done flag set at the end and cleared by IACK, AL the way the last command
//            ended, RxACK the last write's acknowledge; RXR the last byte read; busy follows the
//            START and STOP conditions on the wires, seen through two flops
//            (from the first one seen after the synchronizers fill); both lines released the
//            cycle after EN is clear, and after reset
//   time:    a command ends within 55 ticks of PRER + 1 clocks, and no more than 5 ticks pass
//            between its steps (its start, START, each SCL pulse, its end), not counting ticks at
//            which SCL (through the synchronizer) is held low while the host has released it
//   assumed: the bridge's protocol (regbus_vip, proved of AXI4_RegBus by formal/regbus); software
//            never sets RD and WR together; the I2C bus as i2c_host_mon models it.
// The INVARIANTS section names internals for k-induction only.
`default_nettype none
module board_io_wb (
    input wire        clk, rst,
    input wire        rb_valid, rb_we, input wire [15:0] rb_addr, input wire [31:0] rb_wdata,
    input wire [3:0]  rb_wstrb, input wire rb_ack, input wire [31:0] rb_rdata,
    input wire [6:0]  btn_i, input wire [3:0] sw_i,
    input wire        esp32_tx_i, cec_i, hpd_i, util_i, scl_i, sda_i,
    input wire        scl_low, sda_low, esp32_en, esp32_strap, shutdown, reconf, cec_low,
    input wire        tr_cmd_valid, input wire [4:0] tr_cmd, input wire [7:0] tr_cmd_tx,
    input wire        tr_start, tr_stop, tr_rx_valid, input wire [7:0] tr_rx,
    input wire        tr_ack_valid, tr_ack, tr_done, tr_al, tr_abort,
    // internals (induction only)
    input wire [2:0]  state, ph, input wire [3:0] bits, input wire [7:0] shift, input wire [15:0] cnt,
    input wire        c_sta, c_sto, c_rd, c_wr, c_ack, tip, irq_flag, al, rxack, busy,
    input wire [7:0]  rxr, txr, ctr, input wire [15:0] prer,
    input wire [1:0]  scl_m, sda_m, etx_m, cec_m, hpd_m, util_m,
    input wire [6:0]  btn_m, btn_s, input wire [3:0] sw_m, sw_s, input wire sda_q, scl_q
);
    // ---------------- the bus and the register model ----------------
    wire bw, br; wire [15:0] bw_a, br_a; wire [31:0] bw_d, br_d; wire [3:0] bw_s;
    regbus_vip #(.DUT_IS_DEST(1), .AW(16)) bus (.clk(clk), .rst(rst), .abandon(1'b0), .valid(rb_valid), .we(rb_we),
        .addr(rb_addr), .wdata(rb_wdata), .wstrb(rb_wstrb), .ack(rb_ack), .rdata(rb_rdata),
        .wr(bw), .wr_addr(bw_a), .wr_data(bw_d), .wr_strb(bw_s), .rd(br), .rd_addr(br_a), .rd_data(br_d));
    wire [7:0] s_PRERLO, s_PRERHI, s_CTR, s_TXR; wire s_ESP32_EN, s_STRAP, s_CEC_LOW;
    board_io_regs regs (.clk(clk), .rst(rst), .wr(bw), .wr_addr(bw_a), .wr_data(bw_d), .wr_strb(bw_s),
        .rd(br), .rd_addr(br_a), .rd_data(br_d), .s_PRERLO(s_PRERLO), .s_PRERHI(s_PRERHI), .s_CTR(s_CTR),
        .s_TXR(s_TXR), .s_ESP32_EN(s_ESP32_EN), .s_STRAP(s_STRAP), .s_CEC_LOW(s_CEC_LOW));
    wire        take   = rb_valid && !rb_ack;
    wire [15:0] w_at   = bw_a & 16'hF01C;
    wire        w_cr   = bw && w_at == 16'h6010 && bw_s[0];
    wire [15:0] s_prer = {s_PRERHI, s_PRERLO};
    wire        s_en   = s_CTR[7];
    reg         r_q = 1'b1;
    always @(posedge clk) r_q <= rst;

    // software: never RD and WR together
    always @(*) if (!rst && w_cr) assume (!(bw_d[5] && bw_d[4]));

    // ---------------- the pins through two flops ----------------
    reg [1:0] age = 2'd0;
    always @(posedge clk) if (age != 2'd3) age <= age + 2'd1;
    reg [6:0] b1, b2; reg [3:0] w1, w2; reg e1, e2, c1, c2, h1, h2, u1, u2, sc1, sc2, sc3, sd1, sd2, sd3;
    always @(posedge clk) begin
        b1 <= btn_i;  b2 <= b1;  w1 <= sw_i;  w2 <= w1;  e1 <= esp32_tx_i;  e2 <= e1;
        c1 <= cec_i;  c2 <= c1;  h1 <= hpd_i;  h2 <= h1;  u1 <= util_i;  u2 <= u1;
        sc1 <= scl_i; sc2 <= sc1; sc3 <= sc2; sd1 <= sda_i; sd2 <= sd1; sd3 <= sd2;
    end
    wire filled = (age == 2'd3);

    // ---------------- the I2C model ----------------
    reg m_tip = 1'b0, m_irq = 1'b0, m_al = 1'b0, m_rxack = 1'b0, m_busy = 1'b0, m_bk = 1'b0;
    reg m_sd = 1'b0, m_rc = 1'b0;
    reg [7:0] m_rxr = 8'd0;
    wire c_start = sc2 && sc3 && sd3 && !sd2, c_stop = sc2 && sc3 && !sd3 && sd2;
    always @(posedge clk) begin
        if (tr_cmd_valid) begin m_tip <= 1'b1; m_al <= 1'b0; end
        if (tr_done || tr_abort) m_tip <= 1'b0;
        if (w_cr && bw_d[0]) m_irq <= 1'b0;
        if (tr_done) m_irq <= 1'b1;
        if (tr_al) m_al <= 1'b1;
        if (tr_ack_valid) m_rxack <= tr_ack;
        if (tr_rx_valid) m_rxr <= tr_rx;
        if (c_start) m_busy <= 1'b1;
        if (c_stop) m_busy <= 1'b0;
        if (filled && (c_start || c_stop)) m_bk <= 1'b1;
        if (bw && w_at == 16'h8010 && bw_s == 4'hF && bw_d == 32'h504F4646) m_sd <= 1'b1;
        if (bw && w_at == 16'h8014 && bw_s == 4'hF && bw_d == 32'h52454346) m_rc <= 1'b1;
        if (rst) begin
            m_tip <= 1'b0; m_irq <= 1'b0; m_al <= 1'b0; m_rxack <= 1'b0; m_rxr <= 8'd0;
            m_busy <= 1'b0; m_bk <= 1'b0; m_sd <= 1'b0; m_rc <= 1'b0;
        end
    end

    // the volatile reads, as of the take
    wire [15:0] t_at = rb_addr & 16'hF01C;
    reg  [31:0] e, e_m; reg e_ok;
    always @(*) begin
        e = 32'd0; e_m = 32'hFFFFFFFF; e_ok = 1'b1;
        case (t_at)
            16'h600C: e = {24'd0, m_rxr};
            16'h6010: begin e = {24'd0, m_rxack, m_busy, m_al, 3'b0, m_tip, m_irq}; if (!m_bk) e_m[6] = 1'b0; end
            16'h8004: begin e = {25'd0, b2[6:1], ~b2[0]}; e_ok = filled; end
            16'h8008: begin e = {28'd0, w2}; e_ok = filled; end
            16'h800C: begin e = {29'd0, s_STRAP, e2, s_ESP32_EN}; e_ok = filled; end
            16'h8010: e = {31'd0, m_sd};
            16'h8014: e = {31'd0, m_rc};
            16'h8018: begin e = {21'd0, u2, h2, c2, 7'd0, s_CEC_LOW}; e_ok = filled; end
            default: e_ok = 1'b0;
        endcase
    end
    reg [31:0] e_q, e_mq; reg ok_q = 1'b0;
    always @(posedge clk) if (take) begin e_q <= e; e_mq <= e_m; ok_q <= e_ok && !rb_we; end
    always @(*) if (!rst && br && ok_q) assert ((br_d & e_mq) == (e_q & e_mq));

    // ---------------- pins ----------------
    reg en_q = 1'b0;
    always @(posedge clk) en_q <= s_en;
    always @(*) if (!rst) begin
        assert (esp32_en == s_ESP32_EN && esp32_strap == s_STRAP && cec_low == s_CEC_LOW);
        assert (shutdown == m_sd && reconf == m_rc);
        if (r_q || !en_q) assert (!scl_low && !sda_low);
    end

    // ---------------- commands ----------------
    always @(*) if (!rst) begin
        assert (tr_cmd_valid == (w_cr && s_en && !m_tip && bw_d[7:4] != 4'd0));
        if (tr_cmd_valid) assert (tr_cmd == bw_d[7:3] && tr_cmd_tx == s_TXR);
        assert (tr_abort == (!s_en && (m_tip || scl_low || sda_low)));
        if (tr_start || tr_stop || tr_rx_valid || tr_ack_valid || tr_done) assert (m_tip && s_en);
        if (tr_al) assert (tr_done);
    end

    // the wires, against the trace
    wire pend, started, arm, al_due, lb, scl_wq, sda_wq, scll_q, sdal_q, pulse;
    wire [4:0] q; wire [7:0] tx, got; wire [3:0] n;
    i2c_host_mon #(.HOST_IS_DUT(1)) i2c (.clk(clk), .rst(rst), .scl_low(scl_low), .sda_low(sda_low),
        .scl(scl_i), .sda(sda_i), .cmd_valid(tr_cmd_valid), .cmd(tr_cmd), .cmd_tx(tr_cmd_tx),
        .start(tr_start), .stop(tr_stop), .rx_valid(tr_rx_valid), .rx(tr_rx), .ack_valid(tr_ack_valid),
        .ack(tr_ack), .done(tr_done), .al(tr_al), .abort(tr_abort),
        .pend(pend), .q(q), .tx(tx), .started(started), .arm(arm), .n(n), .got(got), .lb(lb),
        .al_due(al_due), .scl_q(scl_wq), .sda_q(sda_wq), .scll_q(scll_q), .sdal_q(sdal_q), .pulse(pulse));

    // ---------------- time ----------------
    reg [15:0] m_cnt = 16'hFFFF; reg [5:0] m_go = 6'd0; reg [2:0] m_bt = 3'd0;
    wire m_tk    = (m_cnt == 16'd0);
    wire stalled = !scl_low && !sc2;
    always @(posedge clk) begin
        m_cnt <= (m_tk || tr_cmd_valid) ? s_prer : m_cnt - 16'd1;
        if (tr_cmd_valid) m_go <= 6'd0;
        else if (m_tip && m_tk && !stalled && m_go != 6'd63) m_go <= m_go + 6'd1;
        if (tr_cmd_valid || tr_start || pulse) m_bt <= 3'd0;
        else if (m_tip && m_tk && !stalled && m_bt != 3'd7) m_bt <= m_bt + 3'd1;
        if (rst) m_cnt <= 16'hFFFF;
    end
    always @(*) if (!rst && m_tip) assert (m_go <= 6'd54 && m_bt <= 3'd5);

    // ---------------- reachability ----------------
    always @(posedge clk) if (!rst) begin
        cover (tr_start);
        cover (tr_ack_valid && !tr_ack);                       // a byte written and acknowledged
        cover (tr_rx_valid && tr_rx == 8'hA5);                 // a byte read
        cover (tr_stop);
        cover (tr_al);
        cover (m_tip && m_tk && stalled && filled);            // a slave stretching the clock
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    wire [3:0] k    = 4'd8 - bits;                              // data bits done in this byte
    wire [7:0] lowk = (8'd1 << k) - 8'd1;
    wire [7:0] gk   = (n == k + 4'd1) ? {1'b0, got[7:1]} : got;
    wire [7:0] rank_left = 8'd5 - {5'd0, ph};
    wire [7:0] after = c_sto ? 8'd5 : 8'd0;
    reg  [7:0] rank;
    always @(*) case (state)
        3'd1:    rank = rank_left + ((c_rd || c_wr) ? 8'd45 : 8'd0) + after;
        3'd2:    rank = rank_left + ({4'd0, bits} - 8'd1) * 8'd5 + 8'd5 + after;
        3'd3:    rank = rank_left + after;
        3'd4:    rank = rank_left;
        default: rank = 8'd0;
    endcase
    always @(*) if (!rst) begin
        // the registers
        assert (ctr == s_CTR && prer == s_prer && txr == s_TXR && cnt == m_cnt);
        assert (tip == m_tip && irq_flag == m_irq && al == m_al && rxack == m_rxack && rxr == m_rxr);
        if (m_bk) assert (busy == m_busy);
        if (filled) assert (btn_m == b1 && btn_s == {b2[6:1], ~b2[0]} && sw_m == w1 && sw_s == w2
                            && etx_m == {e2, e1} && cec_m == {c2, c1} && hpd_m == {h2, h1} && util_m == {u2, u1}
                            && scl_m == {sc2, sc1} && sda_m == {sd2, sd1} && scl_q == sc3 && sda_q == sd3);
        if (m_tip) assert (filled);
        // the engine
        assert (state <= 3'd4 && ph <= 3'd4 && bits <= 4'd8);
        assert ((state == 3'd0) == !tip);
        if (state == 3'd0) assert (ph == 3'd0);
        if (state == 3'd2) assert (bits != 4'd0);
        if (state == 3'd3) assert (bits == 4'd0);
        if (state == 3'd1) assert (bits == 4'd8 && c_sta);
        if (state == 3'd4) assert (c_sto);
        if (tip) assert (!(c_wr && c_rd));
        if (state == 3'd2 || state == 3'd3) assert (c_wr || c_rd);
        if (tip) assert (rank <= 8'd55 && {2'd0, m_go} + rank <= 8'd55);
        // the monitor
        assert (pend == m_tip);
        if (tip) assert (q == {c_sta, c_sto, c_rd, c_wr, c_ack});
        if (tip) assert (started == (c_sta && (state != 3'd1 || ph == 3'd4)));
        if (state == 3'd1) assert (tx == shift);
        if (state == 3'd2 && c_wr) assert ((shift >> k) == (tx & ~(8'hFF << bits)));
        if (state == 3'd2 && c_rd) assert ((shift & lowk) == (gk & lowk));
        if (state == 3'd3 && c_rd) assert (rxr == got);
        if ((state == 3'd2 || (state == 3'd3 && n == 4'd8)) && n != 4'd0) assert (got[0] == lb);
        if (state == 3'd2 || state == 3'd3) begin
            if (ph <= 3'd2) assert (n == k);
            if (ph == 3'd3) assert (n == k + {3'd0, scl_wq});
            if (ph == 3'd4) assert (n == k + 4'd1 && scl_i && scl_wq && sc2 && lb == sda_i && lb == sd1 && lb == sd2);
            if (ph == 3'd3 && scl_wq) assert (scl_i && lb == sda_i && lb == sd1);
            if (ph == 3'd3 && sc2) assert (scl_wq && lb == sd2);
            if (ph >= 3'd2) assert (arm);
            if (ph == 3'd1) assert (arm || scl_low);
            if (ph >= 3'd2) assert (sda_low == !(state == 3'd3 ? (c_rd ? c_ack : 1'b1) : (c_wr ? shift[7] : 1'b1)));
            if (ph == 3'd1 || ph == 3'd2) assert (scl_low);
            if (ph >= 3'd3) assert (!scl_low);
            assert (al_due == (state == 3'd2 && n == k + 4'd1 && c_wr && shift[7] && !lb));
        end
        if (state == 3'd1) assert (!al_due);
        if (state == 3'd4) begin
            if (ph <= 3'd2) assert (n == (c_rd || c_wr ? 4'd9 : 4'd0));
            if (ph == 3'd3) assert (n == (c_rd || c_wr ? 4'd9 : 4'd0) + {3'd0, scl_wq});
            if (ph == 3'd4) assert (n == (c_rd || c_wr ? 4'd10 : 4'd1) && scl_i && scl_wq);
            if (ph >= 3'd2) assert (arm && sda_low);
            if (ph == 3'd1) assert (arm || scl_low);
            if (ph == 3'd1 || ph == 3'd2) assert (scl_low);
            if (ph >= 3'd3) assert (!scl_low);
            assert (!al_due);
        end
        if (state == 3'd1) begin
            if (ph >= 3'd1 && ph <= 3'd3) assert (!sda_low);
            if (ph >= 3'd2) assert (!scl_low);
            if (ph == 3'd4) assert (sda_low && n == 4'd0 && !arm && scl_i && scl_wq);
        end
        if ((state == 3'd0 && en_q) || (state == 3'd1 && ph == 3'd0)) assert (!sda_low || scl_low);
        assert (scl_wq == sc1 && sda_wq == sd1);
        if (state == 3'd1) assert (m_bt <= ((ph == 3'd4) ? 3'd0 : ph));
        if (state >= 3'd2 && ph <= 3'd2) assert (m_bt <= 3'd2 + ph);
        if (state >= 3'd2 && ph == 3'd3 && scl_wq) assert (m_bt == 3'd0);
        if (state >= 3'd2 && ph == 3'd4) assert (m_bt <= 3'd1);
        if (state >= 3'd2 && ph == 3'd0 && arm && !scl_low) assert (scl_i && scl_wq);
    end
`endif
endmodule

bind board_io board_io_wb wb (
    .clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
    .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata),
    .btn_i(btn_i), .sw_i(sw_i), .esp32_tx_i(esp32_tx_i), .cec_i(cec_i), .hpd_i(hpd_i), .util_i(util_i),
    .scl_i(scl_i), .sda_i(sda_i), .scl_low(scl_low), .sda_low(sda_low), .esp32_en(esp32_en),
    .esp32_strap(esp32_strap), .shutdown(shutdown), .reconf(reconf), .cec_low(cec_low),
    .tr_cmd_valid(tr_cmd_valid), .tr_cmd(tr_cmd), .tr_cmd_tx(tr_cmd_tx), .tr_start(tr_start),
    .tr_stop(tr_stop), .tr_rx_valid(tr_rx_valid), .tr_rx(tr_rx), .tr_ack_valid(tr_ack_valid),
    .tr_ack(tr_ack), .tr_done(tr_done), .tr_al(tr_al), .tr_abort(tr_abort),
    .state(state), .ph(ph), .bits(bits), .shift(shift), .cnt(cnt), .c_sta(c_sta), .c_sto(c_sto),
    .c_rd(c_rd), .c_wr(c_wr), .c_ack(c_ack), .tip(tip), .irq_flag(irq_flag), .al(al), .rxack(rxack),
    .busy(busy), .rxr(rxr), .txr(txr), .ctr(ctr), .prer(prer), .scl_m(scl_m), .sda_m(sda_m),
    .etx_m(etx_m), .cec_m(cec_m), .hpd_m(hpd_m), .util_m(util_m), .btn_m(btn_m), .btn_s(btn_s),
    .sw_m(sw_m), .sw_s(sw_s), .sda_q(sda_q), .scl_q(scl_q));
