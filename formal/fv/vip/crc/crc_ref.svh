// crc_ref.svh: reference CRCs by polynomial long division (the RTL uses LFSR steps).  `include
// inside a module.  MSB-first message, zero initial value, no final XOR (SD CRC7/CRC16).
function automatic [6:0] crc7_ld40 (input [39:0] d);          // x^7 + x^3 + 1
    reg [46:0] m; integer i;
    begin
        m = {d, 7'b0};
        for (i = 46; i >= 7; i = i - 1) if (m[i]) m[i -: 8] = m[i -: 8] ^ 8'h89;
        crc7_ld40 = m[6:0];
    end
endfunction
function automatic [6:0] crc7_ld120 (input [119:0] d);
    reg [126:0] m; integer i;
    begin
        m = {d, 7'b0};
        for (i = 126; i >= 7; i = i - 1) if (m[i]) m[i -: 8] = m[i -: 8] ^ 8'h89;
        crc7_ld120 = m[6:0];
    end
endfunction
function automatic [15:0] crc16_ld8 (input [7:0] d);          // x^16 + x^12 + x^5 + 1
    reg [23:0] m; integer i;
    begin
        m = {d, 16'b0};
        for (i = 23; i >= 16; i = i - 1) if (m[i]) m[i -: 17] = m[i -: 17] ^ 17'h11021;
        crc16_ld8 = m[15:0];
    end
endfunction
function automatic [15:0] crc16_ld32 (input [31:0] d);
    reg [47:0] m; integer i;
    begin
        m = {d, 16'b0};
        for (i = 47; i >= 16; i = i - 1) if (m[i]) m[i -: 17] = m[i -: 17] ^ 17'h11021;
        crc16_ld32 = m[15:0];
    end
endfunction
