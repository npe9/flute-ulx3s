// entropy_ro_env: an instance of Flute's Entropy_Source.bsv mkEntropy_Source_RO_P
// (Entropy_Source_Fv.bsv: the small instance, or the SoC's with FV_REAL) with consume free and one
// reset cycle; the raw bit comes from vip/trng/ro_trng_free.sv (free).  The checker
// (entropy_ro_wb.sv) is bound into it.
`ifndef ES_TOP
`ifdef FV_REAL
`define ES_TOP mkEntropy_Source_RO_Real
`else
`define ES_TOP mkEntropy_Source_RO_Fv
`endif
`endif
`default_nettype none
module entropy_ro_env (input wire clk, input wire consume);
    reg init = 1'b1;                           // one reset cycle (RST_N low)
    always @(posedge clk) init <= 1'b0;
    `ES_TOP dut (.CLK(clk), .RST_N(!init), .seed(), .EN_consume(consume),
        .tr_raw(), .tr_sample(), .tr_fail());
endmodule
`default_nettype wire
