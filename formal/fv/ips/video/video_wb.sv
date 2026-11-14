// video_wb: the checker for src/Video_DVI.v (register-bus side), bound into the DUT (no RTL
// changes).  Properties on the ports and the trace port, against the register model generated
// from video.regs, one symbolic pixel RAM word and one symbolic palette entry:
//   bus:     the regbus VIP with this device's latencies (a write acked the cycle after its take,
//            a read 5 cycles after), the register model (ID, MODE, STATUS[31:1], FBSIZE, zeros)
//   RAM:     each byte lane of a word reads back the last write to it; a write lands (tr_fb_wr)
//            the cycle after its take with its word, data and lanes, and only then; reads past
//            the end of the RAM return 0
//   palette: an entry reads back its reset colour (0-15 the VGA colours, 16-255 RGB332 of the
//            index) until a write replaces it whole; tr_pal_wr exactly at a palette write's take
//   FRAME:   reads the number of frames the trace has counted (tr_frame)
//   assumed: the bridge's protocol (regbus_vip) and routing (only the two windows)
// The pixel side (scan-out, TMDS) is not specified here yet.
// The INVARIANTS section names internals for k-induction only.
`default_nettype none
module video_wb #(parameter integer FB_WORDS = 36) (
    input wire        clk, rst,
    input wire        rb_valid, rb_we, input wire [31:0] rb_addr, input wire [31:0] rb_wdata,
    input wire [3:0]  rb_wstrb, input wire rb_ack, input wire [31:0] rb_rdata,
    input wire        tr_fb_wr, input wire [15:0] tr_fb_word, input wire [31:0] tr_fb_data,
    input wire [3:0]  tr_fb_strb, input wire tr_pal_wr, input wire [7:0] tr_pal_idx,
    input wire [23:0] tr_pal_data, input wire tr_frame,
    // internals (induction only)
    input wire [32*FB_WORDS-1:0] memv, input wire [24*256-1:0] palv,
    input wire [2:0]  mode, input wire busy, input wire [1:0] rd_st, input wire rd_fb, rd_in, rd_pal,
    input wire [31:0] frame
);
    // ---------------- the bus and the register model ----------------
    wire bw, br; wire [31:0] bw_a, br_a, bw_d, br_d; wire [3:0] bw_s;
    regbus_vip #(.DUT_IS_DEST(1), .AW(32), .RD_LAT(5), .WR_LAT(1)) bus (.clk(clk), .rst(rst), .abandon(1'b0),
        .valid(rb_valid), .we(rb_we), .addr(rb_addr), .wdata(rb_wdata), .wstrb(rb_wstrb), .ack(rb_ack),
        .rdata(rb_rdata), .wr(bw), .wr_addr(bw_a), .wr_data(bw_d), .wr_strb(bw_s), .rd(br),
        .rd_addr(br_a), .rd_data(br_d), .tk(b_tk), .pend(b_pend), .we_q(b_we), .w(b_w), .a_q(b_a));
    wire b_tk, b_pend, b_we; wire [3:0] b_w; wire [31:0] b_a;
    wire [2:0] s_MODE;
    video_regs regs (.clk(clk), .rst(rst), .wr(bw), .wr_addr(bw_a), .wr_data(bw_d), .wr_strb(bw_s),
        .rd(br), .rd_addr(br_a), .rd_data(br_d), .s_MODE(s_MODE));
    // the bridge routes only the two windows here
    always @(*) if (!rst && rb_valid) assume (rb_addr[31:25] == 7'h60 && (rb_addr[24] || rb_addr[23:12] == 12'h010));

    // ---------------- pixel RAM: one symbolic word ----------------
    (* anyconst *) reg [15:0] sw;
    always @(*) assume (sw < FB_WORDS);
    function is_word (input [31:0] a, input [15:0] w); is_word = a[24] && a[23:18] == 6'd0 && a[17:2] == w; endfunction
    function backed (input [31:0] a); backed = a[24] && a[23:18] == 6'd0 && a[17:2] < FB_WORDS; endfunction
    reg [31:0] shadow; reg [3:0] known = 4'd0;
    integer b, c, e;
    always @(posedge clk) begin
        if (bw && is_word(bw_a, sw))
            for (b = 0; b < 4; b = b + 1)
                if (bw_s[b]) begin shadow[8*b +: 8] <= bw_d[8*b +: 8]; known[b] <= 1'b1; end
        if (rst) known <= 4'd0;
    end
    always @(*) if (!rst && br) begin
        if (is_word(br_a, sw))
            for (c = 0; c < 4; c = c + 1)
                if (known[c]) assert (br_d[8*c +: 8] == shadow[8*c +: 8]);
        if (br_a[24] && !backed(br_a)) assert (br_d == 32'd0);
    end
    // the trace: a write lands the cycle after its take
    reg f_wr = 1'b0; reg [15:0] f_w; reg [31:0] f_d; reg [3:0] f_s;
    always @(posedge clk) begin
        f_wr <= !rst && bw && backed(bw_a);  f_w <= bw_a[17:2];  f_d <= bw_d;  f_s <= bw_s;
    end
    always @(*) if (!rst) begin
        assert (tr_fb_wr == f_wr);
        if (tr_fb_wr) assert (tr_fb_word == f_w && tr_fb_data == f_d && tr_fb_strb == f_s);
    end

    // ---------------- palette: one symbolic entry, from its reset value ----------------
    (* anyconst *) reg [7:0] sp;
    function [23:0] pal_reset (input [7:0] k);
        case (k)
            0: pal_reset = 24'h000000;  1: pal_reset = 24'h0000AA;  2: pal_reset = 24'h00AA00;
            3: pal_reset = 24'h00AAAA;  4: pal_reset = 24'hAA0000;  5: pal_reset = 24'hAA00AA;
            6: pal_reset = 24'hAA5500;  7: pal_reset = 24'hAAAAAA;  8: pal_reset = 24'h555555;
            9: pal_reset = 24'h5555FF; 10: pal_reset = 24'h55FF55; 11: pal_reset = 24'h55FFFF;
           12: pal_reset = 24'hFF5555; 13: pal_reset = 24'hFF55FF; 14: pal_reset = 24'hFFFF55;
           15: pal_reset = 24'hFFFFFF;
           default: pal_reset = { k[7:5], k[7:5], k[7:6], k[4:2], k[4:2], k[4:3],
                                  k[1:0], k[1:0], k[1:0], k[1:0] };
        endcase
    endfunction
    function is_pal (input [31:0] a); is_pal = !a[24] && a[11:10] == 2'b01; endfunction
    reg [23:0] pshadow;
    always @(posedge clk) begin
        if (rst) pshadow <= pal_reset(sp);
        else if (bw && is_pal(bw_a) && bw_a[9:2] == sp) pshadow <= bw_d[23:0];
    end
    always @(*) if (!rst && br && is_pal(br_a) && br_a[9:2] == sp) assert (br_d[23:0] == pshadow);
    always @(*) if (!rst) begin
        assert (tr_pal_wr == (bw && is_pal(bw_a)));
        if (tr_pal_wr) assert (tr_pal_idx == bw_a[9:2] && tr_pal_data == bw_d[23:0]);
    end

    // ---------------- FRAME ----------------
    reg [31:0] m_frame = 32'd0, e_frame;
    always @(posedge clk) begin
        if (tr_frame) m_frame <= m_frame + 32'd1;
        if (rst) m_frame <= 32'd0;
        if (b_tk) e_frame <= m_frame;
    end
    always @(*) if (!rst && br && !br_a[24] && br_a[11:2] == 10'h003) assert (br_d == e_frame);

    // ---------------- reachability ----------------
    always @(*) if (!rst) begin
        cover (br && is_word(br_a, sw) && known == 4'hF);
        cover (br && is_pal(br_a) && br_a[9:2] == sp && pshadow != pal_reset(sp));
    end

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    wire [31:0] word = memv[32*sw +: 32];
    wire [23:0] pent = palv[24*sp +: 24];
    always @(*) if (!rst) begin
        for (e = 0; e < 4; e = e + 1)
            if (known[e]) begin
                if (tr_fb_wr && tr_fb_word == sw && tr_fb_strb[e]) assert (tr_fb_data[8*e +: 8] == shadow[8*e +: 8]);
                else assert (word[8*e +: 8] == shadow[8*e +: 8]);
            end
        assert (pent == pshadow);
        assert (mode == s_MODE && frame == m_frame);
        assert (busy == (b_pend && !b_we && !rb_ack));
        if (busy) assert (rd_st == b_w[1:0] - 2'd1 && b_w <= 4'd4 && rd_fb == b_a[24]
                          && rd_in == backed(b_a) && rd_pal == is_pal(b_a));
        if (b_pend && b_we) assert (b_w == 4'd1);
        if (b_pend && !b_we) assert (b_w <= 4'd5);
    end
`endif
endmodule

