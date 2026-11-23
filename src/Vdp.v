// ================================================================
// Vdp: VDP1, a tile-and-sprite engine for the game2d SoC (notes/soc-family-plan.md; Phase 5 G2).
// The programming model, layer rules and register map are in sw/vdp/vdp.h, and sw/vdp/vdp_ref.c
// is the reference model this block is compared against pixel for pixel (sim/vdp_ut).
//
// Register bus slave (sys clock; protocol in src/AXI4_RegBus.bsv).  Windows (Top.v decodes):
//   0xC002_0000  control (4 KB): 0x000 ID "VDP1", 0x004 CTRL, 0x008 BG_SCROLL, 0x00C BACKDROP,
//                0x010 STATUS; 0x400-0x5FC the sprite table (64 x 2 words)
//   0xC108_0000  VRAM (64 KB): 0x0000-0x0FFF the BG map (2048 x 16 bits), 0x8000-0xFFFF the
//                pattern RAM (8192 x 32 bits); byte writes work everywhere
// A read is answered two cycles after it is taken (the block RAMs register their output).
//
// Picture side (pixel clock): video_fb (src/Video_DVI.v) shows this block in its MODE 4.  It
// passes its stage-0 scan counters (scan_hc 0-799, scan_vc 0-524, scan_on) and takes idx, the
// palette index of that pixel, two pixel clocks later (its stage 2).  VDP line y (0-239) is
// scanlines 2y and 2y+1, pixel x is columns 2x and 2x+1.
//
// Rendering: line y is rendered into one of two line buffers (y mod 2) while line y-1 is on
// screen: it starts at hc 0 of scanline 2y-2 (line 0: scanline 523, in the vertical blank), so
// it has 1600 pixel clocks; it needs about 700 (BG 1 pixel a clock, the sprite scan over the 64
// entries alongside it, then up to 16 sprites at 20 clocks each).  The registers are copied
// into the pixel domain at each render start: the pixel side toggles rq_t 16 clocks before the
// start, the sys side copies CTRL / BG_SCROLL / BACKDROP into snap_* when it sees the toggle,
// and snap_* then holds still until the next toggle (at least 784 pixel clocks later), so the
// pixel side reads a stable value at the start.  A sprite overflow toggles ov_t back to the sys
// side, which sets STATUS[0].
//
// Trace outputs (pixel clock; unconnected in the FPGA build): r_start / r_line when a render
// starts, r_done when it finishes, r_busy while it runs, r_lw / r_lw_buf a line-buffer write and
// its buffer, for formal/fv/ips/vdp (the deadline: done before the line is shown).
// ================================================================
module vdp (
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
    input  wire [9:0]  scan_hc,
    input  wire [9:0]  scan_vc,
    input  wire        scan_on,
    output reg  [7:0]  idx,
    output wire        r_start,
    output wire [7:0]  r_line,
    output wire        r_done,
    output wire        r_busy,
    output wire        r_lw,
    output wire        r_lw_buf
);
    // ------------------------------------------------------------
    // Memories.  Byte lanes are separate arrays so every write strobe maps onto a RAM enable.

    // BG map: 1024 words of two entries (entry e in word e/2, half e%2)
    reg [7:0] map0 [0:1023], map1 [0:1023], map2 [0:1023], map3 [0:1023];
    // pattern RAM: 8192 words
    reg [7:0] pat0 [0:8191], pat1 [0:8191], pat2 [0:8191], pat3 [0:8191];
    // sprite table: word 0 and word 1 of each of the 64 sprites
    reg [7:0] sa0 [0:63], sa1 [0:63], sa2 [0:63], sa3 [0:63];
    reg [7:0] sb0 [0:63], sb1 [0:63], sb2 [0:63], sb3 [0:63];

    // ------------------------------------------------------------
    // System side

    reg  [1:0]  ctrl = 0;
    reg  [8:0]  sx = 0;
    reg  [7:0]  sy = 0;
    reg  [7:0]  backdrop = 0;
    reg         ovf = 0;

    wire win_vram = rb_addr[24];
    wire win_pat  = win_vram && rb_addr[15];
    wire win_map  = win_vram && !rb_addr[15] && (rb_addr[14:12] == 3'd0);
    wire win_spr  = !win_vram && (rb_addr[11:9] == 3'b010);    // 0x400-0x5FF
    wire spr_w1   = rb_addr[2];
    wire [5:0]  spr_i = rb_addr[8:3];

    reg  pend = 0;            // a request taken, answered next cycle
    reg  pend_we = 0;
    reg  [2:0] pend_win = 0;  // 0 regs, 1 map, 2 pattern, 3 sprites
    reg  [4:0] pend_reg = 0;
    wire take = rb_valid && !rb_ack && !pend;
    wire [3:0] be = rb_wstrb & {4{take && rb_we}};

    // port A of the RAMs: written and read here
    reg [31:0] map_qa, pat_qa;
    always @(posedge clk) begin
        if (win_map && be[0]) map0[rb_addr[11:2]] <= rb_wdata[7:0];
        if (win_map && be[1]) map1[rb_addr[11:2]] <= rb_wdata[15:8];
        if (win_map && be[2]) map2[rb_addr[11:2]] <= rb_wdata[23:16];
        if (win_map && be[3]) map3[rb_addr[11:2]] <= rb_wdata[31:24];
        map_qa <= { map3[rb_addr[11:2]], map2[rb_addr[11:2]], map1[rb_addr[11:2]], map0[rb_addr[11:2]] };
    end
    always @(posedge clk) begin
        if (win_pat && be[0]) pat0[rb_addr[14:2]] <= rb_wdata[7:0];
        if (win_pat && be[1]) pat1[rb_addr[14:2]] <= rb_wdata[15:8];
        if (win_pat && be[2]) pat2[rb_addr[14:2]] <= rb_wdata[23:16];
        if (win_pat && be[3]) pat3[rb_addr[14:2]] <= rb_wdata[31:24];
        pat_qa <= { pat3[rb_addr[14:2]], pat2[rb_addr[14:2]], pat1[rb_addr[14:2]], pat0[rb_addr[14:2]] };
    end
    reg [31:0] spr_qa;
    always @(posedge clk) begin
        if (win_spr && !spr_w1 && be[0]) sa0[spr_i] <= rb_wdata[7:0];
        if (win_spr && !spr_w1 && be[1]) sa1[spr_i] <= rb_wdata[15:8];
        if (win_spr && !spr_w1 && be[2]) sa2[spr_i] <= rb_wdata[23:16];
        if (win_spr && !spr_w1 && be[3]) sa3[spr_i] <= rb_wdata[31:24];
        if (win_spr &&  spr_w1 && be[0]) sb0[spr_i] <= rb_wdata[7:0];
        if (win_spr &&  spr_w1 && be[1]) sb1[spr_i] <= rb_wdata[15:8];
        if (win_spr &&  spr_w1 && be[2]) sb2[spr_i] <= rb_wdata[23:16];
        if (win_spr &&  spr_w1 && be[3]) sb3[spr_i] <= rb_wdata[31:24];
        spr_qa <= spr_w1 ? { sb3[spr_i], sb2[spr_i], sb1[spr_i], sb0[spr_i] }
                         : { sa3[spr_i], sa2[spr_i], sa1[spr_i], sa0[spr_i] };
    end

    // overflow events from the pixel side
    reg       ov_t = 0;                 // pixel domain
    reg [2:0] ov_s = 0;                 // sys domain synchronizer (+ previous)
    always @(posedge clk) ov_s <= { ov_s[1:0], ov_t };
    wire ov_ev = ov_s[2] != ov_s[1];

    always @(posedge clk) begin
        rb_ack <= 1'b0;
        if (rst) begin
            pend <= 1'b0; rb_rdata <= 32'b0;
            ctrl <= 0; sx <= 0; sy <= 0; backdrop <= 0; ovf <= 0;
        end else begin
            if (ov_ev) ovf <= 1'b1;
            if (take) begin
                pend     <= 1'b1;
                pend_we  <= rb_we;
                pend_win <= win_vram ? (win_pat ? 3'd2 : (win_map ? 3'd1 : 3'd4)) : (win_spr ? 3'd3 : 3'd0);
                pend_reg <= rb_addr[11:9] == 3'b000 && rb_addr[8:5] == 4'd0 ? rb_addr[6:2] : 5'd31;
                if (rb_we && !win_vram && !win_spr && rb_addr[11:5] == 7'd0)
                    case (rb_addr[4:2])
                        3'd1: if (rb_wstrb[0]) ctrl <= rb_wdata[1:0];
                        3'd2: begin
                                  if (rb_wstrb[0]) sx[7:0] <= rb_wdata[7:0];
                                  if (rb_wstrb[1]) sx[8]   <= rb_wdata[8];
                                  if (rb_wstrb[2]) sy      <= rb_wdata[23:16];
                              end
                        3'd3: if (rb_wstrb[0]) backdrop <= rb_wdata[7:0];
                        3'd4: ovf <= ov_ev;      // write clears (an event this cycle stays)
                        default: ;
                    endcase
            end
            if (pend) begin
                pend   <= 1'b0;
                rb_ack <= 1'b1;
                rb_rdata <= 32'b0;
                if (!pend_we)
                    case (pend_win)
                        3'd1: rb_rdata <= map_qa;
                        3'd2: rb_rdata <= pat_qa;
                        3'd3: rb_rdata <= spr_qa;
                        3'd0: case (pend_reg)
                                  5'd0: rb_rdata <= 32'h31504456;          // "VDP1"
                                  5'd1: rb_rdata <= {30'b0, ctrl};
                                  5'd2: rb_rdata <= {8'b0, sy, 7'b0, sx};
                                  5'd3: rb_rdata <= {24'b0, backdrop};
                                  5'd4: rb_rdata <= {31'b0, ovf};
                                  default: ;
                              endcase
                        default: ;
                    endcase
            end
        end
    end

    // register snapshot for the pixel side (see the header)
    reg        rq_t = 0;                // pixel domain
    reg [2:0]  rq_s = 0;
    reg [1:0]  snap_ctrl = 0;
    reg [8:0]  snap_sx = 0;
    reg [7:0]  snap_sy = 0;
    reg [7:0]  snap_bd = 0;
    always @(posedge clk) begin
        rq_s <= { rq_s[1:0], rq_t };
        if (rq_s[2] != rq_s[1]) begin
            snap_ctrl <= ctrl; snap_sx <= sx; snap_sy <= sy; snap_bd <= backdrop;
        end
    end

    // ------------------------------------------------------------
    // Pixel side: when to render which line

    // render line L starts at hc 0 of scanline 2L-2 (L = 0: scanline 523)
    wire       st_now  = scan_on && (scan_hc == 10'd0)
                         && ((scan_vc == 10'd523) || (!scan_vc[0] && scan_vc <= 10'd476));
    wire [7:0] st_line = (scan_vc == 10'd523) ? 8'd0 : scan_vc[8:1] + 8'd1;
    // the snapshot request: 16 clocks before a start (hc 784 of the scanline before; line 1's
    // start at scanline 0 has its request on scanline 524)
    wire       rq_now  = scan_on && (scan_hc == 10'd784)
                         && ((scan_vc == 10'd522) || (scan_vc == 10'd524)
                             || (scan_vc[0] && scan_vc <= 10'd475));
    always @(posedge pclk) if (rq_now) rq_t <= ~rq_t;

    // the line being rendered and its copy of the registers
    reg [7:0]  ln = 0;
    reg [1:0]  c_ctrl = 0;
    reg [8:0]  c_sx = 0;
    reg [7:0]  c_sy = 0;
    reg [7:0]  bd_buf0 = 0, bd_buf1 = 0;   // the backdrop of each line buffer's line

    // ------------------------------------------------------------
    // Every pixel-side RAM read below takes a combinational address (from registers) and
    // registers the data: the data is seen the next cycle.

    // Line buffers: {BG opaque, index} per pixel.  Port A writes (render); port B reads, for
    // the scan-out on the buffer on screen and for the sprite pass on the other.  During the
    // vertical blank the scan-out side is buffer 1, so line 0 renders into buffer 0 freely.
    reg [8:0] lb0 [0:511], lb1 [0:511];
    reg        lw_en = 0;
    reg        lw_buf = 0;
    reg [8:0]  lw_x = 0;
    reg [8:0]  lw_d = 0;
    always @(posedge pclk) begin
        if (lw_en && !lw_buf) lb0[lw_x] <= lw_d;
        if (lw_en &&  lw_buf) lb1[lw_x] <= lw_d;
    end
    wire       front = (scan_vc < 10'd480) ? scan_vc[1] : 1'b1;   // buffer of line vc / 2
    wire [8:0] sc_x  = { 1'b0, scan_hc[9:1] };
    wire [8:0] rd_x;                                 // the sprite pass's read (below)
    reg  [8:0] lb0_q, lb1_q;
    always @(posedge pclk) begin
        lb0_q <= lb0[(front == 1'b0) ? sc_x : rd_x];
        lb1_q <= lb1[(front == 1'b1) ? sc_x : rd_x];
    end
    // scan-out: stage 0 counters, stage 1 RAM output, stage 2 idx
    reg       front1 = 0;
    reg [7:0] bd1 = 0;
    always @(posedge pclk) begin
        front1 <= front;
        bd1    <= front ? bd_buf1 : bd_buf0;
        begin : so
            reg [8:0] q;
            q = front1 ? lb1_q : lb0_q;
            idx <= (q[7:0] == 8'd0) ? bd1 : q[7:0];
        end
    end

    // ------------------------------------------------------------
    // Render engine

    localparam S_IDLE = 2'd0, S_BG = 2'd1, S_SPR = 2'd2;
    reg [1:0]  st = S_IDLE;
    reg        busy = 0;

    // BG pass.  Stage 0: bx (0-319) addresses the map; stage 1: the map entry addresses the
    // pattern RAM; stage 2: the pattern word gives the pixel, written to the line buffer.
    reg [8:0]  bx = 0;
    reg        bv0 = 0, bv1 = 0, bv2 = 0;
    reg [8:0]  bx1 = 0, bx2 = 0;
    reg [2:0]  bpx1 = 0, bpy1 = 0;
    reg        bhalf1 = 0;
    reg [2:0]  bcol2 = 0;
    reg [3:0]  bbank2 = 0;
    wire [8:0] b_px = bx + c_sx;
    wire [7:0] b_py = ln + c_sy;
    wire [9:0] map_a = { b_py[7:3], b_px[8:4] };
    reg [31:0] map_qb;
    always @(posedge pclk) map_qb <= { map3[map_a], map2[map_a], map1[map_a], map0[map_a] };
    wire [15:0] b_e   = bhalf1 ? map_qb[31:16] : map_qb[15:0];
    wire [2:0]  b_r   = b_e[15] ? 3'd7 - bpy1 : bpy1;

    // sprite draw state (the list and the current sprite)
    reg [8:0]  l_x  [0:15];
    reg [3:0]  l_j  [0:15];
    reg [17:0] l_a  [0:15];               // word 1 [17:0]
    reg [4:0]  ln_n = 0;                  // sprites listed (0-16)
    reg        ovf_line = 0;
    reg [4:0]  dk = 0;                    // list entries left to draw, this one included
    reg [4:0]  dph = 0;                   // 0 fetch left, 1 fetch right, 2 latch, 3-18 pixels
    reg [31:0] wl = 0, wr = 0;            // row words of the screen-left / -right tiles
    reg [8:0]  d_x = 0;
    reg [3:0]  d_j = 0;
    reg [17:0] d_a = 0;
    wire [3:0] d_r    = d_a[15] ? 4'd15 - d_j : d_j;          // row in the sprite after vflip
    wire [9:0] d_ttop = d_a[9:0] + (d_r[3] ? 10'd2 : 10'd0);
    wire [9:0] d_tl   = d_ttop + (d_a[14] ? 10'd1 : 10'd0);   // screen-left tile
    wire [9:0] d_tr   = d_ttop + (d_a[14] ? 10'd0 : 10'd1);   // screen-right tile
    wire [3:0] d_i2   = dph[3:0] - 4'd3;                      // pixel 0-15 at dph 3-18
    assign     rd_x   = d_x + { 5'b0, d_i2 };
    wire [2:0] d_nb   = d_a[14] ? 3'd7 - d_i2[2:0] : d_i2[2:0]; // nibble in the row word (hflip)
    wire [31:0] d_w   = d_i2[3] ? wr : wl;
    wire [3:0] d_n    = d_w[4*d_nb +: 4];                     // the sprite pixel at dph 3-18

    // pattern RAM port B: the BG pass at stage 1, the sprite fetch at dph 0 / 1
    wire [12:0] pat_a = (st == S_SPR) ? { (dph == 5'd0) ? d_tl : d_tr, d_r[2:0] }
                                      : { b_e[9:0], b_r };
    reg [31:0] pat_qb;
    always @(posedge pclk) pat_qb <= { pat3[pat_a], pat2[pat_a], pat1[pat_a], pat0[pat_a] };

    // sprite scan, alongside the BG pass: entry ei is read, seen the next cycle
    reg [5:0]  ei = 0;
    reg        ev = 0, ev1 = 0;
    reg [31:0] e_w0, e_w1;
    always @(posedge pclk) begin
        e_w0 <= { sa3[ei], sa2[ei], sa1[ei], sa0[ei] };
        e_w1 <= { sb3[ei], sb2[ei], sb1[ei], sb0[ei] };
    end

    // sprite pixel pipeline: dph 3-18 reads the line buffer at rd_x, the next cycle writes
    reg        pv1 = 0;
    reg [8:0]  px1 = 0;
    reg [7:0]  pidx1 = 0;
    reg        pbehind1 = 0;

    reg        done_p = 0;
    reg        start_p = 0;
    assign r_start = start_p;
    assign r_line  = ln;
    assign r_done  = done_p;
    assign r_busy  = busy;
    assign r_lw    = lw_en;
    assign r_lw_buf = lw_buf;

    always @(posedge pclk) begin
        lw_en   <= 1'b0;
        done_p  <= 1'b0;
        start_p <= 1'b0;
        pv1     <= 1'b0;
        if (st_now) begin
            // a new line: anything still in progress is abandoned (formal/fv/ips/vdp proves
            // every render ends first)
            st <= S_BG; busy <= 1'b1; start_p <= 1'b1;
            ln <= st_line;
            c_ctrl <= snap_ctrl; c_sx <= snap_sx; c_sy <= snap_sy;
            if (st_line[0]) bd_buf1 <= snap_bd; else bd_buf0 <= snap_bd;
            bx <= 0; bv0 <= 1'b1; bv1 <= 1'b0; bv2 <= 1'b0;
            ei <= 0; ev <= 1'b1; ev1 <= 1'b0; ln_n <= 0; ovf_line <= 1'b0;
            dph <= 0;
        end else begin
            // ---------------- BG pass
            bv1 <= bv0; bx1 <= bx; bhalf1 <= b_px[3]; bpx1 <= b_px[2:0]; bpy1 <= b_py[2:0];
            if (bv0) begin
                if (bx == 9'd319) bv0 <= 1'b0; else bx <= bx + 1;
            end
            bv2 <= bv1; bx2 <= bx1;
            bcol2  <= b_e[14] ? 3'd7 - bpx1 : bpx1;
            bbank2 <= b_e[13:10];
            if (bv2) begin
                begin : s2
                    reg [3:0] n;
                    n = pat_qb[4*bcol2 +: 4];
                    if (!c_ctrl[0]) n = 4'd0;
                    lw_en  <= 1'b1;
                    lw_buf <= ln[0];
                    lw_x   <= bx2;
                    lw_d   <= (n == 4'd0) ? 9'd0 : { 1'b1, bbank2, n };
                end
            end

            // ---------------- sprite scan
            ev1 <= ev;
            if (ev) begin
                if (ei == 6'd63) ev <= 1'b0; else ei <= ei + 1;
            end
            if (ev1 && c_ctrl[1]) begin
                begin : scan
                    reg [8:0] j;
                    j = { 1'b0, ln } - e_w0[24:16];
                    if (e_w1[16] && j < 9'd16) begin
                        if (ln_n < 5'd16) begin
                            l_x[ln_n[3:0]] <= e_w0[8:0];
                            l_j[ln_n[3:0]] <= j[3:0];
                            l_a[ln_n[3:0]] <= e_w1[17:0];
                            ln_n <= ln_n + 1;
                        end else
                            ovf_line <= 1'b1;
                    end
                end
            end

            // ---------------- BG and scan both finished
            if (st == S_BG && !bv0 && !bv1 && !bv2 && !ev && !ev1) begin
                if (ovf_line) ov_t <= ~ov_t;
                if (ln_n == 0) begin
                    st <= S_IDLE; busy <= 1'b0; done_p <= 1'b1;
                end else begin
                    st <= S_SPR; dk <= ln_n; dph <= 0;
                    d_x <= l_x[ln_n - 1]; d_j <= l_j[ln_n - 1]; d_a <= l_a[ln_n - 1];
                end
            end

            // ---------------- sprite draw, highest list entry first
            if (st == S_SPR) begin
                if (dph == 5'd1) wl <= pat_qb;
                if (dph == 5'd2) wr <= pat_qb;
                if (dph >= 5'd3) begin
                    pv1      <= (d_n != 4'd0) && (rd_x < 9'd320);
                    px1      <= rd_x;
                    pidx1    <= { d_a[13:10], d_n };
                    pbehind1 <= d_a[17];
                end
                if (dph == 5'd18) begin
                    dph <= 0;
                    if (dk == 5'd1)
                        st <= S_IDLE;
                    else begin
                        dk <= dk - 1;
                        d_x <= l_x[dk - 2]; d_j <= l_j[dk - 2]; d_a <= l_a[dk - 2];
                    end
                end else
                    dph <= dph + 1;
            end
            // the pixel's write: a behind sprite only over a transparent BG pixel
            if (pv1) begin
                begin : wr_px
                    reg [8:0] q;
                    q = ln[0] ? lb1_q : lb0_q;
                    if (!(pbehind1 && q[8])) begin
                        lw_en <= 1'b1; lw_buf <= ln[0]; lw_x <= px1; lw_d <= { q[8], pidx1 };
                    end
                end
            end
            // the sprite pass ends when its last pixel is written
            if (busy && st == S_IDLE && !pv1 && ln_n != 0) begin
                busy <= 1'b0; done_p <= 1'b1;
            end
        end
    end
endmodule
