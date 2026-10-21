// Test stand-in for src/RO_TRNG.v: the C++ driver sets the raw noise bit each clock.
module RO_TRNG (input CLK, input RST_N, output BIT);
   reg noise /*verilator public_flat_rw*/;
   initial noise = 0;
   assign BIT = noise;
endmodule
