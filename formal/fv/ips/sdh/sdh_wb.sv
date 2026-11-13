// sdh_wb: the checker for src/Sd_Host.v, bound into the DUT (no RTL changes).
//   Properties are stated on the DUT's ports and its trace port, against the register model
//   generated from sdh.regs and the SD bus VIPs: the trace is checked against the bus (a command
//   goes out exactly for an accepted CMD write, with its word and ARG; WPROT refusals; the received
//   word and the CRC verdict of a read block), the pins against the trace (the CMD frame carries
//   the traced command) and against the card VIP.  The second port group names DUT internals; they
//   appear only in the INVARIANTS section, which strengthens k-induction and claims nothing.
// Checks (fvgen -D): (none) safety, CHK_FRAME command frames, CHK_RD a read block.
`default_nettype none
module sdh_wb (
    input wire        clk, rst,
    input wire        rb_valid, rb_we, input wire [11:0] rb_addr, input wire [31:0] rb_wdata,
    input wire [3:0]  rb_wstrb, input wire rb_ack, input wire [31:0] rb_rdata,
    input wire        spi_sclk, spi_mosi, spi_cs_n, spi_miso, esp32_en, esp32_strap,
    input wire        clk_o, cmd_o, cmd_oe, cmd_i,
    input wire [3:0]  dat_o, dat_oe, dat_i,
    input wire        tr_cmd_valid, input wire [12:0] tr_cmd, input wire [31:0] tr_cmd_arg,
    input wire        tr_cmd_reject, tr_cmd_done, tr_cmd_tmo, tr_cmd_crc,
    input wire        tr_buf_valid, tr_buf_rx, input wire [6:0] tr_buf_addr, input wire [31:0] tr_buf_data,
    input wire        tr_dat_done, tr_dat_crc, tr_dat_tmo, tr_dat_wrerr,
    // internals (induction only)
    input wire        mode, wide, wprot, clken, sclk, coe, cout, doe,
    input wire [11:0] div, ccnt,
    input wire [31:0] arg,
    input wire [23:0] dtmo,
    input wire [2:0]  cst, dst,
    input wire [7:0]  cn,
    input wire [39:0] csh,
    input wire [6:0]  crc7,
    input wire [9:0]  blksize, input wire [15:0] blkcnt, input wire [12:0] dcnt, input wire [23:0] dto,
    input wire [15:0] k0, k1, k2, k3, input wire [7:0] byt, input wire [31:0] dsh,
    input wire [6:0]  bptr, cptr, wa_m, input wire rx_ready, we_m, input wire [31:0] wd_m, mem0, q,
    input wire [3:0]  dat_q, input wire d_crc, d_tmo, d_done, wr_err
);
`ifdef CHK_FRAME
 `define SDH_SW
`endif
`ifdef CHK_RD
 `define SDH_SW
