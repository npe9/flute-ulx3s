// fifo2_inv: bsc's library FIFO2 is never empty and full at once (its two flag registers, reset
// to empty / not full, move together).  An unbounded proof starting from free registers (k-induction,
// or a PDR frame) needs this: an "empty and full" FIFO2 blocks its producer and offers nothing,
// a deadlock no real run reaches.  Bound into every FIFO2 instance; the user's cfg checks the bind
// took (`script = select -assert-count <n> t:fifo2_inv`).  Always an assertion (k-induction proves
// it with the rest; it is never assumed).
`default_nettype none
module fifo2_inv (input wire rst_n, input wire full_reg, input wire empty_reg);
    always @(*) if (rst_n) assert (full_reg || empty_reg);
endmodule
bind FIFO2 fifo2_inv fifo2_inv_i (.rst_n(RST), .full_reg(full_reg), .empty_reg(empty_reg));
`default_nettype wire
