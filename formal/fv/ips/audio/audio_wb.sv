// audio_wb: the checker for src/Audio.v, bound into the DUT (no RTL changes).
//   Properties on the ports, against the register model generated from audio.regs, a FIFO model
//   (a symbolic slot), and a sample clock model.  Two internal interfaces are named as the
//   boundaries of sub-functions: the S/PDIF transmitter instance's sample inputs (pcm_l, pcm_r:
//   the samples the player hands on; formal/fv/ips/spdif proves the transmitter) and the
//   sigma-delta DAC's input word (u_l, u_r).
//   bus:     the regbus VIP (one ack per request, one cycle after it), the register model
//   STATUS:  [8:0] level = accepted pushes - pops, [16] drop (a push to a full FIFO), [17] underrun
//            (a sample time with CTRL[0] set and nothing queued), both cleared by a write to STATUS
//   FIFO:    a write to a full FIFO is dropped; every accepted sample reaches the player unchanged,
//            in order, nothing lost or repeated; with CTRL[0] clear the player hands on silence
//   clock:   a sample time every RATE + 1 clocks (a new RATE takes effect at the next one)
//   DAC:     the running error sum(input) - sum(code * 4096) of each channel stays in 0..4095
//            (so the mean code is the mean input); clipped inputs play code F; muted (volume 0),
//            both pins sit at code 8
//   S/PDIF:  audio_v is low after reset and only ever drives the PINS bits
// The INVARIANTS section names further internals for k-induction only.
`default_nettype none
module audio_wb (
    input wire        clk, rst,
    input wire        rb_valid, rb_we, input wire [11:0] rb_addr, input wire [31:0] rb_wdata,
    input wire [3:0]  rb_wstrb, input wire rb_ack, input wire [31:0] rb_rdata,
    input wire [3:0]  audio_l, audio_r, audio_v,
    // sub-function interfaces
    input wire [15:0] pcm_l, pcm_r, u_l, u_r,
    // internals (induction only)
    input wire [8191:0] memv,
    input wire [7:0]  wp, rp, input wire [8:0] level, input wire pop,
    input wire [31:0] q, cur, input wire [11:0] acc_l, acc_r, input wire [15:0] rate_cnt,
    input wire        drop, underrun, input wire [3:0] volume, spdif_pins, spdif_sfreq,
    input wire [1:0]  ctrl, input wire [15:0] rate, tone
);
    // ---------------- the bus and the register model ----------------
    wire bw, br; wire [11:0] bw_a, br_a; wire [31:0] bw_d, br_d; wire [3:0] bw_s;
    regbus_vip #(.DUT_IS_DEST(1), .AW(12)) bus (.clk(clk), .rst(rst), .valid(rb_valid), .we(rb_we),
        .addr(rb_addr), .wdata(rb_wdata), .wstrb(rb_wstrb), .ack(rb_ack), .rdata(rb_rdata),
        .wr(bw), .wr_addr(bw_a), .wr_data(bw_d), .wr_strb(bw_s), .rd(br), .rd_addr(br_a), .rd_data(br_d));
    wire [1:0] s_CTRL; wire [3:0] s_VOLUME, s_PINS, s_SFREQ; wire [15:0] s_RATE, s_TONE;
    audio_regs regs (.clk(clk), .rst(rst), .wr(bw), .wr_addr(bw_a[5:0]), .wr_data(bw_d), .wr_strb(bw_s),
        .rd(br), .rd_addr(br_a[5:0]), .rd_data(br_d), .s_CTRL(s_CTRL), .s_VOLUME(s_VOLUME),
        .s_RATE(s_RATE), .s_TONE(s_TONE), .s_PINS(s_PINS), .s_SFREQ(s_SFREQ));
    wire take = rb_valid && !rb_ack;            // the DUT acts on a request at its take

    // ---------------- sample clock ----------------
    localparam [15:0] RATE_RESET = 16'd2;          // as audio_env sets it
    reg [15:0] sc = RATE_RESET;
    always @(posedge clk) sc <= rst ? RATE_RESET : (sc == 16'd0) ? s_RATE : sc - 16'd1;
    wire stick = (sc == 16'd0);

    // ---------------- FIFO model ----------------
    (* anyconst *) reg [7:0] idx;
    reg [7:0] m_wp = 8'd0, m_rp = 8'd0; reg [8:0] m_lv = 9'd0; reg m_drop = 1'b0, m_und = 1'b0;
    wire push_rq = bw && bw_a[5:2] == 4'd5 && bw_s == 4'hF;
    wire push = push_rq && !m_lv[8];
    wire m_pop = stick && s_CTRL[0] && m_lv != 9'd0;
    reg [31:0] val; reg held = 1'b0;
    reg [1:0] dl = 2'b00; reg [31:0] dv;        // the slot's sample, on its way to the player
    reg [8:0] lv_t;                             // the level as of a STATUS read's take
    always @(posedge clk) begin
        if (push) m_wp <= m_wp + 8'd1;
        if (m_pop) m_rp <= m_rp + 8'd1;
        if (push && !m_pop) m_lv <= m_lv + 9'd1;
        if (!push && m_pop) m_lv <= m_lv - 9'd1;
        if (bw && bw_a[5:2] == 4'd6) m_drop <= 1'b0;
        if (push_rq && m_lv[8]) m_drop <= 1'b1;
        if (bw && bw_a[5:2] == 4'd6) m_und <= 1'b0;
        if (stick && s_CTRL[0] && m_lv == 9'd0) m_und <= 1'b1;   // a sample time with nothing to play
        if (push && m_wp == idx) begin val <= bw_d; held <= 1'b1; end
        else if (m_pop && m_rp == idx) held <= 1'b0;
        dl <= {dl[0], m_pop && m_rp == idx};
        if (m_pop && m_rp == idx) dv <= val;
        if (take) lv_t <= m_lv;
        if (rst) begin m_wp <= 8'd0; m_rp <= 8'd0; m_lv <= 9'd0; m_drop <= 1'b0; m_und <= 1'b0; held <= 1'b0; dl <= 2'b00; end
    end
    // a pop lands in the player 2 clocks later; it hands on the slot's sample while the slot's
    // pop is the last to have landed
    reg [1:0] dl_any = 2'b00; reg isx = 1'b0; reg m_drop_t, m_und_t;
    always @(posedge clk) begin
        dl_any <= rst ? 2'b00 : {dl_any[0], m_pop};
        if (dl_any[1]) isx <= dl[1];
        if (rst) isx <= 1'b0;
        if (take) begin m_drop_t <= m_drop; m_und_t <= m_und; end
    end
    wire now = dl_any[1] ? dl[1] : isx;
    always @(*) if (!rst) begin
        if (br && br_a[5:2] == 4'd6) assert (br_d == {14'd0, m_und_t, m_drop_t, 7'd0, lv_t});
        if (!s_CTRL[0]) assert (pcm_l == 16'd0 && pcm_r == 16'd0);
        else if (now) assert ({pcm_r, pcm_l} == dv);
    end

    // ---------------- DAC ----------------
    // e: the running error  sum(input) - sum(code * 4096)  of each channel; it must stay in
    // 0..4095, so the mean code is the mean input.  A clipped input (top nibble F) plays code F
    // and keeps only its low 12 bits in the error.
    reg [15:0] ul_q = 16'h8000, ur_q = 16'h8000; reg [1:0] mute = 2'b00; reg up = 1'b0;
    reg signed [17:0] el = 18'sd0, er = 18'sd0;
    wire signed [17:0] el_n = (ul_q[15:12] == 4'hF) ? $signed({6'd0, el[11:0]} + {6'd0, ul_q[11:0]}) & 18'sh00FFF
                                                    : el + $signed({2'b0, ul_q}) - $signed({2'b0, audio_l, 12'b0});
    wire signed [17:0] er_n = (ur_q[15:12] == 4'hF) ? $signed({6'd0, er[11:0]} + {6'd0, ur_q[11:0]}) & 18'sh00FFF
                                                    : er + $signed({2'b0, ur_q}) - $signed({2'b0, audio_r, 12'b0});
    always @(posedge clk) begin
        ul_q <= u_l; ur_q <= u_r; up <= !rst;
        mute <= rst ? 2'b00 : {mute[0], s_VOLUME == 4'd0};
        if (up) begin el <= el_n; er <= er_n; end
        if (rst) begin el <= 18'sd0; er <= 18'sd0; end
    end
    always @(*) if (!rst && up) begin
        assert (el_n >= 18'sd0 && el_n < 18'sd4096 && er_n >= 18'sd0 && er_n < 18'sd4096);
        if (ul_q[15:12] == 4'hF) assert (audio_l == 4'hF);
        if (ur_q[15:12] == 4'hF) assert (audio_r == 4'hF);
        if (mute == 2'b11) assert (audio_l == 4'h8 && audio_r == 4'h8);   // muted: silence on the pins
    end

    // ---------------- S/PDIF pins ----------------
    reg [3:0] pins_q = 4'h0;
    always @(posedge clk) pins_q <= rst ? 4'h0 : s_PINS;
    always @(*) if (!rst) assert ((audio_v & ~pins_q) == 4'h0);

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
    wire [31:0] slot = memv[32 * idx +: 32];
    wire [7:0]  d8   = idx - m_rp;
    reg  [7:0]  rp_q;
    always @(posedge clk) rp_q <= rp;
    always @(*) if (!rst) begin
        assert (ctrl == s_CTRL && volume == s_VOLUME && rate == s_RATE && tone == s_TONE && spdif_pins == s_PINS && spdif_sfreq == s_SFREQ);
        assert (rate_cnt == sc && drop == m_drop && underrun == m_und);
        if (up) assert (el_n == {6'd0, acc_l} && er_n == {6'd0, acc_r});
        if (mute[0]) assert (u_l == 16'h8000 && u_r == 16'h8000);
        assert (wp == m_wp && rp == m_rp && level == m_lv && m_lv <= 9'd256 && m_wp == m_rp + m_lv[7:0]);
        assert (held == ({1'b0, d8} < m_lv));
        if (held) assert (slot == val);
        assert (pop == dl_any[0] && (dl[0] == (pop && rp_q == idx)));
        if (dl[0]) assert (q == dv && rp_q == idx);
        if (now) assert (cur == dv && m_rp == idx + 8'd1 + {7'd0, dl_any[0]});   // no later pop has landed
        if (dl[0]) assert (m_rp == idx + 8'd1);
        if (dl[1]) assert (dl_any[1]);
        if (dl[0]) assert (dl_any[0]);
    end
    always @(*) if (!rst) cover (dl[1] && dv == 32'h1234ABCD && s_CTRL[0]);
endmodule

bind audio audio_wb wb (
    .clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
    .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata),
    .audio_l(audio_l), .audio_r(audio_r), .audio_v(audio_v),
    .pcm_l(pcm_l), .pcm_r(pcm_r), .u_l(u_l), .u_r(u_r),
    .memv({mem[255], mem[254], mem[253], mem[252], mem[251], mem[250], mem[249], mem[248], mem[247], mem[246], mem[245], mem[244], mem[243], mem[242], mem[241], mem[240], mem[239], mem[238], mem[237], mem[236], mem[235], mem[234], mem[233], mem[232], mem[231], mem[230], mem[229], mem[228], mem[227], mem[226], mem[225], mem[224], mem[223], mem[222], mem[221], mem[220], mem[219], mem[218], mem[217], mem[216], mem[215], mem[214], mem[213], mem[212], mem[211], mem[210], mem[209], mem[208], mem[207], mem[206], mem[205], mem[204], mem[203], mem[202], mem[201], mem[200], mem[199], mem[198], mem[197], mem[196], mem[195], mem[194], mem[193], mem[192], mem[191], mem[190], mem[189], mem[188], mem[187], mem[186], mem[185], mem[184], mem[183], mem[182], mem[181], mem[180], mem[179], mem[178], mem[177], mem[176], mem[175], mem[174], mem[173], mem[172], mem[171], mem[170], mem[169], mem[168], mem[167], mem[166], mem[165], mem[164], mem[163], mem[162], mem[161], mem[160], mem[159], mem[158], mem[157], mem[156], mem[155], mem[154], mem[153], mem[152], mem[151], mem[150], mem[149], mem[148], mem[147], mem[146], mem[145], mem[144], mem[143], mem[142], mem[141], mem[140], mem[139], mem[138], mem[137], mem[136], mem[135], mem[134], mem[133], mem[132], mem[131], mem[130], mem[129], mem[128], mem[127], mem[126], mem[125], mem[124], mem[123], mem[122], mem[121], mem[120], mem[119], mem[118], mem[117], mem[116], mem[115], mem[114], mem[113], mem[112], mem[111], mem[110], mem[109], mem[108], mem[107], mem[106], mem[105], mem[104], mem[103], mem[102], mem[101], mem[100], mem[99], mem[98], mem[97], mem[96], mem[95], mem[94], mem[93], mem[92], mem[91], mem[90], mem[89], mem[88], mem[87], mem[86], mem[85], mem[84], mem[83], mem[82], mem[81], mem[80], mem[79], mem[78], mem[77], mem[76], mem[75], mem[74], mem[73], mem[72], mem[71], mem[70], mem[69], mem[68], mem[67], mem[66], mem[65], mem[64], mem[63], mem[62], mem[61], mem[60], mem[59], mem[58], mem[57], mem[56], mem[55], mem[54], mem[53], mem[52], mem[51], mem[50], mem[49], mem[48], mem[47], mem[46], mem[45], mem[44], mem[43], mem[42], mem[41], mem[40], mem[39], mem[38], mem[37], mem[36], mem[35], mem[34], mem[33], mem[32], mem[31], mem[30], mem[29], mem[28], mem[27], mem[26], mem[25], mem[24], mem[23], mem[22], mem[21], mem[20], mem[19], mem[18], mem[17], mem[16], mem[15], mem[14], mem[13], mem[12], mem[11], mem[10], mem[9], mem[8], mem[7], mem[6], mem[5], mem[4], mem[3], mem[2], mem[1], mem[0]}),
    .wp(wp), .rp(rp), .level(level), .pop(pop), .q(q), .cur(cur), .acc_l(acc_l), .acc_r(acc_r),
    .rate_cnt(rate_cnt), .drop(drop), .underrun(underrun), .volume(volume), .spdif_pins(spdif_pins),
    .spdif_sfreq(spdif_sfreq), .ctrl(ctrl), .rate(rate), .tone(tone));
