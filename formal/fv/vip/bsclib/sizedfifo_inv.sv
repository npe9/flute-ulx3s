// sizedfifo_inv: the refinement invariant of bsc's library SizedFIFO (a ring arr[0..DEPTH-2] behind
// an output register D_OUT) against a checker's in-order model queue (vip/common/fv_queue: its count
// n and entries ents, head first).  For a checker's INVARIANTS section: the FIFO's internals come in
// through taps (flatten + connect), since a bind cannot name a library submodule's registers.
//   hasodata == (n != 0), D_OUT == the model head; the ring holds the model's entries 1..n-1 from
//   head, in order; ring_empty, not_ring_full and the pointers are consistent with that count.
// en: the user's assertion enable (out of reset).
`default_nettype none
module sizedfifo_inv #(parameter integer W = 8, parameter integer DEPTH = 4, parameter integer CW = 2,
                       parameter integer D = 4) (
    input wire                   en,
    input wire                   hasodata, ring_empty, not_ring_full,
    input wire [CW-1:0]          head, tail,
    input wire [W*(DEPTH-1)-1:0] arr,              // word i at [W*i +: W]
    input wire [W-1:0]           dout,
    input wire [3:0]             n, input wire [W*D-1:0] ents
);
    localparam integer R = DEPTH - 1;
    wire [CW:0] h = {1'b0, head}, tl = {1'b0, tail};
    wire [CW:0] rcnt = ring_empty ? 0 : (tl > h ? tl - h : tl + R - h);
    integer i;
    always @(*) begin i = 0; if (en) begin
        assert (h < R && tl < R);
        assert (ring_empty == (rcnt == 0) && (!ring_empty || h == tl));
        assert (not_ring_full == (rcnt != R));
        assert (hasodata || ring_empty);
        assert ({3'b0, rcnt} + (hasodata ? 1 : 0) == n);
        if (hasodata) assert (dout == ents[0 +: W]);
        for (i = 0; i < R; i = i + 1)
            if (i < rcnt && i + 1 < D) assert (arr[W*((h + i) % R) +: W] == ents[W*(i + 1) +: W]);
    end end
endmodule
`default_nettype wire
