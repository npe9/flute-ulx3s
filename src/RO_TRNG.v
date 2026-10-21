// RO_TRNG: raw noise bit for the Zkr entropy source (Entropy_Source.bsv, mkEntropy_Source_RO).
//
// Synthesis (ECP5): 8 free-running inverter rings of distinct odd lengths (3..17 stages), each an
// explicit LUT4 inverter chain kept by (* keep *) so yosys cannot fold the loop. Each ring is
// sampled by the core clock through two flops (the first may go metastable -- that is the noise),
// and the eight samples are XORed into one registered raw bit per clock. nextpnr needs
// --ignore-loops for the rings. Health tests, decimation and OPST live in the BSV wrapper.
//
// In simulation and formal the rings cannot be modelled, so a 32-bit Galois LFSR stands in behind the same
// port (deterministic; passes the health tests; NOT entropy).
module RO_TRNG (input CLK, input RST_N, output BIT);
`ifdef VERILATOR
   reg [31:0] lfsr;
   always @(posedge CLK)
      if (!RST_N) lfsr <= 32'hACE1_2468;
      else        lfsr <= {1'b0, lfsr[31:1]} ^ (lfsr[0] ? 32'hA300_0001 : 32'h0);
   assign BIT = lfsr[0];
`elsif FORMAL
   (* anyseq *) wire noise;
   assign BIT = noise;
`else
   wire [7:0] ring_out;
   genvar r;
   generate
      for (r = 0; r < 8; r = r + 1) begin : g_ring
         localparam integer N = 3 + 2 * r;          // 3, 5, ..., 17 stages
         (* keep *) wire [N-1:0] w;
         genvar s;
         for (s = 0; s < N; s = s + 1) begin : g_stage
            (* keep *) LUT4 #(.INIT(16'h5555)) inv (   // Z = ~A
               .A(w[(s + N - 1) % N]), .B(1'b0), .C(1'b0), .D(1'b0), .Z(w[s]));
         end
         assign ring_out[r] = w[N-1];
      end
   endgenerate
   (* keep *) reg [7:0] s1;
   (* keep *) reg [7:0] s2;
   reg bit_q;
   always @(posedge CLK) begin
      s1    <= ring_out;
      s2    <= s1;
      bit_q <= ^s2;
   end
   assign BIT = bit_q;
`endif
endmodule
