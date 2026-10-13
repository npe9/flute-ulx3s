// randcase secondary probe
module tb_top;
  int cnt[3] = '{0, 0, 0};
  initial begin
    for (int i = 0; i < 3000; i++) begin
      randcase
        5: cnt[0]++;
        3: cnt[1]++;
        2: cnt[2]++;
      endcase
    end
    $display("RANDCASE cnt=%0d,%0d,%0d", cnt[0], cnt[1], cnt[2]);
    $finish;
  end
endmodule
