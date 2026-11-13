// ================================================================
// Spdif_Tx: IEC 60958 (S/PDIF) consumer transmitter, locked to the audio block's sample tick.
//
// One frame (two subframes, left then right, 32 time slots each, 2 biphase-mark cells per slot:
// 128 cells) per sample period.  The cell clock is a fractional divider: every clock adds 128 to
// an accumulator and a cell ends when it reaches PERIOD (= the audio block's RATE + 1), so
// exactly 128 cells fit in one sample period, each PERIOD / 128 clocks long, give or take one
// clock (at 44.1 kHz and 50 MHz: 8.86 clocks, a 177 ns cell, 20 ns of jitter).  The tick also
// restarts the frame, so the stream cannot drift from the samples.  PERIOD must be at least 128.
//
// Subframe: slots 0-3 preamble (B at frame 0 of each 192-frame block, M other left, W right),
// 4-7 aux (0), 8-27 audio, LSB first: the 16-bit sample in 12-27 (8-11 zero), 28 V (0 =
// valid), 29 U (0), 30 C (channel status), 31 P (even parity over slots 4-31).  Channel status:
// consumer, PCM, no copy restriction asserted, all zero except byte 3 bits 0-3 = SFREQ (0000
// 44.1 kHz, 0010 48 kHz, 0011 32 kHz).
//
// Biphase mark: the level changes at every slot start, and also mid-slot for a 1.  Preambles are
// the standard 8-cell patterns given for a preceding level of 0 (B 11101000, M 11100010,
// W 11100100), inverted after a 1; they hold a level for 3 cells, which data never does.
// ================================================================

module spdif_tx (
    input  wire        clk,
    input  wire        rst,         // active high
    input  wire        en,          // 0: output held low, frame count reset
    input  wire        tick,        // one clock per sample period: a new frame starts here
    input  wire [16:0] period,      // clocks per sample period (>= 128)
    input  wire [15:0] left,        // signed samples, sampled at tick
    input  wire [15:0] right,
    input  wire [3:0]  sfreq,       // channel status byte 3 bits 0-3
    output reg         out
);
    reg [6:0]  cidx;            // 0-127: [6] subframe (0 left), [5:1] slot, [0] half
    reg [16:0] acc;
    reg [7:0]  frame;           // 0-191 within the channel status block
    reg [15:0] l_q, r_q;
    reg        base;            // the level before this subframe's preamble
    reg        par;             // parity of slots 4 .. current, this subframe

    wire [17:0] acc_n = {1'b0, acc} + 18'd128;
    wire        adv   = (acc_n >= {1'b0, period});
    wire [6:0]  nc    = cidx + 7'd1;           // the cell being entered on adv
    wire [4:0]  slot  = nc[5:1];
    wire [15:0] smp   = nc[6] ? r_q : l_q;
    wire [7:0]  fr_n  = (frame == 8'd191) ? 8'd0 : frame + 8'd1;
    wire        cbit  =(frame >= 8'd24 && frame <= 8'd27) ? sfreq[frame[1:0]] : 1'b0;

    // the data bit of a slot (4-30; 31 is the parity)
    function automatic dbit (input [4:0] s, input [15:0] v, input c);
        dbit = (s >= 5'd12 && s <= 5'd27) ? v[s - 5'd12] :
               (s == 5'd30)               ? c : 1'b0;
    endfunction

    // the preamble pattern for a preceding level of 0, cell k (0-7) of the subframe
    function automatic pre (input [2:0] k, input right_sf, input first);
        reg [7:0] p;
        begin
            p   = right_sf ? 8'b11100100 : (first ? 8'b11101000 : 8'b11100010);
            pre = p[3'd7 - k];
        end
    endfunction

    // the level of cell n, entered from level o (cell 0 of a frame: the left preamble)
    function automatic lvl (input [6:0] n, input o, input b, input pr, input [7:0] fr,
                            input [15:0] v, input c);
        reg [4:0] s;
        reg       bt;
        begin
            s  = n[5:1];
            bt = (s == 5'd31) ? pr : dbit (s, v, c);
            if (s < 5'd4)      lvl = pre (n[2:0], n[6], fr == 8'd0) ^ b;
            else if (!n[0])    lvl = !o;
            else               lvl = bt ? !o : o;
        end
    endfunction

    always @(posedge clk) begin
        if (tick) begin
            // a new frame: left preamble, cell 0
            cidx  <= 7'd0;
            acc   <= 17'd0;
            l_q   <= left;
            r_q   <= right;
            frame <= fr_n;
            base  <= out;
            par   <= 1'b0;
            out   <= pre (3'd0, 1'b0, fr_n == 8'd0) ^ out;
        end
        else if (adv && cidx != 7'd127) begin
            acc  <= acc_n[16:0] - period;
            cidx <= nc;
            if (nc[5:0] == 6'd0) begin base <= out; par <= 1'b0; end
            else if (nc[0] && slot >= 5'd4 && slot <= 5'd30) par <= par ^ dbit (slot, smp, cbit);
            out  <= lvl (nc, out, (nc[5:0] == 6'd0) ? out : base, par, frame, smp, cbit);
        end
        else
            acc <= acc_n[16:0];

        if (rst || !en) begin
            cidx  <= 7'd127;
            acc   <= 17'd0;
            frame <= 8'd191;        // the first tick starts frame 0 (B)
            base  <= 1'b0;
            par   <= 1'b0;
            out   <= 1'b0;
            l_q   <= 16'd0;
            r_q   <= 16'd0;
        end
    end

endmodule
