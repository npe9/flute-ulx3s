// a_conc_seq.sv — temporal concurrent assertions with ## delays.
// Probed under --no-timing first (expect compile rejection), then
// under --timing (documents what the F1 harness would need).
module tb_top (input logic clk);
  logic req = 1'b0;
  logic gnt = 1'b0;
  int cycle = 0;

  always @(posedge clk) begin
    cycle <= cycle + 1;
    req <= (cycle == 3);
    gnt <= (cycle == 5);   // two cycles later
  end

  a_eventual: assert property (@(posedge clk) req |-> ##[1:3] gnt)
    else $error("no gnt within 3 cycles");
  a_gnt_stays: assert property (@(posedge clk) gnt |=> gnt [*1] ##1 !gnt)
    else $error("gnt shape");
endmodule
