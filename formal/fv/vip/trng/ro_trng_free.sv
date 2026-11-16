// ro_trng_free: formal/fv's stand-in for src/RO_TRNG.v (whose rings cannot be modelled).  The raw
// bit is free on every clock; checkers constrain it (or not) through the DUT's tr_raw trace port.
// The ring structure itself is checked on the shipped netlist (formal/fv/bin/ro_trng_netlist.py).
`default_nettype none
module RO_TRNG (input wire CLK, input wire RST_N, output wire BIT);
    (* anyseq *) wire noise;
    assign BIT = noise;
endmodule
`default_nettype wire
