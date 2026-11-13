// spdif_wb: the checker for src/Spdif_Tx.v, bound into the DUT (no RTL changes).
//   Environment (port-level assumptions): the audio block's tick comes every PERIOD clocks
//   (128 <= PERIOD <= 1200, constant), SFREQ constant.
//   Checks (fvgen -D): (none) EN held high: the output is IEC 60958 (vip/spdif/iec60958_mon);
//   CHK_EN, EN free: the output is low in the clock after EN is low.
// The second port group names DUT internals; they appear only in the INVARIANTS section.
`default_nettype none
module spdif_wb (
    input wire        clk, rst, en, tick,
    input wire [16:0] period,
    input wire [15:0] left, right,
    input wire [3:0]  sfreq,
    input wire        out,
    // internals (induction only)
    input wire [6:0]  cidx,
    input wire [16:0] acc,
    input wire [7:0]  frame,
    input wire [15:0] l_q, r_q,
    input wire        base, par
);
    // ---------------- environment ----------------
    reg [3:0] sf_q; reg [16:0] p_q; reg up = 1'b0;
    always @(posedge clk) begin sf_q <= sfreq; p_q <= period; up <= !rst; end
    always @(*) begin
        assume (period >= 17'd128 && period <= 17'd1200);
        if (up) assume (period == p_q && sfreq == sf_q);
    end

`ifdef CHK_EN
    reg en_q = 1'b1;
    always @(posedge clk) en_q <= en;
    always @(*) if (!rst && !en_q) assert (!out);
`else
    wire started, step, hbase, hpar, prev, prev2; wire [16:0] kc; wire [6:0] hc; wire [15:0] hl, hr;
    wire [7:0] hfr;
    always @(*) assume (en);
    always @(*) if (!rst) assume (tick == (kc == period - 17'd1));
    iec60958_mon mon (.clk(clk), .rst(rst), .tick(tick), .period(period), .left(left), .right(right),
        .sfreq(sfreq), .out(out), .started(started), .kc(kc), .hc(hc), .hl(hl), .hr(hr), .hfr(hfr),
        .hbase(hbase), .hpar(hpar), .prev(prev), .prev2(prev2), .step(step));

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
    wire [4:0] slot = hc[5:1];
    wire       t    = (out != prev);
    always @(*) if (!rst) begin
        assert (kc < period);
        if (!started) assert (cidx == 7'd127 && frame == 8'd191 && hc == 7'd127 && !prev);
        else begin
            assert (hc == cidx);
            assert ({7'd0, cidx} * {7'd0, period} + {7'd0, acc} == 24'd128 * {7'd0, kc});
            assert (acc < period);
            assert (hl == l_q && hr == r_q && hfr == frame && frame <= 8'd191 && hbase == base);
            // the transmitter counts a slot's bit on entering its second half, the decoder on leaving it
            assert (par == ((hc[0] && slot >= 5'd4 && slot <= 5'd30) ? hpar ^ t : hpar));
        end
    end
`endif
endmodule

bind spdif_tx spdif_wb wb (
    .clk(clk), .rst(rst), .en(en), .tick(tick), .period(period), .left(left), .right(right),
    .sfreq(sfreq), .out(out),
    .cidx(cidx), .acc(acc), .frame(frame), .l_q(l_q), .r_q(r_q), .base(base), .par(par));