bind video_fb video_wb #(.FB_WORDS(FB_WORDS)) wb (
    .clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
    .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata),
    .tr_fb_wr(tr_fb_wr), .tr_fb_word(tr_fb_word), .tr_fb_data(tr_fb_data), .tr_fb_strb(tr_fb_strb),
    .tr_pal_wr(tr_pal_wr), .tr_pal_idx(tr_pal_idx), .tr_pal_data(tr_pal_data), .tr_frame(tr_frame),
    .memv({{fbg[4].fbl[3].mem[3], fbg[4].fbl[2].mem[3], fbg[4].fbl[1].mem[3], fbg[4].fbl[0].mem[3]}, {fbg[4].fbl[3].mem[2], fbg[4].fbl[2].mem[2], fbg[4].fbl[1].mem[2], fbg[4].fbl[0].mem[2]}, {fbg[4].fbl[3].mem[1], fbg[4].fbl[2].mem[1], fbg[4].fbl[1].mem[1], fbg[4].fbl[0].mem[1]}, {fbg[4].fbl[3].mem[0], fbg[4].fbl[2].mem[0], fbg[4].fbl[1].mem[0], fbg[4].fbl[0].mem[0]}, {fbg[3].fbl[3].mem[7], fbg[3].fbl[2].mem[7], fbg[3].fbl[1].mem[7], fbg[3].fbl[0].mem[7]}, {fbg[3].fbl[3].mem[6], fbg[3].fbl[2].mem[6], fbg[3].fbl[1].mem[6], fbg[3].fbl[0].mem[6]}, {fbg[3].fbl[3].mem[5], fbg[3].fbl[2].mem[5], fbg[3].fbl[1].mem[5], fbg[3].fbl[0].mem[5]}, {fbg[3].fbl[3].mem[4], fbg[3].fbl[2].mem[4], fbg[3].fbl[1].mem[4], fbg[3].fbl[0].mem[4]}, {fbg[3].fbl[3].mem[3], fbg[3].fbl[2].mem[3], fbg[3].fbl[1].mem[3], fbg[3].fbl[0].mem[3]}, {fbg[3].fbl[3].mem[2], fbg[3].fbl[2].mem[2], fbg[3].fbl[1].mem[2], fbg[3].fbl[0].mem[2]}, {fbg[3].fbl[3].mem[1], fbg[3].fbl[2].mem[1], fbg[3].fbl[1].mem[1], fbg[3].fbl[0].mem[1]}, {fbg[3].fbl[3].mem[0], fbg[3].fbl[2].mem[0], fbg[3].fbl[1].mem[0], fbg[3].fbl[0].mem[0]}, {fbg[2].fbl[3].mem[7], fbg[2].fbl[2].mem[7], fbg[2].fbl[1].mem[7], fbg[2].fbl[0].mem[7]}, {fbg[2].fbl[3].mem[6], fbg[2].fbl[2].mem[6], fbg[2].fbl[1].mem[6], fbg[2].fbl[0].mem[6]}, {fbg[2].fbl[3].mem[5], fbg[2].fbl[2].mem[5], fbg[2].fbl[1].mem[5], fbg[2].fbl[0].mem[5]}, {fbg[2].fbl[3].mem[4], fbg[2].fbl[2].mem[4], fbg[2].fbl[1].mem[4], fbg[2].fbl[0].mem[4]}, {fbg[2].fbl[3].mem[3], fbg[2].fbl[2].mem[3], fbg[2].fbl[1].mem[3], fbg[2].fbl[0].mem[3]}, {fbg[2].fbl[3].mem[2], fbg[2].fbl[2].mem[2], fbg[2].fbl[1].mem[2], fbg[2].fbl[0].mem[2]}, {fbg[2].fbl[3].mem[1], fbg[2].fbl[2].mem[1], fbg[2].fbl[1].mem[1], fbg[2].fbl[0].mem[1]}, {fbg[2].fbl[3].mem[0], fbg[2].fbl[2].mem[0], fbg[2].fbl[1].mem[0], fbg[2].fbl[0].mem[0]}, {fbg[1].fbl[3].mem[7], fbg[1].fbl[2].mem[7], fbg[1].fbl[1].mem[7], fbg[1].fbl[0].mem[7]}, {fbg[1].fbl[3].mem[6], fbg[1].fbl[2].mem[6], fbg[1].fbl[1].mem[6], fbg[1].fbl[0].mem[6]}, {fbg[1].fbl[3].mem[5], fbg[1].fbl[2].mem[5], fbg[1].fbl[1].mem[5], fbg[1].fbl[0].mem[5]}, {fbg[1].fbl[3].mem[4], fbg[1].fbl[2].mem[4], fbg[1].fbl[1].mem[4], fbg[1].fbl[0].mem[4]}, {fbg[1].fbl[3].mem[3], fbg[1].fbl[2].mem[3], fbg[1].fbl[1].mem[3], fbg[1].fbl[0].mem[3]}, {fbg[1].fbl[3].mem[2], fbg[1].fbl[2].mem[2], fbg[1].fbl[1].mem[2], fbg[1].fbl[0].mem[2]}, {fbg[1].fbl[3].mem[1], fbg[1].fbl[2].mem[1], fbg[1].fbl[1].mem[1], fbg[1].fbl[0].mem[1]}, {fbg[1].fbl[3].mem[0], fbg[1].fbl[2].mem[0], fbg[1].fbl[1].mem[0], fbg[1].fbl[0].mem[0]}, {fbg[0].fbl[3].mem[7], fbg[0].fbl[2].mem[7], fbg[0].fbl[1].mem[7], fbg[0].fbl[0].mem[7]}, {fbg[0].fbl[3].mem[6], fbg[0].fbl[2].mem[6], fbg[0].fbl[1].mem[6], fbg[0].fbl[0].mem[6]}, {fbg[0].fbl[3].mem[5], fbg[0].fbl[2].mem[5], fbg[0].fbl[1].mem[5], fbg[0].fbl[0].mem[5]}, {fbg[0].fbl[3].mem[4], fbg[0].fbl[2].mem[4], fbg[0].fbl[1].mem[4], fbg[0].fbl[0].mem[4]}, {fbg[0].fbl[3].mem[3], fbg[0].fbl[2].mem[3], fbg[0].fbl[1].mem[3], fbg[0].fbl[0].mem[3]}, {fbg[0].fbl[3].mem[2], fbg[0].fbl[2].mem[2], fbg[0].fbl[1].mem[2], fbg[0].fbl[0].mem[2]}, {fbg[0].fbl[3].mem[1], fbg[0].fbl[2].mem[1], fbg[0].fbl[1].mem[1], fbg[0].fbl[0].mem[1]}, {fbg[0].fbl[3].mem[0], fbg[0].fbl[2].mem[0], fbg[0].fbl[1].mem[0], fbg[0].fbl[0].mem[0]}}),
    .palv({pal[255], pal[254], pal[253], pal[252], pal[251], pal[250], pal[249], pal[248], pal[247], pal[246], pal[245], pal[244], pal[243], pal[242], pal[241], pal[240], pal[239], pal[238], pal[237], pal[236], pal[235], pal[234], pal[233], pal[232], pal[231], pal[230], pal[229], pal[228], pal[227], pal[226], pal[225], pal[224], pal[223], pal[222], pal[221], pal[220], pal[219], pal[218], pal[217], pal[216], pal[215], pal[214], pal[213], pal[212], pal[211], pal[210], pal[209], pal[208], pal[207], pal[206], pal[205], pal[204], pal[203], pal[202], pal[201], pal[200], pal[199], pal[198], pal[197], pal[196], pal[195], pal[194], pal[193], pal[192], pal[191], pal[190], pal[189], pal[188], pal[187], pal[186], pal[185], pal[184], pal[183], pal[182], pal[181], pal[180], pal[179], pal[178], pal[177], pal[176], pal[175], pal[174], pal[173], pal[172], pal[171], pal[170], pal[169], pal[168], pal[167], pal[166], pal[165], pal[164], pal[163], pal[162], pal[161], pal[160], pal[159], pal[158], pal[157], pal[156], pal[155], pal[154], pal[153], pal[152], pal[151], pal[150], pal[149], pal[148], pal[147], pal[146], pal[145], pal[144], pal[143], pal[142], pal[141], pal[140], pal[139], pal[138], pal[137], pal[136], pal[135], pal[134], pal[133], pal[132], pal[131], pal[130], pal[129], pal[128], pal[127], pal[126], pal[125], pal[124], pal[123], pal[122], pal[121], pal[120], pal[119], pal[118], pal[117], pal[116], pal[115], pal[114], pal[113], pal[112], pal[111], pal[110], pal[109], pal[108], pal[107], pal[106], pal[105], pal[104], pal[103], pal[102], pal[101], pal[100], pal[99], pal[98], pal[97], pal[96], pal[95], pal[94], pal[93], pal[92], pal[91], pal[90], pal[89], pal[88], pal[87], pal[86], pal[85], pal[84], pal[83], pal[82], pal[81], pal[80], pal[79], pal[78], pal[77], pal[76], pal[75], pal[74], pal[73], pal[72], pal[71], pal[70], pal[69], pal[68], pal[67], pal[66], pal[65], pal[64], pal[63], pal[62], pal[61], pal[60], pal[59], pal[58], pal[57], pal[56], pal[55], pal[54], pal[53], pal[52], pal[51], pal[50], pal[49], pal[48], pal[47], pal[46], pal[45], pal[44], pal[43], pal[42], pal[41], pal[40], pal[39], pal[38], pal[37], pal[36], pal[35], pal[34], pal[33], pal[32], pal[31], pal[30], pal[29], pal[28], pal[27], pal[26], pal[25], pal[24], pal[23], pal[22], pal[21], pal[20], pal[19], pal[18], pal[17], pal[16], pal[15], pal[14], pal[13], pal[12], pal[11], pal[10], pal[9], pal[8], pal[7], pal[6], pal[5], pal[4], pal[3], pal[2], pal[1], pal[0]}),
    .mode(mode), .busy(busy), .rd_st(rd_st), .rd_fb(rd_fb), .rd_in(rd_in), .rd_pal(rd_pal), .frame(frame));
`default_nettype wire
