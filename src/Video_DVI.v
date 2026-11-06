// ================================================================
// Video_DVI: block-RAM framebuffer, palette and DVI (TMDS) output on the ULX3S GPDI port.
// 640x480 at 60 Hz (25 MHz pixel clock, 800x525 total, both syncs active low).
//
// Register bus slave (sys clock; protocol in src/AXI4_RegBus.bsv).  Windows:
//   0xC001_0000  control (4 KB)
//     0x000 ID      RO  0x56494431 ("VID1")
//     0x004 MODE    RW  [2:0]  0 off (no sync: the display sleeps), 1 640x480 4 bpp palette
//                              (entries 0-15), 2 320x240 RGB565, 3 320x240 8 bpp palette,
//                              7 test pattern (colour bars over a grey ramp, white border);
//                              320x240 modes are doubled in both directions
//     0x008 STATUS  RO  [0] in vertical blank
//     0x00C FRAME   RO  frames started since reset (counts at the start of vertical blank)
//     0x010 FBSIZE  RO  bytes of pixel RAM (153600)
//     0x400-0x7FC PALETTE[256]  RW  0x00RRGGBB (a write replaces the entry).  Reset: 0-15
//                              the VGA/TempleOS colours, 16-255 RGB332 of the index
//   0xC100_0000  pixel RAM (153600 bytes; byte writes work, reads above the end return 0).
//     Little endian: 4 bpp has the left pixel in the low nibble, RGB565 is a 16-bit word per
//     pixel; the line stride is 320 bytes (4 bpp, 8 bpp) or 640 bytes (RGB565).
//
// The pixel RAM and the palette are true dual-port block RAMs: the system side reads and
// writes on sys_clk, the scan-out reads on the pixel clock, so pixels never cross a FIFO.
// MODE crosses through a two-flop synchronizer (a change takes effect within a frame);
// the vertical-blank toggle comes back the same way.
// ================================================================

