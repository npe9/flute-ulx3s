// randsequence secondary probe
module tb_top;
  int n_a = 0, n_b = 0;
  initial begin
    for (int i = 0; i < 100; i++) begin
      randsequence (main)
        main: A | B ;
        A : { n_a++; } ;
        B : { n_b++; } ;
      endsequence
    end
    $display("RANDSEQ a=%0d b=%0d", n_a, n_b);
    $finish;
  end
endmodule
