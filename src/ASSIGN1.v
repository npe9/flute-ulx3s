// BVI clock-domain crossing primitive used by ClockHacks.bsv.
// BSC expects this module to exist in the Verilog elaboration library.
module ASSIGN1 (
    output wire OUT,
    input  wire IN
);
    assign OUT = IN;
endmodule