`endif
    `include "crc_ref.svh"
    function automatic is_wr (input [5:0] i);
        is_wr = (i == 6'd24) || (i == 6'd25) || (i == 6'd27) || (i == 6'd28) || (i == 6'd29)
             || (i == 6'd38) || (i == 6'd42) || (i == 6'd56);
    endfunction

    // ---------------- the bus and the register model ----------------
    wire bw, br; wire [11:0] bw_a, br_a; wire [31:0] bw_d, br_d; wire [3:0] bw_s;
    regbus_vip #(.DUT_IS_DEST(1), .AW(12)) bus (.clk(clk), .rst(rst), .valid(rb_valid), .we(rb_we),
        .addr(rb_addr), .wdata(rb_wdata), .wstrb(rb_wstrb), .ack(rb_ack), .rdata(rb_rdata),
        .wr(bw), .wr_addr(bw_a), .wr_data(bw_d), .wr_strb(bw_s), .rd(br), .rd_addr(br_a), .rd_data(br_d));
    wire [0:0] s_MODE, s_WIDE, s_WPROT, s_CLKEN; wire [11:0] s_DIV; wire [31:0] s_ARG; wire [23:0] s_DTMO;
    sdh_regs regs (.clk(clk), .rst(rst), .wr(bw), .wr_addr(bw_a), .wr_data(bw_d), .wr_strb(bw_s),
        .rd(br), .rd_addr(br_a), .rd_data(br_d), .s_MODE(s_MODE), .s_WIDE(s_WIDE), .s_WPROT(s_WPROT),
        .s_CLKEN(s_CLKEN), .s_DIV(s_DIV), .s_ARG(s_ARG), .s_DTMO(s_DTMO));
    wire native = s_MODE && !esp32_en && !esp32_strap;
    wire full_wr = bw && bw_s == 4'hF;

    // ---------------- pins (spec: Sd_Host.v header) ----------------
    reg [1:0] nat_h = 2'b00; reg [1:0] clk_h = 2'b00;
    always @(posedge clk) begin nat_h <= {nat_h[0], native}; clk_h <= {clk_h[0], clk_o}; end
    always @(*) if (!rst) begin
        if (!native) begin                       // SPI mode: exactly SPI0 plus the ESP32 strap
            assert (clk_o == spi_sclk && cmd_o == spi_mosi && cmd_oe);
            assert (dat_o[3] == spi_cs_n && dat_oe == {1'b1, 2'b00, esp32_strap && spi_cs_n});
            assert (spi_miso == dat_i[0]);
        end else begin
            assert (dat_oe == 4'h0 || dat_oe == (s_WIDE ? 4'hF : 4'h1));
            if (s_WPROT) assert (dat_oe == 4'h0);  // write-protected: DAT is never driven
            assert (spi_miso);
        end
        // the card clock: phases of at least 2 system clocks while the host owns it
        if (native && nat_h == 2'b11 && clk_o != clk_h[0]) assert (clk_h[0] == clk_h[1]);
    end

`ifdef SDH_SW
    // software contract (port-level): CMD is written only after a STATUS read showed the host idle
    // ([0] = 0), with no CMD write since -- the drivers poll STATUS
    reg rdy = 1'b0;
    wire cmd_wr = full_wr && bw_a == 12'h00C;
    always @(posedge clk) begin
        if (br && br_a == 12'h010) rdy <= !br_d[0];
        if (cmd_wr) rdy <= 1'b0;
        if (rst) rdy <= 1'b0;
    end
    always @(*) if (!rst && cmd_wr) assume (rdy);
    wire cmd_acc = cmd_wr && native && !(s_WPROT && (bw_d[12] || is_wr (bw_d[5:0])));
`endif

    // ---------------- the command trace ----------------
    // a command goes out only for a full-word CMD write in native mode, carrying that word and ARG,
    // and never a write command under WPROT; with the polling contract, every such write is one
    wire cmd_w  = full_wr && bw_a == 12'h00C;
    wire cmd_wp = bw_d[12] || is_wr (bw_d[5:0]);
    always @(*) if (!rst) begin
        if (tr_cmd_valid) assert (cmd_w && native && !(s_WPROT && cmd_wp) && tr_cmd == bw_d[12:0] && tr_cmd_arg == s_ARG);
        if (tr_cmd_reject) assert (cmd_w && native && s_WPROT && cmd_wp);
`ifdef SDH_SW
        assert (tr_cmd_valid == cmd_acc);
        assert (tr_cmd_reject == (cmd_w && native && s_WPROT && cmd_wp));
`endif
    end

    // ---------------- command frames ----------------
`ifdef CHK_FRAME
    wire [5:0] mn; wire [47:0] msh; wire mdone; wire [5:0] midx; wire [31:0] marg; wire msq;
    sd_cmd_mon mon (.clk(clk), .rst(rst), .en(native), .sck(clk_o), .cmd(cmd_o), .cmd_oe(cmd_oe),
        .n(mn), .sh(msh), .done(mdone), .idx(midx), .arg(marg), .sck_q(msq));
    // a CMD write while idle starts exactly one frame carrying its index and ARG, unless WPROT
    // refuses it; nothing else puts a frame on the line
    reg pend = 1'b0; reg [47:0] exp_f;
    wire accept = tr_cmd_valid;                      // the wire must carry what the trace says
    wire [39:0] head = {2'b01, tr_cmd[5:0], tr_cmd_arg};
    always @(posedge clk) begin
        if (accept) begin pend <= 1'b1; exp_f <= {head, crc7_ld40 (head), 1'b1}; end
        if (mdone) pend <= 1'b0;
        if (rst) pend <= 1'b0;
    end
    always @(*) if (!rst) begin
        if (mdone) assert (pend && midx == exp_f[45:40] && marg == exp_f[39:8]);
        if (mn != 6'd0) assert (pend);
    end
    // software: no register traffic while a command is in flight, the ESP32 left in reset
    always @(*) if (!rst && pend) assume (!rb_valid && !esp32_en && !esp32_strap);
`else
    wire msq = clk_h[0];
`endif

    // ---------------- a read block ----------------
`ifdef CHK_RD
    // one read transfer of a 4-byte block from a card that sends the data W with the CRCs C and the
    // end bits E it likes; the host must buffer W and flag a CRC error exactly when a line's CRC is
    // not the long-division one or its end bit is 0.
    (* anyconst *) reg [31:0] W;
    (* anyconst *) reg [63:0] C;
    (* anyconst *) reg [3:0]  E;
    (* anyseq *)   reg [3:0]  fr;
    (* anyseq *)   reg        go_any;
    reg armed = 1'b0, arm_q = 1'b0, rseen = 1'b0, got = 1'b0;
    reg [9:0] bs = 10'd512; reg [15:0] bc = 16'd0; reg [23:0] nf = 24'd0;
    wire [3:0] card_dat; wire [12:0] p; wire card_sq, jf;
    wire [12:0] D = s_WIDE ? 13'd8 : 13'd32;
    wire [12:0] T = D + 13'd18;
    wire [23:0] nf1 = nf + {23'd0, jf && !arm_q};       // falls since the arming, this one included
    sd_rd_card #(.NB(4)) card (.clk(clk), .rst(rst), .en(native), .sck(clk_o), .wide(s_WIDE),
        .go(go_any && armed), .data(W), .crc(C), .endb(E), .free(fr),
        .dat(card_dat), .p(p), .sck_q(card_sq), .fell(jf));
    function automatic [7:0] lane (input [31:0] w, input integer l);   // a byte's bits on DAT l
        lane = {w[4+l], w[l], w[12+l], w[8+l], w[20+l], w[16+l], w[28+l], w[24+l]};
    endfunction
    wire [31:0] w1 = {W[7:0], W[15:8], W[23:16], W[31:24]};          // the 1-bit stream, first bit at 31
    wire bad = s_WIDE ? (C[15:0] != crc16_ld8 (lane (W, 0)) || C[31:16] != crc16_ld8 (lane (W, 1))
                      || C[47:32] != crc16_ld8 (lane (W, 2)) || C[63:48] != crc16_ld8 (lane (W, 3)) || E != 4'hF)
                      : (C[15:0] != crc16_ld32 (w1) || !E[0]);
    wire rd_cmd = cmd_wr && bw_d[11];
    wire arm = cmd_acc && bw_d[11];
    always @(posedge clk) begin
        arm_q <= arm;
        if (full_wr && bw_a == 12'h024) bs <= (bw_d[9:2] == 8'd0) ? 10'd4 : {bw_d[9:2], 2'b00};
        if (full_wr && bw_a == 12'h028) bc <= bw_d[15:0];
        if (arm) begin armed <= 1'b1; nf <= 24'd0; end
        else if (armed && jf && !arm_q && p == 13'd0) nf <= nf + 24'd1;
        if (br && br_a == 12'h010 && armed && br_d[8]) rseen <= 1'b1;
        if (br && br_a == 12'h030 && rseen) got <= 1'b1;
        if (rst) begin armed <= 1'b0; arm_q <= 1'b0; rseen <= 1'b0; got <= 1'b0; bs <= 10'd512; bc <= 16'd0; end
    end
    // software: one read transfer (4-byte block, one block, a nonzero timeout), nothing written while
    // it runs, the ESP32 in reset, STATUS polled for the block before the FIFO is read
    always @(*) if (!rst) begin
        if (rd_cmd) assume (!bw_d[12] && !armed && bs == 10'd4 && bc <= 16'd1 && s_DTMO != 24'd0);
        if (armed) assume (!(rb_valid && rb_we) && !esp32_en && !esp32_strap);
        if (armed && rb_valid && !rb_we && rb_addr == 12'h030) assume (rseen);
    end
    always @(*) assume (dat_i == card_dat);                     // the card owns DAT
    // the card answers within the data timeout
    always @(*) if (!rst && armed && p == 13'd0 && jf && nf1 == s_DTMO) assume (go_any);
    // properties
    always @(*) if (!rst && br && br_a == 12'h010 && armed) begin
        assert (!br_d[7]);                                       // no timeout
        if (br_d[8]) assert (p >= T && br_d[6] == bad && br_d[5] && !br_d[4]);
    end
    always @(*) if (!rst && br && br_a == 12'h030 && rseen && !got) assert (br_d == W);
    // the trace: the block's one word reaches buffer word 0 once the card has sent it, and the
    // transfer ends with the CRC verdict
    always @(*) if (!rst) begin
        if (tr_buf_valid) assert (armed && tr_buf_rx && tr_buf_addr == 7'd0 && tr_buf_data == W && p >= D + 13'd1);   // after the card's last data bit (bit 1 is the start bit)
        if (tr_dat_done) assert (armed && p >= T && tr_dat_crc == bad && !tr_dat_tmo && !tr_dat_wrerr);
    end
    // milestones (~125 steps to the last: DIV = 1 is 4 clocks per card clock, 26 card clocks)
    always @(*) if (!rst) begin
        cover (armed && p == 13'd1);                 // the card has started
        cover (armed && p == D + 13'd2);             // into the CRC
        cover (rseen);                               // STATUS showed the block buffered
        cover (got && !bad && s_WIDE);               // the first word read back
    end
`endif

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
    function automatic [6:0] crc7_pre (input [39:0] d, input [7:0] k);
        reg [6:0] c; reg fb; integer i;
        begin
            c = 7'd0;
            for (i = 0; i < 40; i = i + 1)
                if (i < k) begin fb = c[6] ^ d[39 - i]; c = {c[5:3], c[2] ^ fb, c[1:0], fb}; end
            crc7_pre = c;
        end
    endfunction
`ifdef CHK_RD
    function automatic [15:0] crc16_pre (input [47:0] d, input [12:0] k);   // LFSR over the first k bits
        reg [15:0] c; reg fb; integer i;
        begin
            c = 16'd0;
            for (i = 0; i < 48; i = i + 1)
                if (i < k) begin fb = c[15] ^ d[47 - i]; c = {c[14:12], c[11] ^ fb, c[10:5], c[4] ^ fb, c[3:0], fb}; end
            crc16_pre = c;
        end
    endfunction
    wire [31:0] l0  = s_WIDE ? {lane (W, 0), 24'd0} : w1;           // DAT0's data bits, first at 31
    wire [5:0]  nbv = s_WIDE ? {dcnt[3:0], 2'b00} : dcnt[5:0];      // data bits taken so far
    wire [3:0]  rbv = s_WIDE ? (dcnt[0] ? 4'd4 : 4'd0) : {1'b0, dcnt[2:0]};   // of them, in the byte being built
    wire [6:0]  jbv = {1'b0, nbv[5:3], 3'b000};                      // of them, in whole bytes
`endif
    wire [11:0] div_e = (div == 12'd0) ? 12'd1 : div;
    always @(*) if (!rst) begin
        assert (mode == s_MODE && wide == s_WIDE && wprot == s_WPROT && clken == s_CLKEN);
        assert (div == s_DIV && arg == s_ARG && dtmo == s_DTMO);
        assert (cst <= 3'd4 && dst <= 3'd7);
        if (cst == 3'd0 || cst == 3'd3) assert (!coe);
        if (doe) assert (dst == 3'd5);
        assert (ccnt <= 12'hFFF);
        if (native && nat_h[0] && msq != sclk) assert (ccnt != 12'd0);   // the clock toggled one cycle ago: it holds
        if (native) assert (clk_o == sclk);
`ifdef SDH_SW
        if (rdy) assert (cst == 3'd0);
`endif
`ifdef CHK_FRAME
        if (rdy) assert (!pend);
        if (!pend) begin
            assert (cst != 3'd1 && mn == 6'd0);
            if (coe) assert ((cst == 3'd2 || cst == 3'd4) && cout && sclk && msq);
        end else begin
            assert (native && exp_f[47:46] == 2'b01 && exp_f[0] && exp_f[7:1] == crc7_ld40 (exp_f[47:8]));
            if (mn != 6'd0) assert ((msh & ((48'h1 << mn) - 48'h1)) == (exp_f >> (6'd48 - mn)));
            if (cst == 3'd1) begin
                assert (cn <= 8'd47 && coe == (cn != 8'd0));
                if (cn != 8'd0) assert (cout == exp_f[8'd48 - cn]);
                assert (mn == ((cn == 8'd0) ? 6'd0 : (sclk && msq) ? cn[5:0] : cn[5:0] - 6'd1));   // the monitor sees a rise one cycle late
                if (cn <= 8'd40) begin
                    assert (csh == (exp_f[47:8] << cn));
                    assert (crc7 == crc7_pre (exp_f[47:8], cn));
                end else
                    assert (crc7 == (exp_f[7:1] << (cn - 8'd40)));
            end else begin
                assert (cst == 3'd2 || cst == 3'd4);
                assert (coe && cout && mn == 6'd47 && !(sclk && msq));   // the end bit's rise is being seen (done) or still to come
                if (cst == 3'd2) assert (cn == 8'd0);
            end
        end
`endif
`ifdef CHK_RD
        assert (card_sq == clk_h[0] && bs == blksize && (armed || bc == blkcnt) && (!got || rseen));
        if (!armed) assert (dst == 3'd0 && !rx_ready && p == 13'd0 && !rseen && dat_q[0] && !we_m);
        else begin
            assert (native && s_DTMO != 24'd0 && blksize == 10'd4 && blkcnt <= 16'd1);
            if (dst != 3'd3) assert (!we_m);
            assert (!d_tmo && !wr_err && (dst == 3'd0 || dst == 3'd1 || dst == 3'd2 || dst == 3'd3));
            if (sclk && p != 13'd0 && p <= T) assert (s_WIDE ? dat_q == card_dat : dat_q[0] == card_dat[0]);
            if (p == 13'd0) assert (dat_q[0]);
            if (dst != 3'd0) assert (!rx_ready && !d_crc && !d_done && cptr == 7'd0 && !rseen && bptr == (dst == 3'd3));
            if (p == 13'd0) assert (dst == 3'd1 && nf < s_DTMO && nf1 <= s_DTMO && dto == s_DTMO - nf1);   // the card is made to start by fall DTMO
            else if (dst == 3'd1) assert (p == 13'd1 && !jf);
            else if (dst == 3'd2) begin
                assert (dcnt < D && p == dcnt + (jf ? 13'd1 : 13'd2));
                assert (k0 == crc16_pre ({l0, 16'd0}, dcnt));
                if (s_WIDE) assert (k1 == crc16_pre ({lane (W, 1), 40'd0}, dcnt) && k2 == crc16_pre ({lane (W, 2), 40'd0}, dcnt)
                                 && k3 == crc16_pre ({lane (W, 3), 40'd0}, dcnt));
                assert (((byt ^ (w1 >> (6'd32 - nbv))) & ((8'd1 << rbv) - 8'd1)) == 8'd0);
                assert ((({32'd0, dsh} >> (7'd32 - jbv)) ^ ({32'd0, W} & ((64'd1 << jbv) - 64'd1))) == 64'd0);
            end else if (dst == 3'd3) begin
                assert (dcnt <= 13'd16 && p == D + dcnt + (jf ? 13'd1 : 13'd2) && dsh == W);
                assert (k0 == crc16_pre (s_WIDE ? {lane (W, 0), C[15:0], 24'd0} : {w1, C[15:0]}, D + dcnt));
                if (s_WIDE) assert (k1 == crc16_pre ({lane (W, 1), C[31:16], 24'd0}, 13'd8 + dcnt)
                                 && k2 == crc16_pre ({lane (W, 2), C[47:32], 24'd0}, 13'd8 + dcnt)
                                 && k3 == crc16_pre ({lane (W, 3), C[63:48], 24'd0}, 13'd8 + dcnt));
                if (dcnt == 13'd0) assert ((!we_m || (wa_m == 7'd0 && wd_m == W)) && (we_m || mem0 == W));
                else assert (!we_m && mem0 == W && q == W);
            end else begin
                assert (p == T + 13'd1 || (p == T && jf));
                assert (d_done && d_crc == bad && blkcnt == 16'd0 && cptr == 7'd0 && !we_m && mem0 == W);
                assert (rx_ready == !(got || (br && br_a == 12'h030)) && (got || q == W) && (!got || rseen));   // a FIFO read's take drains it
            end
        end
`endif
    end
`ifdef CHK_FRAME
    always @(*) cover (mdone);
`endif
endmodule

bind sd_host sdh_wb wb (
    .clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
    .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n), .spi_miso(spi_miso),
    .esp32_en(esp32_en), .esp32_strap(esp32_strap),
    .clk_o(clk_o), .cmd_o(cmd_o), .cmd_oe(cmd_oe), .cmd_i(cmd_i),
    .dat_o(dat_o), .dat_oe(dat_oe), .dat_i(dat_i),
    .tr_cmd_valid(tr_cmd_valid), .tr_cmd(tr_cmd), .tr_cmd_arg(tr_cmd_arg), .tr_cmd_reject(tr_cmd_reject),
    .tr_cmd_done(tr_cmd_done), .tr_cmd_tmo(tr_cmd_tmo), .tr_cmd_crc(tr_cmd_crc), .tr_buf_valid(tr_buf_valid),
    .tr_buf_rx(tr_buf_rx), .tr_buf_addr(tr_buf_addr), .tr_buf_data(tr_buf_data), .tr_dat_done(tr_dat_done),
    .tr_dat_crc(tr_dat_crc), .tr_dat_tmo(tr_dat_tmo), .tr_dat_wrerr(tr_dat_wrerr),
    .mode(mode), .wide(wide), .wprot(wprot), .clken(clken), .sclk(sclk), .coe(coe), .cout(cout),
    .doe(doe), .div(div), .ccnt(ccnt), .arg(arg), .dtmo(dtmo), .cst(cst), .dst(dst), .cn(cn), .csh(csh), .crc7(crc7),
    .blksize(blksize), .blkcnt(blkcnt), .dcnt(dcnt), .dto(dto), .k0(k0), .k1(k1), .k2(k2), .k3(k3),
    .byt(byt), .dsh(dsh), .bptr(bptr), .cptr(cptr), .wa_m(wa_m), .rx_ready(rx_ready), .we_m(we_m),
    .wd_m(wd_m), .mem0(mem[0]), .q(q), .dat_q(dat_q), .d_crc(d_crc), .d_tmo(d_tmo), .d_done(d_done), .wr_err(wr_err));
