// sd_rd_card: SD bus VIP, card side of a read data block (SD Physical Layer spec 4.11: data
// token).  Starts at a falling CLK when told (go), then on each falling edge drives the next bit:
// start 0, the data (1-bit: MSB first on DAT0; 4-bit: high nibble first on DAT3..0), 16 CRC bits per
// line and an end bit per line -- both given, so a checker can send good or bad ones -- then
// returns to idle.  Lines the host does not read (DAT1-3 in 1-bit mode, DAT1-3 while idle) carry
// free values.  p counts the bits driven so far (0 = not started, T+1 = finished).
`default_nettype none
module sd_rd_card #(parameter NB = 4) (      // block size in bytes
    input  wire           clk,
    input  wire           rst,
    input  wire           en,               // native SD mode on these pins
    input  wire           sck,
    input  wire           wide,             // 4-bit bus
    input  wire           go,               // start the block at this falling edge
    input  wire [8*NB-1:0] data,            // byte 0 (first on the wire) in bits 7:0
    input  wire [63:0]    crc,              // the CRC sent on DAT l in bits 16l+15:16l
    input  wire [3:0]     endb,             // the end bit sent on each line
    input  wire [3:0]     free,             // values for the lines not in use
    output reg  [3:0]     dat,
    output reg  [12:0]    p = 13'd0,
    output reg            sck_q,
    output wire           fell
);
    wire [12:0] D = wide ? 13'd2 * NB : 13'd8 * NB;   // data clocks
    wire [12:0] T = D + 13'd18;                       // start + data + CRC + end
    assign fell = en && sck_q && !sck;
    always @(posedge clk) begin
        sck_q <= sck;
        if (rst) p <= 13'd0;
        else if (fell) begin
            if (p == 13'd0) begin if (go) p <= 13'd1; end
            else if (p <= T) p <= p + 13'd1;
        end
    end
    // the bit on line l at position p (1 = start bit)
    function automatic lbit (input [12:0] pp, input integer l);
        reg [12:0] i;
        begin
            if (pp == 13'd1) lbit = 1'b0;
            else if (pp <= D + 13'd1) begin
                i = pp - 13'd2;
                lbit = wide ? data[8 * (i >> 1) + (i[0] ? 0 : 4) + l]
                            : data[8 * (i >> 3) + 7 - i[2:0]];
            end else if (pp <= D + 13'd17) lbit = crc[16 * l + 15 - (pp - D - 13'd2)];
            else lbit = endb[l];
        end
    endfunction
    always @(*) begin
        dat = {free[3:1], 1'b1};
        if (p != 13'd0 && p <= T) begin
            dat[0] = lbit (p, 0);
            if (wide) dat[3:1] = {lbit (p, 3), lbit (p, 2), lbit (p, 1)};
        end
    end
endmodule
