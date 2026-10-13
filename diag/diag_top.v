module ulx3s_top(input wire CLK,input wire BTN1,output wire [7:0] led,
output wire gn0,gn1,gn2,gn3,gn4,gn5,gn6,gn7,gn8,gn9,gn10,gn11,gn12,gn13,gp0,gp1,gp2,gp3,gp4,gp5,gp6,gp7,gp8,gp9,gp10,gp11,gp12,gp13);
 wire [27:0] d = 28'b1111111111111111111111111111;
 assign {gn0,gn1,gn2,gn3,gn4,gn5,gn6,gn7,gn8,gn9,gn10,gn11,gn12,gn13,gp0,gp1,gp2,gp3,gp4,gp5,gp6,gp7,gp8,gp9,gp10,gp11,gp12,gp13} = d;
 assign led = {1'b1,3'b000, d[3:0]};
endmodule