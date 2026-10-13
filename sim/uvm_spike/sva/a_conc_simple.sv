// a_conc_simple.sv — clocked concurrent assertions, simple boolean and
// overlap implication only (no ## delays). Needs --assert at verilation.
module tb_top (input logic clk);
  logic req = 1'b0;
  logic gnt_ok = 1'b0;    // gnt same-cycle: property holds
  logic gnt_bad = 1'b0;   // gnt one cycle late: property fails once
  int cycle = 0;

  always @(posedge clk) begin
    cycle <= cycle + 1;
    if (cycle == 3) begin
      req     <= 1'b1;
      gnt_ok  <= 1'b1;
      gnt_bad <= 1'b0;   // arrives cycle 4 -> too late
    end else begin
      req     <= 1'b0;
      gnt_ok  <= 1'b0;
      gnt_bad <= 1'b1;
    end
  end

  // tier 1: pure boolean concurrent assertion (must hold every cycle)
  a_no_x: assert property (@(posedge clk) !$isunknown({req, gnt_ok}))
    else $error("X on req/gnt at cycle %0d", cycle);

  // tier 2: overlap implication (same-cycle consequent, no ## delays)
  a_hold: assert property (@(posedge clk) req |-> gnt_ok)
    else $error("HOLD property violated at cycle %0d", cycle);

  // tier 3: the same property against the late grant — fails by design
  a_fail: assert property (@(posedge clk) req |-> gnt_bad)
    else $error("FAIL property violated at cycle %0d (expected once)", cycle);

  // tier 4: cover property (does it count?)
  c_hold: cover property (@(posedge clk) req ##0 gnt_ok);

  final begin
    $display("[tb] cycles=%0d", cycle);
  end
endmodule
