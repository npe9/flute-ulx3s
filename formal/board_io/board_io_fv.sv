// Formal harness for src/Board_IO.v (formal/board_io/board_io.sby).  Unbounded by k-induction.
//   bus:     rb_ack one cycle per request, one cycle after it; ID registers; GPIO reads the pins;
//            ESP32 EN resets to held and changes only on its own register's write; POWER and RECONF
//            latch only on their magic words
//   i2c:     both lines released when disabled or reset (they can only ever be pulled low);
//            SDA changes while SCL is high only as the START or STOP step of a command;
//            a byte written goes out MSB first, the bit on the wire at each SCL high matching the
//            TXR the command took; a read keeps SDA released and RXR gets what was on the wire;
//            the done state and TIP agree; termination: a ranking falls on every tick unless a
//            device is stretching the clock, so a command ends in at most 55 ticks of PRER + 1;
//            a stretched wait phase is not left until SCL is seen high.
//   assumed: the bridge's protocol (AXI4_RegBus, proved in formal/regbus); slaves change SDA only
//            with SCL low (the I2C standard), other than a START or STOP from another master,
//            which is not modelled; software never sets RD and WR together.
//   open:    arbitration lost is reached only through that unmodelled master's write path here.
module board_io_fv (input clk, input [15:0] rb_addr, input rb_valid_i, input rb_we, input [31:0] rb_wdata,
                    input [3:0] rb_wstrb, input [6:0] btn_i, input [3:0] sw_i, input slave_sda_low, input slave_scl_low,
                    input etx_i);
    reg [1:0] rc = 0; wire rst = rc != 2'd3;
    always @(posedge clk) if (rst) rc <= rc + 1;
    reg pv = 0; always @(posedge clk) pv <= 1;

    wire rb_ack; wire [31:0] rb_rdata; wire scl_low, sda_low, esp32_en, shutdown, reconf;
    wire [2:0] st, ph; wire [3:0] bits; wire en, c_wr, c_rd, c_sto, is_tick, tip, scl_s, sda_s; wire [7:0] sh, rxr, txr;
    // the bridge's side of the protocol: valid held with its payload until ack, dropped after it
    wire rb_valid = rb_valid_i && !rst;
    reg ack_q = 0, valid_q = 0; reg [15:0] addr_q; reg we_q; reg [31:0] wd_q; reg [3:0] st_q;
    always @(posedge clk) begin ack_q <= rb_ack; valid_q <= rb_valid; addr_q <= rb_addr; we_q <= rb_we; wd_q <= rb_wdata; st_q <= rb_wstrb; end
    always @(*) if (pv && !rst) begin
        if (valid_q && !ack_q) assume (rb_valid && rb_addr == addr_q && rb_we == we_q && rb_wdata == wd_q && rb_wstrb == st_q);
        if (ack_q) assume (!rb_valid);
        assume (rb_addr[1:0] == 0);
    end
    // a slave only pulls the wires low; the harness models the wires
    wire scl = !(scl_low || slave_scl_low), sda = !(sda_low || slave_sda_low);
    wire esp32_strap;
    board_io dut (.clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
                  .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata), .btn_i(btn_i), .sw_i(sw_i), .esp32_tx_i(etx_i),
                  .scl_i(scl), .sda_i(sda), .scl_low(scl_low), .sda_low(sda_low), .esp32_en(esp32_en), .esp32_strap(esp32_strap), .shutdown(shutdown), .reconf(reconf),
                  .f_state(st), .f_ph(ph), .f_bits(bits), .f_en(en), .f_wr(c_wr), .f_rd(c_rd), .f_sto(c_sto),
                  .f_shift(sh), .f_is_tick(is_tick), .f_tip(tip), .f_scl_s(scl_s), .f_sda_s(sda_s), .f_rxr(rxr), .f_txr(txr));

    // ---------------- register bus ----------------
    always @(posedge clk) if (pv && !rst) begin
        if (rb_ack) assert ($past(rb_valid) && !$past(rb_ack));
        if ($past(rb_valid) && !$past(rb_ack) && !$past(rst)) assert (rb_ack);
        if (rb_ack && !we_q && addr_q[15:12] == 4'h8 && addr_q[4:2] == 3'd0) assert (rb_rdata == 32'h47504931);
        if (rb_ack && !we_q && addr_q[15:12] == 4'h6 && addr_q[4:2] == 3'd7) assert (rb_rdata == 32'h49324331);
    end
    // the ESP32 TX level reaches gpio1 0x0C bit 1 through exactly two flops
    reg e1, e2;
    always @(posedge clk) begin e1 <= etx_i; e2 <= e1; end
    // ESP32 EN: held (0) through reset; changes only on a write to gpio1 0x0C, and reads back
    always @(posedge clk) if (pv) begin
        if ($past(rst)) assert (!esp32_en && !esp32_strap);
        if (!rst && !$past(rst)) begin
            if ($past(rb_valid && !rb_ack && rb_we && rb_addr[15:12] == 4'h8 && rb_addr[4:2] == 3'd3 && rb_wstrb[0]))
                assert (esp32_en == $past(rb_wdata[0]) && esp32_strap == $past(rb_wdata[2]));
            else
                assert (esp32_en == $past(esp32_en) && esp32_strap == $past(esp32_strap));
            if (rb_ack && !we_q && addr_q[15:12] == 4'h8 && addr_q[4:2] == 3'd3) assert (rb_rdata[31:0] == {29'b0, $past(esp32_strap), $past(e2), $past(esp32_en)});
        end
    end
    // POWER / RECONF: clear through reset; set only by the full-word magic write to their own register;
    // once set, held until reset (the board is going away); read back
    always @(posedge clk) if (pv) begin
        if ($past(rst)) assert (!shutdown && !reconf);
        if (!rst && !$past(rst)) begin
            assert (shutdown == ($past(shutdown) || $past(rb_valid && !rb_ack && rb_we && rb_addr[15:12] == 4'h8
                    && rb_addr[4:2] == 3'd4 && rb_wstrb == 4'hF && rb_wdata == 32'h504F4646)));
            assert (reconf == ($past(reconf) || $past(rb_valid && !rb_ack && rb_we && rb_addr[15:12] == 4'h8
                    && rb_addr[4:2] == 3'd5 && rb_wstrb == 4'hF && rb_wdata == 32'h52454346)));
            if (rb_ack && !we_q && addr_q[15:12] == 4'h8 && addr_q[4:2] == 3'd4) assert (rb_rdata == {31'b0, $past(shutdown)});
            if (rb_ack && !we_q && addr_q[15:12] == 4'h8 && addr_q[4:2] == 3'd5) assert (rb_rdata == {31'b0, $past(reconf)});
        end
    end
    // the pins reach the registers through exactly two flops, PWR inverted
    reg [6:0] b1, b2; reg [3:0] s1, s2;;
    always @(posedge clk) begin b1 <= btn_i; b2 <= b1; s1 <= sw_i; s2 <= s1; end
    always @(posedge clk) if (pv && !rst && $past(pv) && $past(!rst)) begin
        if (rb_ack && !we_q && addr_q[15:12] == 4'h8 && addr_q[4:2] == 3'd1) assert (rb_rdata == {25'b0, $past(b2[6:1]), ~$past(b2[0])});
        if (rb_ack && !we_q && addr_q[15:12] == 4'h8 && addr_q[4:2] == 3'd2) assert (rb_rdata == {28'b0, $past(s2)});
    end

    // ---------------- engine invariants, for induction ----------------
    wire take  = rb_valid && !rb_ack && rb_addr[15:12] == 4'h6 && rb_we && rb_wstrb[0];
    wire wr_cr = take && rb_addr[4:2] == 3'd4;
    always @(*) if (pv && !rst) assume (!(wr_cr && rb_wdata[5] && rb_wdata[4]));   // RD with WR
    reg [7:0] s_txr = 0, cmd_tx = 0, rd_sh = 0;
    always @(posedge clk) begin
        if (take && rb_addr[4:2] == 3'd3) s_txr <= rb_wdata[7:0];
        if (wr_cr && en && !tip && rb_wdata[7:4] != 0) cmd_tx <= s_txr;
        if (st == 3'd2 && ph == 3'd4 && is_tick) rd_sh <= {rd_sh[6:0], sda_s};
    end
    wire [3:0] done_bits = 4'd8 - bits;
    always @(*) if (pv) begin
        if (!rst) assert (s_txr == txr);
        assert (st <= 3'd4);
        assert (ph <= 3'd4);
        assert (bits <= 4'd8);
        assert ((st == 3'd0) == !tip);
        if (st == 3'd2) assert (bits != 0);
        if (st == 3'd3) assert (bits == 0);
        if (st == 3'd1) assert (bits == 4'd8 && sh == cmd_tx);
        if (tip) assert (!(c_wr && c_rd));
        if (st == 3'd2 || st == 3'd3) assert (c_wr || c_rd);
        if (st == 3'd0) assert (ph == 3'd0);
    end
    // what each phase has done to the lines
    always @(*) if (pv && !rst && en) begin
        if (st == 3'd0 || (st == 3'd1 && ph == 3'd0)) assert (!sda_low || scl_low);    // between commands
        if (st == 3'd2 || st == 3'd3 || st == 3'd4) begin
            if (ph == 3'd1 || ph == 3'd2) assert (scl_low);
            if (ph == 3'd3 || ph == 3'd4) assert (!scl_low);
        end
        if (st == 3'd4 && (ph == 3'd2 || ph == 3'd3 || ph == 3'd4)) assert (sda_low);
        if (st == 3'd1) begin
            if (ph >= 3'd1 && ph <= 3'd3) assert (!sda_low);
            if (ph >= 3'd2) assert (!scl_low);
            if (ph == 3'd4) assert (sda_low);
        end
    end
    // released when disabled or reset
    always @(posedge clk) if (pv && $past(pv)) begin
        if ($past(rst) || !$past(en)) assert (!scl_low && !sda_low && st == 0 && !tip);
    end
    // SDA moves while SCL is high only as a START or STOP step.  A slave moves it only with SCL low.
    reg scl_q = 1, sda_q = 1, sl_q = 0, en_q = 0; reg [2:0] st_qq = 0, ph_qq = 0;
    always @(posedge clk) begin scl_q <= scl; sda_q <= sda; sl_q <= slave_sda_low; en_q <= en; st_qq <= st; ph_qq <= ph; end
    always @(*) if (pv && !rst && scl && scl_q) assume (slave_sda_low == sl_q);
    wire sda_edge_high = scl && scl_q && (sda != sda_q);
    always @(*) if (pv && !rst && en && en_q && sda_edge_high) begin
        assert ((st == 3'd1 && ph == 3'd4) || (st_qq == 3'd4 && ph_qq == 3'd4));
    end

    // ---------------- data on the wire ----------------
    wire [3:0] sh_top = 4'd8 - bits;
    always @(*) if (pv && !rst && en && (st == 3'd2)) begin
        if (c_wr) begin
            assert (({8'b0, sh} >> sh_top) == ({8'b0, cmd_tx} & ((16'd1 << bits) - 16'd1)));
            if (ph >= 3'd2) assert (sda_low == !sh[7]);
        end
        if (c_rd) begin
            if (ph >= 3'd2) assert (!sda_low);
            assert ((sh & ((8'd1 << done_bits) - 8'd1)) == (rd_sh & ((8'd1 << done_bits) - 8'd1)));
        end
    end
    always @(*) if (pv && !rst && en && st == 3'd3 && c_rd) assert (rxr == rd_sh);

    // ---------------- termination ----------------
    wire [7:0] after = c_sto ? 8'd5 : 8'd0;
    wire [7:0] left  = 8'd5 - {5'b0, ph};
    reg  [7:0] rank;
    always @(*) case (st)
        3'd1:    rank = left + ((c_rd || c_wr) ? 8'd45 : 8'd0) + after;
        3'd2:    rank = left + ({4'b0, bits} - 8'd1) * 8'd5 + 8'd5 + after;
        3'd3:    rank = left + after;
        3'd4:    rank = left;
        default: rank = 8'd0;
    endcase
    reg [7:0] rank_q = 0; reg stepped = 0;
    always @(posedge clk) begin
        rank_q  <= rank;
        stepped <= tip && en && is_tick && !(ph == 3'd3 && !scl_s) && !rst;
    end
    always @(*) if (pv) assert (rank <= 8'd55);
    always @(posedge clk) if (pv && !rst && $past(pv) && !$past(rst)) begin
        if (stepped) assert (rank < rank_q);
        if ($past(st) != 0 && st != 0) assert (rank <= rank_q);
    end

    // clock stretching: the wait phase is left only once SCL is seen high
    always @(posedge clk) if (pv && !rst && en && $past(pv) && !$past(rst) && $past(en)) begin
        if (st != 0 && ph == 3'd4 && ph_qq == 3'd3) assert ($past(scl_s));
        if (ph_qq == 3'd3 && !$past(scl_s) && tip) assert (ph == 3'd3);
    end
    always @(posedge clk) if (pv && !rst) cover (st == 3'd2 && ph == 3'd3 && !scl_s && tip && slave_scl_low);

    // ---------------- reachability ----------------
    always @(posedge clk) if (pv && !rst) begin
        cover (st == 3'd1 && ph == 3'd4);              // a START
        cover (st == 3'd3 && ph == 3'd4 && c_wr);      // a write byte's ack
        cover (st == 3'd3 && ph == 3'd4 && c_rd);      // a read byte's ack
        cover (st == 3'd4 && ph == 3'd4);              // a STOP
        cover (st == 3'd3 && c_rd && rxr == 8'hA5);    // a byte read
    end
endmodule
