// a_imm.sv — immediate assertions, no clock, --binary --no-timing.
module tb_top;
  int n_err = 0;
  initial begin
    int x = 5;
    assert (x == 5) else begin n_err++; $error("immediate assert fired"); end
    assert (x > 100) else $display("[tb] expected-failing immediate assert observed (no $error escalation)");
    // immediate assert with $error DOES escalate: count via $error
    // behavior check below
    $display("[tb] immediate assertions compile and run under --no-timing");
    $display("IMM: DONE");
    $finish;
  end
endmodule