module video_fb #(
    // Pixel RAM geometry; only the formal harness (formal/video) shrinks these.
    parameter FB_WORDS  = 38400,    // 153600 bytes
    parameter BANK_BITS = 13
) (
    input  wire        clk,         // system clock
    input  wire        rst,         // system reset, active high
    input  wire        rb_valid,
    input  wire        rb_we,
    input  wire [31:0] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_wstrb,
    output reg         rb_ack,
    output reg  [31:0] rb_rdata,

    input  wire        pclk,        // pixel clock (25 MHz)
    output wire [9:0]  tmds_r,      // pixel-clock domain TMDS words, bit 0 sent first
    output wire [9:0]  tmds_g,
    output wire [9:0]  tmds_b,
    output reg         ptog,        // toggles every pixel clock (serializer phase reference)
    // pre-encoder taps for simulation benches (pixel-clock domain, aligned with each other)
    output reg  [23:0] dbg_rgb,
    output reg         dbg_de,
    output reg         dbg_hs,
    output reg         dbg_vs
);
    // ------------------------------------------------------------
    // Memories

    // Pixel RAM as four byte lanes (byte strobes without byte-enable support in the RAM),
    // each lane in NBANK banks of BANK_WORDS words (4 DP16KD each, the last one 3), declared in
    // the generate block below.  One 38400-word array per lane read back through a 19:1 mux
    // spread over the whole EBR row (~19 ns, the critical path on one seed); in banks, each
    // bank's 4:1 mux has its own register and the 5:1 bank mux comes one cycle later.
    localparam BANK_WORDS = 1 << BANK_BITS;
    localparam NBANK      = (FB_WORDS + BANK_WORDS - 1) / BANK_WORDS;     // 5

    reg [23:0] pal [0:255];
    integer i;
    reg [7:0] k;
    initial begin
        for (i = 0; i < 256; i = i + 1) begin
            k = i;
            pal[i] = { k[7:5], k[7:5], k[7:6], k[4:2], k[4:2], k[4:3], k[1:0], k[1:0], k[1:0], k[1:0] };
        end
        pal[0]  = 24'h000000; pal[1]  = 24'h0000AA; pal[2]  = 24'h00AA00; pal[3]  = 24'h00AAAA;
        pal[4]  = 24'hAA0000; pal[5]  = 24'hAA00AA; pal[6]  = 24'hAA5500; pal[7]  = 24'hAAAAAA;
        pal[8]  = 24'h555555; pal[9]  = 24'h5555FF; pal[10] = 24'h55FF55; pal[11] = 24'h55FFFF;
        pal[12] = 24'hFF5555; pal[13] = 24'hFF55FF; pal[14] = 24'hFFFF55; pal[15] = 24'hFFFFFF;
    end

    // pixel-side state the system side reads back (through synchronizers)
    reg       vtog  = 0;        // toggles at the start of each vertical blank
    reg       vbl_p = 0;        // in vertical blank
    reg [1:0] vbl_ss = 0;
    wire      vbl_s = vbl_ss[1];

    // ------------------------------------------------------------
    // System side

    wire        sel_fb   = rb_addr[24];                         // 0xC1xx_xxxx
    wire [15:0] fb_word  = rb_addr[17:2];
    wire        fb_in    = (rb_addr[23:18] == 0) && (fb_word < FB_WORDS);
    wire        sel_pal  = !sel_fb && (rb_addr[11:10] == 2'b01);
    wire [7:0]  pal_idx  = rb_addr[9:2];

    reg         busy;
    wire        take     = rb_valid && !busy && !rb_ack;
    wire        wr       = take && rb_we;
    wire [3:0]  fb_we    = (wr && sel_fb && fb_in) ? rb_wstrb : 4'b0;
    wire        pal_we   = wr && sel_pal;

    // The framebuffer RAMs sit in the bottom EBR rows (constraints/video_floorplan.py), far
    // from the register bus, so their system port is registered on both sides: address, data
    // and enables one cycle after the take; the RAM read; each bank's word mux into fbb; the
    // bank mux into fbq.  Each long route is then register to register.
    reg  [15:0] a_r;
    reg  [31:0] wd_r;
    reg  [3:0]  we_r = 4'b0;
    reg  [2:0]  ab1, ab2;          // bank of the read, aligned with the RAM read / fbb
    reg  [31:0] fbq;
    always @(posedge clk) begin
        a_r  <= fb_word;
        wd_r <= rb_wdata;
        we_r <= fb_we;
        ab1  <= a_r[15:BANK_BITS];
        ab2  <= ab1;
    end

    // pixel side address (pixel pipeline below)
    wire [15:0] pa;
    reg  [2:0]  pb1;               // bank of the pixel read, aligned with the RAM read
    always @(posedge pclk) pb1 <= pa[15:BANK_BITS];

    wire [32*NBANK-1:0] fbb;       // system side, per bank, one cycle after the RAM read
    wire [32*NBANK-1:0] pqb;       // pixel side, per bank, the RAM read
    genvar gb, gl;
    generate
        for (gb = 0; gb < NBANK; gb = gb + 1) begin : fbg
            localparam WORDS = (gb == NBANK - 1) ? FB_WORDS - gb * BANK_WORDS : BANK_WORDS;
            wire wr_bank = (a_r[15:BANK_BITS] == gb);
            for (gl = 0; gl < 4; gl = gl + 1) begin : fbl
                reg [7:0] mem [0:WORDS-1];
                reg [7:0] q, qq, pq;
                always @(posedge clk) begin
                    if (we_r[gl] && wr_bank) mem[a_r[BANK_BITS-1:0]] <= wd_r[8*gl +: 8];
                    q  <= mem[a_r[BANK_BITS-1:0]];
                    qq <= q;
                end
                always @(posedge pclk) pq <= mem[pa[BANK_BITS-1:0]];
                assign fbb[32*gb + 8*gl +: 8] = qq;
                assign pqb[32*gb + 8*gl +: 8] = pq;
            end
        end
    endgenerate
    always @(posedge clk) fbq <= fbb[32*ab2 +: 32];

    // a palette write replaces the whole entry ([23:0]) whatever the strobes
    reg  [23:0] pal_q;
    always @(posedge clk) begin
        if (pal_we) pal[pal_idx] <= rb_wdata[23:0];
        pal_q <= pal[pal_idx];
    end

    reg  [2:0]  mode;
    reg  [31:0] frame;
    reg         in_vblank;
    reg  [2:0]  vtog_s;
    reg         rd_in;     // the read address is backed (else 0)
    reg         rd_fb, rd_pal;
    reg  [1:0]  rd_st;
    reg  [31:0] ctl_q;

    always @(*) begin
        case (rb_addr[11:2])
            10'h000: ctl_q = 32'h56494431;
            10'h001: ctl_q = { 29'b0, mode };
            10'h002: ctl_q = { 31'b0, in_vblank };
            10'h003: ctl_q = frame;
            10'h004: ctl_q = FB_WORDS * 4;
            default: ctl_q = 32'b0;
        endcase
    end

    always @(posedge clk) begin
        vtog_s <= { vtog_s[1:0], vtog };
        in_vblank <= vbl_s;
        rb_ack <= 1'b0;
        if (rst) begin
            busy  <= 1'b0;
            mode  <= 3'd0;
            frame <= 32'd0;
        end else begin
            if (vtog_s[2] != vtog_s[1])
                frame <= frame + 1;
            if (take) begin
                if (rb_we) begin
                    if (!sel_fb && rb_addr[11:2] == 10'h001 && rb_wstrb[0])
                        mode <= rb_wdata[2:0];
                    rb_ack <= 1'b1;
                end else begin
                    busy     <= 1'b1;
                    rd_st    <= 2'd0;
                    rd_fb    <= sel_fb;
                    rd_in    <= fb_in;
                    rd_pal   <= sel_pal;
                    rb_rdata <= ctl_q;
                end
            end else if (busy) begin
                // a_r is set after the take, the RAM read one cycle later, fbb one more,
                // fbq one more
                rd_st <= rd_st + 2'd1;
                if (rd_st == 2'd3) begin
                    if (rd_fb)
                        rb_rdata <= rd_in ? fbq : 32'b0;
                    else if (rd_pal)
                        rb_rdata <= { 8'b0, pal_q };
                    rb_ack <= 1'b1;
                    busy   <= 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Pixel side: timing

    reg [2:0] mode_p1 = 0, mode_p = 0;
    always @(posedge pclk) begin
        mode_p1 <= mode;
        mode_p  <= mode_p1;
    end
    wire on     = (mode_p != 3'd0);
    wire m_pal4 = (mode_p == 3'd1);
    wire m_565  = (mode_p == 3'd2);
    wire m_test = (mode_p == 3'd7);

    reg [9:0]  hc = 0, vc = 0;
    reg [15:0] lb = 0;          // word address of the current source line
    always @(posedge pclk) begin
        ptog <= ~ptog;
        if (!on) begin
            hc <= 0; vc <= 0; lb <= 0;
        end else if (hc == 799) begin
            hc <= 0;
            if (vc == 524) begin
                vc <= 0; lb <= 0;
            end else begin
                vc <= vc + 1;
                if (m_pal4)          lb <= lb + 80;
                else if (vc[0])      lb <= lb + (m_565 ? 16'd160 : 16'd80);
            end
            if (vc == 479) vtog <= ~vtog;
        end else
            hc <= hc + 1;
    end
    initial ptog = 0;

    always @(posedge pclk) vbl_p <= (vc >= 480);
    always @(posedge clk) vbl_ss <= { vbl_ss[0], vbl_p };

    // ------------------------------------------------------------
    // Pixel side: pipeline.  Stage 0 = counters; the RAM read registers at the edge into
    // stage 1, the lane mux into stage 2, the palette read into stage 3, the colour into
    // stage 4, the TMDS words into stage 5.

    assign pa = lb + (m_565 ? { 8'b0, hc[9:2] } : { 9'b0, hc[9:3] });

    wire de0 = on && (hc < 640) && (vc < 480);
    wire hs0 = !(on && (hc >= 656) && (hc < 752));
    wire vs0 = !(on && (vc >= 490) && (vc < 492));

    // control delay line: [stage] de, hs, vs, sel bits, test-pattern inputs
    reg        de1, de2, de3, de4;
    reg        hs1, hs2, hs3, hs4;
    reg        vs1, vs2, vs3, vs4;
    reg [2:0]  sl1, sl2;
    reg [9:0]  hx1, hx2, hx3;
    reg [9:0]  vy1, vy2, vy3;
    reg [31:0] w2;
    reg [7:0]  pidx;
    reg [23:0] rgb3, rgb4;
    reg [23:0] ppal;
    reg        p565_3;

    always @(posedge pclk) begin
        de1 <= de0; hs1 <= hs0; vs1 <= vs0; sl1 <= hc[2:0]; hx1 <= hc; vy1 <= vc;
        de2 <= de1; hs2 <= hs1; vs2 <= vs1; sl2 <= sl1;     hx2 <= hx1; vy2 <= vy1;
        w2  <= pqb[32*pb1 +: 32];
        // stage 2 -> 3
        de3 <= de2; hs3 <= hs2; vs3 <= vs2; hx3 <= hx2; vy3 <= vy2;
        p565_3 <= m_565;
        begin : extract
            reg [15:0] h;
            h = sl2[1] ? w2[31:16] : w2[15:0];
            rgb3 <= { h[15:11], h[15:13], h[10:5], h[10:9], h[4:0], h[4:2] };
        end
        ppal <= pal[pidx];
        // stage 3 -> 4
        de4 <= de3; hs4 <= hs3; vs4 <= vs3;
        if (!de3)
            rgb4 <= 24'b0;
        else if (m_test) begin
            if (hx3 == 0 || hx3 == 639 || vy3 == 0 || vy3 == 479)
                rgb4 <= 24'hFFFFFF;
            else if (vy3 < 240)
                rgb4 <= { {8{hx3[8]}}, {8{hx3[7]}}, {8{hx3[6]}} };
            else
                rgb4 <= { 3{hx3[9:2]} };
        end else
            rgb4 <= p565_3 ? rgb3 : ppal;
    end

    // palette index at stage 2 (combinational from w2, registered into the palette RAM)
    always @(*) begin
        if (m_pal4)
            case (sl2)
                3'd0: pidx = { 4'b0, w2[3:0]   };
                3'd1: pidx = { 4'b0, w2[7:4]   };
                3'd2: pidx = { 4'b0, w2[11:8]  };
                3'd3: pidx = { 4'b0, w2[15:12] };
                3'd4: pidx = { 4'b0, w2[19:16] };
                3'd5: pidx = { 4'b0, w2[23:20] };
                3'd6: pidx = { 4'b0, w2[27:24] };
                default: pidx = { 4'b0, w2[31:28] };
            endcase
        else
            case (sl2[2:1])
                2'd0: pidx = w2[7:0];
                2'd1: pidx = w2[15:8];
                2'd2: pidx = w2[23:16];
                default: pidx = w2[31:24];
            endcase
    end

    always @(posedge pclk) begin
        dbg_rgb <= rgb4; dbg_de <= de4; dbg_hs <= hs4; dbg_vs <= vs4;
    end

    tmds_enc enc_b (.clk(pclk), .de(de4), .ctrl({ vs4, hs4 }), .d(rgb4[7:0]),   .q(tmds_b));
    tmds_enc enc_g (.clk(pclk), .de(de4), .ctrl(2'b00),        .d(rgb4[15:8]),  .q(tmds_g));
    tmds_enc enc_r (.clk(pclk), .de(de4), .ctrl(2'b00),        .d(rgb4[23:16]), .q(tmds_r));
endmodule

// ----------------------------------------------------------------
// TMDS encoder (DVI 1.0 section 3.2.3), one registered output word per pixel clock.

module tmds_enc (
    input  wire       clk,
    input  wire       de,
    input  wire [1:0] ctrl,     // { C1, C0 }
    input  wire [7:0] d,
    output reg  [9:0] q
);
    function [3:0] ones8 (input [7:0] x);
        integer k;
        begin
            ones8 = 0;
            for (k = 0; k < 8; k = k + 1) ones8 = ones8 + x[k];
        end
    endfunction

    wire [3:0] n1d = ones8(d);
    wire       xn  = (n1d > 4) || (n1d == 4 && !d[0]);
    // transition-minimizing stage, as a function: a per-bit assign chain on one vector reads
    // as circular logic to the simulator (UNOPTFLAT)
    function [8:0] tmds_qm (input [7:0] x, input use_xnor);
        integer k;
        begin
            tmds_qm[0] = x[0];
            for (k = 1; k < 8; k = k + 1)
                tmds_qm[k] = use_xnor ? ~(tmds_qm[k-1] ^ x[k]) : (tmds_qm[k-1] ^ x[k]);
            tmds_qm[8] = ~use_xnor;
        end
    endfunction
    wire [8:0] qm = tmds_qm(d, xn);

    wire [3:0]        n1q  = ones8(qm[7:0]);
    wire signed [4:0] diff = $signed({ 1'b0, n1q }) - $signed(5'd4);   // (n1 - n0) / 2
    reg  signed [4:0] cnt = 0;                                          // disparity / 2

    always @(posedge clk) begin
        if (!de) begin
            cnt <= 0;
            case (ctrl)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || diff == 0) begin
            q   <= { ~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0] };
            cnt <= qm[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
            q   <= { 1'b1, qm[8], ~qm[7:0] };
            cnt <= cnt + $signed({ 4'b0, qm[8] }) - diff;
        end else begin
            q   <= { 1'b0, qm[8], qm[7:0] };
            cnt <= cnt - $signed({ 4'b0, ~qm[8] }) + diff;
        end
    end
endmodule

// ----------------------------------------------------------------
// DVI serializer: 10:1 at 5x the pixel clock through ODDRX1F (2 bits per shift clock).
// The shift-clock domain finds the pixel-clock phase from ptog (a pixel-domain toggle) and
// loads the words two shift clocks after it sees the toggle, so the words have been stable
// for over two shift clocks and stay stable for one more.

module dvi_ser (
    input  wire       sclk,         // 5x pixel clock (125 MHz), same PLL as the pixel clock
    input  wire       ptog,
    input  wire [9:0] tmds_r,
    input  wire [9:0] tmds_g,
    input  wire [9:0] tmds_b,
    output wire [3:0] gpdi_dp       // [0] blue, [1] green, [2] red, [3] clock
);
    reg       t1 = 0, t2 = 0;
    reg [2:0] ph = 0;
    reg [9:0] sr = 0, sg = 0, sb = 0, sc = 0;
    always @(posedge sclk) begin
        t1 <= ptog;
        t2 <= t1;
        ph <= (t1 != t2) ? 3'd0 : ph + 1;
        if (ph == 3'd1) begin
            sr <= tmds_r; sg <= tmds_g; sb <= tmds_b; sc <= 10'b0000011111;
        end else begin
            sr <= sr >> 2; sg <= sg >> 2; sb <= sb >> 2; sc <= sc >> 2;
        end
    end
    ODDRX1F ddr_b (.D0(sb[0]), .D1(sb[1]), .SCLK(sclk), .RST(1'b0), .Q(gpdi_dp[0]));
    ODDRX1F ddr_g (.D0(sg[0]), .D1(sg[1]), .SCLK(sclk), .RST(1'b0), .Q(gpdi_dp[1]));
    ODDRX1F ddr_r (.D0(sr[0]), .D1(sr[1]), .SCLK(sclk), .RST(1'b0), .Q(gpdi_dp[2]));
    ODDRX1F ddr_c (.D0(sc[0]), .D1(sc[1]), .SCLK(sclk), .RST(1'b0), .Q(gpdi_dp[3]));
endmodule
