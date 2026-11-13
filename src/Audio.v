// ================================================================
// Audio: PCM and a tone generator on the ULX3S jack (4-bit resistor DACs, audio_l and audio_r),
// on the register bus (protocol in src/AXI4_RegBus.bsv).  Window 0xC000_9000:
//   0x00 ID      RO  0x41554431 ("AUD1")
//   0x04 CTRL    RW  [0] play the PCM FIFO  [1] tone on
//   0x08 VOLUME  RW  [3:0] 0 = mute (the reset value: it drives real headphones), 1-8 = output
//                    shifted right by 8 - VOLUME, 8 = full scale
//   0x0C RATE    RW  [15:0] clocks per PCM sample, minus 1 (reset 1133: 44.1 kHz at 50 MHz)
//   0x10 TONE    RW  [15:0] clocks per half period of the square wave, minus 1
//   0x14 FIFO    WO  one stereo sample: [15:0] left, [31:16] right, signed.  Never stalls the
//                    bus: a write to a full FIFO is dropped and counted in STATUS.DROP
//   0x18 STATUS  RO  [8:0] samples in the FIFO (0-256), [16] DROP since last write here,
//                    [17] UNDERRUN since last write here (FIFO empty at a sample time: the last
//                    sample is held)
//                W   clears both sticky bits
//   0x1C SPDIF   RW  [3:0] PINS: the jack's ring 2 DAC bits (audio_v) that carry S/PDIF, 0 = off
//                    (reset: the ring idles low); 0xF drives all four (about 0.5 V into a 75 ohm
//                    coax load).  [11:8] SFREQ, channel status byte 3 bits 0-3: 0000 44.1 kHz,
//                    0010 48 kHz, 0011 32 kHz; it should match RATE.  The stream (src/Spdif_Tx.v)
//                    carries the PCM samples as played (before VOLUME; not the tone), one frame per
//                    RATE + 1 clocks, so it keeps running, silent, while CTRL[0] is off.
//
// Each DAC is a first-order sigma-delta at the system clock: 16 bits in, the top 4 bits plus the
// carry of the 12-bit error accumulator out, so the mean level is the sample's.  The top code is
// saturated: inputs at or above 0xF000 (offset binary) clip to code 15.
// ================================================================

