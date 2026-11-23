// ================================================================
// Apu: APU1, the game2d sound chip (notes/soc-family-plan.md; Phase 5 G3).  The programming
// model, the register map and the exact per-tick arithmetic are in sw/apu/apu.h; sw/apu/apu_ref.c
// is the reference model this block matches sample for sample (sim/apu_ut).
//
// Register bus slave (sys clock; protocol in src/AXI4_RegBus.bsv), window 0xC004_0000 (64 KB):
// registers in 0x0000-0x0FFF (aliased up to 0x7FFF), the wave RAM in 0x8000-0xFFFF.  Every
// request is answered two cycles after its take.  Reads come from a shadow copy (the last value
// written) or status; writes go into the write queue (1024 entries) and are applied, in order, at
// the next sample tick.
//
// One sequencer, all in the system clock domain.  Every TICK clocks (a tick):
//   drain  the writes queued before the tick, 2 clocks each: register / wave RAM writes, KEYON
//          and KEYOFF (one clock: the voice state is in flip-flops)
//   voices 8 x 12 clocks: the voice's registers from the active register RAM, the wave byte, the
//          output (w * level, then * VOL_L and * VOL_R) and the advance (phase, LFSR, envelope)
//   mix    the sums times MASTER, saturated, into out_l / out_r (held until the next tick)
// The tick's work is bounded: a write takes at least 3 bus clocks, so at most TICK / 3 + 1 are
// queued per tick and the drain plus the voices end well within the tick (formal/fv/ips/apu
// proves it, and that the queue never fills).
//
// After reset: CTRL 0, MASTER 64, every voice stopped, the queue empty.  The voice registers and
// the wave RAM are not reset: write them before a KEYON.
//
// Trace outputs (unconnected in the FPGA build): tr_tick (a tick), tr_busy (the sequencer is
// working), tr_done (out_l / out_r just took the tick's sample), tr_level (queued writes),
// tr_apply (a queued write applied, with its offset, strobes and data), for formal/fv/ips/apu
// and sim/apu_ut.
// ================================================================
module apu #(
    parameter integer TICK = 1563             // clocks per sample tick (31.99 kHz at 50 MHz)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        rb_valid,
    input  wire        rb_we,
    input  wire [31:0] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_wstrb,
    output reg         rb_ack,
    output reg  [31:0] rb_rdata,
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r,
    output wire        tr_tick,
    output wire        tr_busy,
    output reg         tr_done,
    output wire [10:0] tr_level,
    output wire        tr_apply,              // a queued write is applied now: tr_apply_a / _s / _d
    output wire [15:0] tr_apply_a,
    output wire [3:0]  tr_apply_s,
    output wire [31:0] tr_apply_d
);
    // ------------------------------------------------------------
    // Bus side

    reg         pend = 0, pend_we = 0;
    reg  [15:0] pend_a = 0;
    wire        take = rb_valid && !rb_ack && !pend;
    wire [15:0] a = rb_addr[15:0];

    // shadow of the voice registers (for reads): 64 words in byte lanes
    reg [7:0] sh0 [0:63], sh1 [0:63], sh2 [0:63], sh3 [0:63];
    wire [5:0] sh_i = a[7:2];
    wire       sh_w = take && rb_we && !a[15] && a[11:8] == 4'h1;
    reg [31:0] sh_q;
    always @(posedge clk) begin
        if (sh_w && rb_wstrb[0]) sh0[sh_i] <= rb_wdata[7:0];
        if (sh_w && rb_wstrb[1]) sh1[sh_i] <= rb_wdata[15:8];
        if (sh_w && rb_wstrb[2]) sh2[sh_i] <= rb_wdata[23:16];
        if (sh_w && rb_wstrb[3]) sh3[sh_i] <= rb_wdata[31:24];
        sh_q <= { sh3[sh_i], sh2[sh_i], sh1[sh_i], sh0[sh_i] };
    end
    reg        ctrl_sh = 0;
    reg  [7:0] master_sh = 8'd64;

    // the write queue: {address [15:2], strobes, data}
    reg  [49:0] qm [0:1023];
    reg  [9:0]  wp = 0, rp = 0;
    reg  [10:0] level = 0;
    wire        enq = take && rb_we && level != 11'd1024;
    wire        deq;                          // the sequencer applies the head (below)
    always @(posedge clk) if (enq) qm[wp] <= { a[15:2], rb_wstrb, rb_wdata };
    assign tr_level = level;

    // ------------------------------------------------------------
    // Voice state (flip-flops) and the active registers

    localparam [2:0] ST_OFF = 3'd0, ST_ATTACK = 3'd1, ST_DECAY = 3'd2, ST_SUSTAIN = 3'd3, ST_RELEASE = 3'd4;
    reg  [26:0] vp [0:7];
    reg  [15:0] ve [0:7];
    reg  [2:0]  vs [0:7];
    reg  [14:0] vl [0:7];
    reg         ctrl = 0;
    reg  [7:0]  master = 8'd64;
    reg  [31:0] ticks = 0;
    integer     i;
    initial for (i = 0; i < 8; i = i + 1) begin vp[i] = 0; ve[i] = 0; vs[i] = ST_OFF; vl[i] = 15'd1; end
    wire [7:0] sounding = { vs[7] != 0, vs[6] != 0, vs[5] != 0, vs[4] != 0,
                            vs[3] != 0, vs[2] != 0, vs[1] != 0, vs[0] != 0 };

    // active voice registers: 64 words in byte lanes, written by the drain, read by the voices
    reg [7:0] ar0 [0:63], ar1 [0:63], ar2 [0:63], ar3 [0:63];
    reg [5:0]  ar_ra;
    reg [31:0] ar_q;
    // wave RAM: 8192 words in byte lanes
    reg [7:0] wv0 [0:8191], wv1 [0:8191], wv2 [0:8191], wv3 [0:8191];
    reg [14:0] wv_ra;
    reg [7:0]  wv_q, wv_q0, wv_q1, wv_q2, wv_q3;
    reg [1:0]  wv_ln;

    // ------------------------------------------------------------
    // The sequencer

    localparam [1:0] S_IDLE = 2'd0, S_DRAIN = 2'd1, S_VOICE = 2'd2, S_MIX = 2'd3;
    reg  [1:0]  st = S_IDLE;
    localparam [10:0] TICK_M1 = TICK[10:0] - 11'd1;
    reg  [10:0] tc = TICK_M1;                 // clocks to the next tick
    wire        tick = (tc == 0);
    assign tr_tick = tick;
    assign tr_busy = (st != S_IDLE);
    reg  [10:0] dn = 0;                       // queue entries left to apply this tick
    reg         dph = 0;                      // drain: 0 read the head, 1 apply it
    reg  [49:0] q_q;
    reg  [2:0]  v = 0;                        // the voice
    reg  [3:0]  k = 0;                        // its step, 0-11
    assign deq = (st == S_DRAIN) && dph;

    // the drained write
    wire [15:0] d_off = { q_q[49:36], 2'b00 };
    wire [3:0]  d_s   = q_q[35:32];
    wire [31:0] d_d   = q_q[31:0];
    wire        d_wave = d_off[15];
    wire        d_reg  = !d_off[15] && d_off[11:8] == 4'h1;
    assign tr_apply = deq; assign tr_apply_a = d_off; assign tr_apply_s = d_s; assign tr_apply_d = d_d;
    always @(posedge clk) begin
        if (deq && d_wave && d_s[0]) wv0[d_off[14:2]] <= d_d[7:0];
        if (deq && d_wave && d_s[1]) wv1[d_off[14:2]] <= d_d[15:8];
        if (deq && d_wave && d_s[2]) wv2[d_off[14:2]] <= d_d[23:16];
        if (deq && d_wave && d_s[3]) wv3[d_off[14:2]] <= d_d[31:24];
        // each lane's read registered on its own (so each maps to block RAM), the lane chosen after
        wv_q0 <= wv0[wv_ra[14:2]];
        wv_q1 <= wv1[wv_ra[14:2]];
        wv_q2 <= wv2[wv_ra[14:2]];
        wv_q3 <= wv3[wv_ra[14:2]];
        wv_ln <= wv_ra[1:0];
    end
    always @(*)
        case (wv_ln)
            2'd0: wv_q = wv_q0;
            2'd1: wv_q = wv_q1;
            2'd2: wv_q = wv_q2;
            default: wv_q = wv_q3;
        endcase
    always @(posedge clk) begin
        if (deq && d_reg && d_s[0]) ar0[d_off[7:2]] <= d_d[7:0];
        if (deq && d_reg && d_s[1]) ar1[d_off[7:2]] <= d_d[15:8];
        if (deq && d_reg && d_s[2]) ar2[d_off[7:2]] <= d_d[23:16];
        if (deq && d_reg && d_s[3]) ar3[d_off[7:2]] <= d_d[31:24];
        ar_q <= { ar3[ar_ra], ar2[ar_ra], ar1[ar_ra], ar0[ar_ra] };
    end

    // the voice being computed: its registers as they arrive (masked as sw/apu/apu.h says)
    reg  [9:0]  r_mode;
    reg  [15:0] r_pitch, r_vol, r_end;
    reg  [31:0] r_adsr;
    reg  [14:0] r_start, r_loop;
    wire [26:0] c_p  = vp[v];
    wire [15:0] c_e  = ve[v];
    wire [2:0]  c_s  = vs[v];
    wire [14:0] c_l  = vl[v];
    wire [4:0]  c_step = c_p[18:14];
    wire [2:0]  c_m  = r_mode[2:0];

    // w: the voice's wave value this tick
    reg signed [8:0] c_w;
    always @(*) begin
        case (c_m)
            3'd1: case (r_mode[5:4])
                      2'd0: c_w = (c_step < 5'd4)  ? 9'sd96 : -9'sd96;
                      2'd1: c_w = (c_step < 5'd8)  ? 9'sd96 : -9'sd96;
                      2'd2: c_w = (c_step < 5'd16) ? 9'sd96 : -9'sd96;
                      default: c_w = (c_step < 5'd24) ? 9'sd96 : -9'sd96;
                  endcase
            3'd2: c_w = $signed({1'b0, (c_step[4] ? 4'd15 - c_step[3:0] : c_step[3:0]), 4'b0}) - 9'sd120;
            3'd3: c_w = c_l[0] ? 9'sd96 : -9'sd96;
            3'd4: c_w = $signed({wv_q[7], wv_q});
            default: c_w = 9'sd0;
        endcase
    end

    // the advance
    wire [27:0] t_sum  = { 1'b0, c_p } + { 12'b0, r_pitch };
    wire [26:0] t_tone = { 8'b0, t_sum[18:0] };
    wire [2:0]  t_n    = t_sum[16:14] - c_p[16:14];   // 2^14 crossings (0-4; the difference of the
                                                     // full quotients, which differ by < 8)
    function [14:0] lstep (input [14:0] l, input sh);
        lstep = { l[0] ^ (sh ? l[6] : l[1]), l[14:1] };
    endfunction
    wire [14:0] t_l1 = lstep (c_l,  r_mode[8]);
    wire [14:0] t_l2 = lstep (t_l1, r_mode[8]);
    wire [14:0] t_l3 = lstep (t_l2, r_mode[8]);
    wire [14:0] t_l4 = lstep (t_l3, r_mode[8]);
    wire [14:0] t_lf = (t_n == 3'd0) ? c_l : (t_n == 3'd1) ? t_l1 : (t_n == 3'd2) ? t_l2
                     : (t_n == 3'd3) ? t_l3 : t_l4;
    wire [26:0] s_np   = t_sum[26:0];
    wire [16:0] s_a    = { 2'b0, r_start } + { 2'b0, s_np[26:12] };
    wire        s_past = s_a >= { 1'b0, r_end };
    wire [15:0] s_back = r_end - { 1'b0, r_loop };
    wire [14:0] s_lp   = s_np[26:12] - s_back[14:0];
    wire        s_stop = (c_m == 3'd4) && s_past && !r_mode[9];
    wire [26:0] n_p    = (c_m != 3'd4) ? t_tone : ((s_past && r_mode[9]) ? { s_lp, s_np[11:0] } : s_np);
    // the envelope
    wire [7:0]  e_A = r_adsr[7:0], e_D = r_adsr[15:8], e_S = r_adsr[23:16], e_R = r_adsr[31:24];
    wire [16:0] e_up = { 1'b0, c_e } + { 9'b0, e_A };
    reg  [15:0] n_e;
    reg  [2:0]  n_s;
    always @(*) begin
        n_e = c_e; n_s = c_s;
        case (c_s)
            ST_ATTACK: begin
                n_e = (e_A == 0 || e_up >= 17'h0FFFF) ? 16'hFFFF : e_up[15:0];
                if (n_e == 16'hFFFF) n_s = ST_DECAY;
            end
            ST_DECAY:
                if (e_D == 0) n_s = ST_SUSTAIN;
                else if (c_e < { 8'b0, e_D } || c_e - { 8'b0, e_D } <= { e_S, 8'b0 }) begin
                    n_e = { e_S, 8'b0 }; n_s = ST_SUSTAIN;
                end else n_e = c_e - { 8'b0, e_D };
            ST_RELEASE:
                if (e_R == 0 || c_e <= { 8'b0, e_R }) begin n_e = 16'd0; n_s = ST_OFF; end
                else n_e = c_e - { 8'b0, e_R };
            default: ;
        endcase
    end

    // products and sums
    reg  signed [16:0] m_e;                 // w * level
    reg  signed [24:0] m_l, m_r;            // e * VOL
    reg  signed [19:0] acc_l, acc_r;
    wire signed [24:0] sh_l = m_l >>> 8, sh_r = m_r >>> 8;
    wire signed [19:0] add_l = sh_l[19:0], add_r = sh_r[19:0];   // |l| < 2^15
    wire signed [27:0] mix_l = acc_l * $signed({1'b0, master});
    wire signed [27:0] mix_r = acc_r * $signed({1'b0, master});
    function signed [15:0] sat16 (input signed [27:0] x);
        sat16 = (x > 28'sd32767) ? 16'sh7FFF : (x < -28'sd32768) ? 16'sh8000 : x[15:0];
    endfunction

    always @(posedge clk) begin
        tr_done <= 1'b0;
        if (rst) begin
            pend <= 0; rb_ack <= 0; rb_rdata <= 0;
            ctrl_sh <= 0; master_sh <= 8'd64;
            wp <= 0; rp <= 0; level <= 0;
            ctrl <= 0; master <= 8'd64; ticks <= 0;
            st <= S_IDLE; tc <= TICK_M1; dn <= 0; dph <= 0; v <= 0; k <= 0;
            out_l <= 0; out_r <= 0;
            for (i = 0; i < 8; i = i + 1) begin vp[i] <= 0; ve[i] <= 0; vs[i] <= ST_OFF; vl[i] <= 15'd1; end
        end else begin
            // ---- the bus
            rb_ack <= 1'b0;
            if (take) begin
                pend <= 1'b1; pend_we <= rb_we; pend_a <= a;
                if (rb_we && !a[15] && a[11:2] == 10'h001 && rb_wstrb[0]) ctrl_sh <= rb_wdata[0];
                if (rb_we && !a[15] && a[11:2] == 10'h002 && rb_wstrb[0]) master_sh <= rb_wdata[7:0];
            end
            if (enq) wp <= wp + 10'd1;
            if (deq) rp <= rp + 10'd1;
            level <= level + (enq ? 11'd1 : 11'd0) - (deq ? 11'd1 : 11'd0);
            if (pend) begin
                pend <= 1'b0; rb_ack <= 1'b1; rb_rdata <= 32'd0;
                if (!pend_we && !pend_a[15]) begin
                    if (pend_a[11:8] == 4'h1)
                        case (pend_a[4:2])
                            3'd0: rb_rdata <= sh_q & 32'h0000_0337;
                            3'd1, 3'd2: rb_rdata <= sh_q & 32'h0000_FFFF;
                            3'd3: rb_rdata <= sh_q;
                            3'd4, 3'd5: rb_rdata <= sh_q & 32'h0000_7FFF;
                            3'd6: rb_rdata <= sh_q & 32'h0000_FFFF;
                            default: rb_rdata <= { 21'b0, vs[pend_a[7:5]], ve[pend_a[7:5]][15:8] };
                        endcase
                    else if (pend_a[11:8] == 4'h0)
                        case (pend_a[7:2])
                            6'd0: rb_rdata <= 32'h31555041;               // "APU1"
                            6'd1: rb_rdata <= { 31'b0, ctrl_sh };
                            6'd2: rb_rdata <= { 24'b0, master_sh };
                            6'd3: rb_rdata <= ticks;
                            6'd4: rb_rdata <= { 8'b0, sounding, 5'b0, level };
                            default: ;
                        endcase
                end
            end

            // ---- the tick clock
            tc <= tick ? TICK_M1 : tc - 11'd1;

            // ---- the sequencer
            case (st)
                S_IDLE:
                    if (tick) begin
                        dn <= level; dph <= 1'b0; v <= 0; k <= 0;
                        st <= (level != 0) ? S_DRAIN : S_VOICE;
                        acc_l <= 0; acc_r <= 0;
                    end
                S_DRAIN: begin
                    if (!dph) begin
                        q_q <= qm[rp];
                        dph <= 1'b1;
                    end else begin
                        dph <= 1'b0;
                        dn  <= dn - 11'd1;
                        if (dn == 11'd1) st <= S_VOICE;
                        if (!d_wave && d_off[11:2] == 10'h001 && d_s[0]) ctrl   <= d_d[0];
                        if (!d_wave && d_off[11:2] == 10'h002 && d_s[0]) master <= d_d[7:0];
                        if (!d_wave && d_off[11:2] == 10'h005 && d_s[0])
                            for (i = 0; i < 8; i = i + 1)
                                if (d_d[i]) begin vp[i] <= 0; ve[i] <= 0; vs[i] <= ST_ATTACK; vl[i] <= 15'd1; end
                        if (!d_wave && d_off[11:2] == 10'h006 && d_s[0])
                            for (i = 0; i < 8; i = i + 1)
                                if (d_d[i] && vs[i] != ST_OFF) vs[i] <= ST_RELEASE;
                    end
                end
                S_VOICE: begin
                    k <= k + 4'd1;
                    // k 0-6 read registers 0-6 (each seen a clock later)
                    case (k)
                        4'd1: r_mode  <= ar_q[9:0];
                        4'd2: r_pitch <= ar_q[15:0];
                        4'd3: r_vol   <= ar_q[15:0];
                        4'd4: r_adsr  <= ar_q;
                        4'd5: r_start <= ar_q[14:0];
                        4'd6: r_loop  <= ar_q[14:0];
                        4'd7: r_end   <= ar_q[15:0];
                        default: ;
                    endcase
                    // k 8: the output product and the advance (wv_q holds the byte read at k 7)
                    if (k == 4'd8) begin
                        m_e  <= c_w * $signed({1'b0, c_e[15:8]});
                        if (c_s != ST_OFF) begin
                            vp[v] <= n_p;
                            if (c_m == 3'd3) vl[v] <= t_lf;
                            if (s_stop) begin vs[v] <= ST_OFF; ve[v] <= 16'd0; end
                            else begin vs[v] <= n_s; ve[v] <= n_e; end
                        end
                    end
                    if (k == 4'd9)  m_l <= m_e * $signed({1'b0, r_vol[7:0]});
                    if (k == 4'd10) m_r <= m_e * $signed({1'b0, r_vol[15:8]});
                    if (k == 4'd11) begin
                        acc_l <= acc_l + add_l;     // a stopped voice has E = 0: adds 0
                        acc_r <= acc_r + add_r;
                        k <= 4'd0;
                        v <= v + 3'd1;
                        if (v == 3'd7) st <= S_MIX;
                    end
                end
                S_MIX: begin
                    out_l <= ctrl ? sat16 (mix_l >>> 6) : 16'sd0;
                    out_r <= ctrl ? sat16 (mix_r >>> 6) : 16'sd0;
                    ticks <= ticks + 32'd1;
                    tr_done <= 1'b1;
                    st <= S_IDLE;
                end
            endcase
        end
    end

`ifdef APU_TRACE
    // simulation only (sim/game2d/frame_check.sh): every bus write with the tick that applies it,
    // and every sample, to apu_trace.txt (sw/apu/replay.c checks it against the reference model)
    integer     tr_f;
    reg  [31:0] tr_n = 0;                     // ticks at earlier clocks
    initial tr_f = $fopen ("apu_trace.txt", "w");
    always @(posedge clk) if (!rst) begin
        if (take && rb_we) $fdisplay (tr_f, "W %0d %04x %08x %x", tick ? tr_n + 1 : tr_n, a, rb_wdata, rb_wstrb);
        if (tick) tr_n <= tr_n + 1;
        if (tr_done) $fdisplay (tr_f, "S %0d %0d %0d", tr_n - 1, out_l, out_r);
    end
`endif

    // RAM read addresses (registered RAM outputs: the data is seen a clock later)
    always @(*) begin
        ar_ra = { v, k[2:0] };
        // the sample byte: START (arrives at k 6, r_start) plus the offset
        wv_ra = r_start + c_p[26:12];
    end
endmodule
