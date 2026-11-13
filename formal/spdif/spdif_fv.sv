`default_nettype none
// formal/spdif: src/Spdif_Tx.v against an independent biphase-mark decoder.
//   assumed: the audio block's tick, every PERIOD clocks (PERIOD >= 128, constant); EN held after
//            reset (EN = 0 is checked on its own: output low); SFREQ constant
//   proved:  exactly 128 cells per sample period (cell * PERIOD + acc == 128 * clocks since the
//            tick); a transition at every data slot start (slots 4-31); a mid-slot transition
//            exactly for a 1, so the decoded 16-bit sample in slots 12-27 is the one latched at the
//            tick; slots 4-11, 28 (V), 29 (U) decode 0, slot 30 the channel status bit; even parity
//            over slots 4-31; preambles B (frame 0 of 192) / M / W, relative to the level before
//            them; data never holds a level for 3 cells.
module spdif_fv (input clk, input [16:0] period, input [15:0] left, input [15:0] right,
                 input [3:0] sfreq, input en_i);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst = init;

    // the tick: every PERIOD clocks
    reg [16:0] kc = 0;
    reg        started = 1'b0;
    wire       tick = !rst && (kc == period - 17'd1);
    always @(posedge clk) begin
        kc <= (rst || tick) ? 17'd0 : kc + 17'd1;
        if (tick) started <= 1'b1;
        if (rst) started <= 1'b0;
    end
    reg [3:0] sf_q;
    always @(posedge clk) begin
        assume (period >= 17'd128 && period <= 17'd1200);
        if (!init) assume (period == $past(period) && sfreq == $past(sfreq));
    end
    wire en = 1'b1;

    wire out; wire [6:0] cell; wire adv; wire [7:0] frame; wire [16:0] acc; wire [15:0] lq, rq; wire base, par;
    spdif_tx dut (.clk(clk), .rst(rst), .en(en), .tick(tick), .period(period), .left(left), .right(right),
                  .sfreq(sfreq), .out(out), .f_cell(cell), .f_adv(adv), .f_frame(frame), .f_acc(acc), .f_lq(lq), .f_rq(rq), .f_base(base), .f_par(par));

    // ---------------- the decoder ----------------
    // Steps with the transmitter: on the edge where it enters a new cell, prev takes the level of
    // the cell it leaves.  So at every clock: out = this cell's level, prev = the previous cell's.
    reg        prev, prev2;
    reg [6:0]  hc;                   // cell index, counted from the tick
    reg [15:0] hl, hr;               // samples latched at the tick
    reg [7:0]  hfr;                  // frame number in the block
    reg        hbase;                // level before the subframe's preamble
    reg        hpar;                 // parity of the decoded slots 4 .. 30 so far (this subframe)
    reg        fresh;                // first clock of a cell
    wire [4:0] slot = hc[5:1];
    wire       t    = (out != prev); // a transition into this cell
    wire       step = tick || (started && adv && hc != 7'd127);
    wire [15:0] want = hc[6] ? hr : hl;
    wire       cs   = (hfr >= 8'd24 && hfr <= 8'd27) ? sfreq[hfr[1:0]] : 1'b0;
    function automatic [7:0] pat (input right_sf, input first);
        pat = right_sf ? 8'b11100100 : (first ? 8'b11101000 : 8'b11100010);
    endfunction

    always @(posedge clk) begin
        fresh <= step;
        if (step) begin prev <= out; prev2 <= prev; end
        if (tick) begin
            hc <= 7'd0; hl <= left; hr <= right; hbase <= out; hpar <= 1'b0;
            hfr <= (!started || hfr == 8'd191) ? 8'd0 : hfr + 8'd1;
        end
        else if (step) begin
            hc <= hc + 7'd1;
            if (hc[5:0] == 6'd63) begin hbase <= out; hpar <= 1'b0; end
            // leaving the second half of slot 4-30: its transition is a data bit
            if (hc[0] && slot >= 5'd4 && slot <= 5'd30) hpar <= hpar ^ t;
        end
        if (rst) begin prev <= 1'b0; prev2 <= 1'b0; hc <= 7'd127; hfr <= 8'd0; hbase <= 1'b0; hpar <= 1'b0; fresh <= 1'b0; end
    end

    always @(posedge clk) if (!init) begin
        if (!started) assert (out == 1'b0 && cell == 7'd127 && prev == 1'b0 && frame == 8'd191 && hc == 7'd127);
        if (started) begin
            // timing: whole cells, 128 per period
            assert (hc == cell);
            assert ({7'd0, cell} * {7'd0, period} + {7'd0, acc} == 24'd128 * {7'd0, kc});
            assert (acc < period);
            assert (hl == lq && hr == rq);
            assert (hfr == frame && frame <= 8'd191);
            assert (hbase == base);
            // the transmitter counts a slot's bit on entering its second half, the decoder on leaving it
            assert (par == ((hc[0] && slot >= 5'd4 && slot <= 5'd30) ? hpar ^ t : hpar));
            if (slot < 5'd4)
                assert (out == ((pat (hc[6], hfr == 8'd0) >> (3'd7 - hc[2:0])) & 8'd1) ^ hbase);
            else if (!hc[0])
                assert (t);                                          // every slot starts with a transition
            else begin
                if (slot <= 5'd11) assert (!t);
                if (slot >= 5'd12 && slot <= 5'd27) assert (t == want[slot - 5'd12]);
                if (slot == 5'd28 || slot == 5'd29) assert (!t);
                if (slot == 5'd30) assert (t == cs);
                if (slot == 5'd31) assert (t == hpar);               // even parity over 4-31
            end
            // data never holds a level for 3 cells (the preambles do)
            if (slot >= 5'd5 || (slot == 5'd4 && hc[0])) assert (!(out == prev && prev == prev2));
        end
    end

    always @(posedge clk) if (started) cover (hc == 7'd20 && out != prev);   // into slot 10
endmodule
