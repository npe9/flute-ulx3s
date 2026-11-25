module tiny(input clk, input [7:0] a, b, output reg [15:0] q);
  reg [15:0] acc; reg [7:0] ra, rb;
  always @(posedge clk) begin ra <= a; rb <= b; acc <= acc + ra*rb; q <= acc ^ {acc[7:0], acc[15:8]}; end
endmodule