module audio #(
    parameter [15:0] RATE_RESET = 16'd1133   // the formal harness shortens it to reach a sample time
) (
    input  wire        clk,
    input  wire        rst,         // active high
    input  wire        rb_valid,
    input  wire        rb_we,
    input  wire [11:0] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_wstrb,
    output reg         rb_ack,
    output reg  [31:0] rb_rdata,
    output reg  [3:0]  audio_l,
    output reg  [3:0]  audio_r,
    output reg  [3:0]  audio_v
`ifdef FORMAL
    ,
    input  wire [7:0]  f_idx,       // the harness's symbolic FIFO slot
    output wire [31:0] f_slot,
    output wire [7:0]  f_wp,
    output wire [7:0]  f_rp,
    output wire [8:0]  f_level,
    output wire        f_pop,
    output wire [31:0] f_q,
    output wire [31:0] f_cur,
    output wire [11:0] f_acc_l,
    output wire [15:0] f_u_l,
    output wire [15:0] f_rate_cnt,
    output wire [15:0] f_rate,
    output wire        f_do_pop,
    output wire        f_push,
    output wire [3:0]  f_volume,
    output wire [7:0]  f_spdif
`endif
);
    reg [1:0]  ctrl;
    reg [3:0]  volume;
    reg [15:0] rate, tone;
    reg        drop, underrun;

    reg [31:0] mem [0:255];
    reg [7:0]  wp, rp;
    reg [8:0]  level;
    reg [31:0] q, cur;
    reg        pop;
    reg [15:0] rate_cnt, tone_cnt;
    reg        tone_hi;
    reg [3:0]  spdif_pins, spdif_sfreq;
    wire       spdif_out;

    wire take    = rb_valid && !rb_ack;
    wire wr      = take && rb_we && (rb_wstrb != 0);
    wire [3:0] a = rb_addr[5:2];
    wire push_rq = wr && (a == 4'd5) && (rb_wstrb == 4'hF);
    wire full    = level[8];
    wire empty   = (level == 0);
    wire push    = push_rq && !full;
    wire tick    = (rate_cnt == 0);
    wire take_s  = ctrl[0] && tick;
    wire do_pop  = take_s && !empty;

    // ---------------- sample path ----------------
    function automatic [15:0] mix (input [15:0] pcm, input [15:0] tn);
        reg signed [16:0] sum;
        begin
            sum = {pcm[15], pcm} + {tn[15], tn};
            mix = (sum[16] == sum[15]) ? sum[15:0] : (sum[16] ? 16'h8000 : 16'h7FFF);
        end
    endfunction
    function automatic [15:0] scale (input [15:0] v, input [3:0] vol);
        scale = (vol == 0)  ? 16'd0 :
                (vol >= 8)  ? v     :
                              $signed(v) >>> (4'd8 - vol);
    endfunction
    wire [15:0] tone_s = !ctrl[1] ? 16'd0 : (tone_hi ? 16'h4000 : 16'hC000);
    wire [15:0] pcm_l  = ctrl[0] ? cur[15:0]  : 16'd0;
    wire [15:0] pcm_r  = ctrl[0] ? cur[31:16] : 16'd0;
    // registered: the cone from the sample registers ends here, ahead of the accumulators
    reg  [15:0] u_l, u_r;      // offset binary: 0x8000 is silence
    reg  [11:0] acc_l, acc_r;
    wire [12:0] nx_l = {1'b0, acc_l} + {1'b0, u_l[11:0]};
    wire [12:0] nx_r = {1'b0, acc_r} + {1'b0, u_r[11:0]};

    always @(posedge clk) begin
        // the block RAM: read-first, so a slot written now is seen a cycle later
        q <= mem[rp];
        if (push) mem[wp] <= rb_wdata;
    end

    always @(posedge clk) begin
        rb_ack <= 1'b0;
        if (take) begin
            rb_ack   <= 1'b1;
            rb_rdata <= 32'b0;
            if (!rb_we)
                case (a)
                    4'd0: rb_rdata <= 32'h41554431;
                    4'd1: rb_rdata <= {30'b0, ctrl};
                    4'd2: rb_rdata <= {28'b0, volume};
                    4'd3: rb_rdata <= {16'b0, rate};
                    4'd4: rb_rdata <= {16'b0, tone};
                    4'd6: rb_rdata <= {14'b0, underrun, drop, 7'b0, level};
                    4'd7: rb_rdata <= {20'b0, spdif_sfreq, 4'b0, spdif_pins};
                    default: ;
                endcase
        end
        if (wr)
            case (a)
                4'd1: ctrl   <= rb_wdata[1:0];
                4'd2: volume <= rb_wdata[3:0];
                4'd3: rate   <= rb_wdata[15:0];
                4'd4: tone   <= rb_wdata[15:0];
                4'd7: begin spdif_pins <= rb_wdata[3:0]; spdif_sfreq <= rb_wdata[11:8]; end
                default: ;
            endcase

        // FIFO
        if (push) wp <= wp + 8'd1;
        if (do_pop) rp <= rp + 8'd1;
        if (push && !do_pop) level <= level + 9'd1;
        if (!push && do_pop) level <= level - 9'd1;
        pop <= do_pop;
        if (pop) cur <= q;

        // sticky bits: a set on the same clock as the clear wins
        if (wr && (a == 4'd6)) begin drop <= 1'b0; underrun <= 1'b0; end
        if (push_rq && full)     drop <= 1'b1;
        if (take_s && empty)     underrun <= 1'b1;

        // timebases
        rate_cnt <= tick ? rate : rate_cnt - 16'd1;
        if (tone_cnt == 0) begin tone_cnt <= tone; tone_hi <= !tone_hi; end
        else tone_cnt <= tone_cnt - 16'd1;

        // DACs
        u_l <= scale (mix (pcm_l, tone_s), volume) ^ 16'h8000;
        u_r <= scale (mix (pcm_r, tone_s), volume) ^ 16'h8000;
        acc_l <= nx_l[11:0];
        acc_r <= nx_r[11:0];
        audio_l <= (u_l[15:12] == 4'hF) ? 4'hF : u_l[15:12] + {3'b0, nx_l[12]};
        audio_r <= (u_r[15:12] == 4'hF) ? 4'hF : u_r[15:12] + {3'b0, nx_r[12]};
        audio_v <= spdif_pins & {4{spdif_out}};

        if (rst) begin
            rb_ack   <= 1'b0;
            rb_rdata <= 32'b0;
            ctrl     <= 2'b0;
            volume   <= 4'd0;
            rate     <= RATE_RESET;
            tone     <= 16'd28408;      // 440 Hz at 50 MHz
            drop     <= 1'b0;
            underrun <= 1'b0;
            wp <= 8'd0; rp <= 8'd0; level <= 9'd0;
            cur <= 32'd0;
            pop <= 1'b0;
            rate_cnt <= RATE_RESET;
            tone_cnt <= 16'd28408;
            tone_hi  <= 1'b0;
            u_l <= 16'h8000; u_r <= 16'h8000;
            acc_l <= 12'd0; acc_r <= 12'd0;
            audio_l <= 4'h8; audio_r <= 4'h8;
            audio_v <= 4'h0;
            spdif_pins <= 4'h0; spdif_sfreq <= 4'h0;
        end
    end

    spdif_tx spdif (
        .clk(clk), .rst(rst), .en(spdif_pins != 4'h0), .tick(tick), .period({1'b0, rate} + 17'd1),
        .left(pcm_l), .right(pcm_r), .sfreq(spdif_sfreq), .out(spdif_out)
    );

`ifdef FORMAL
    assign f_slot = mem[f_idx];
    assign f_wp = wp;
    assign f_rp = rp;
    assign f_level = level;
    assign f_pop = pop;
    assign f_q = q;
    assign f_cur = cur;
    assign f_acc_l = acc_l;
    assign f_u_l = u_l;
    assign f_rate_cnt = rate_cnt;
    assign f_rate = rate;
    assign f_do_pop = do_pop;
    assign f_push = push;
    assign f_volume = volume;
    assign f_spdif = {spdif_sfreq, spdif_pins};
`endif
endmodule
