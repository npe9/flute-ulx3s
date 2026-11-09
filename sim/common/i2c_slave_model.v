// i2c_slave_model: the board's I2C bus for benches, clocked so it builds under Verilator as well.
// At 0x6F the MCP7940N registers (register 0 = seconds in BCD, bit 7 = ST; while ST is set it counts
// every TICK clocks, much faster than a real second so benches finish), at 0x50 a 128-byte EDID
// with a valid header and checksum.  Open-drain: sda_low = 1 pulls the line low.
module i2c_slave_model #(parameter TICK = 200000) (
    input  wire clk,
    input  wire scl,
    input  wire sda,
    output reg  sda_low
);
    reg [7:0] rtc [0:31];
    reg [7:0] edid [0:127];
    integer i, sum;
    initial begin
        sda_low = 0;
        for (i = 0; i < 32; i = i + 1) rtc[i] = 8'h00;
        for (i = 0; i < 128; i = i + 1) edid[i] = (i * 7) & 8'hFF;
        edid[0] = 8'h00;
        for (i = 1; i < 7; i = i + 1) edid[i] = 8'hFF;
        edid[7] = 8'h00;
        sum = 0;
        for (i = 0; i < 127; i = i + 1) sum = sum + edid[i];
        edid[127] = (256 - (sum & 255)) & 255;
    end

    reg scl_q = 1, sda_q = 1;
    reg active = 0, rw = 0, addressed = 0, is_rtc = 0, have_ptr = 0, in_ack = 0, sending = 0;
    reg [7:0] sr = 0, tx = 0, ptr = 0;
    reg [3:0] n = 0;
    integer ticker = 0;
    wire [7:0] rd_val = is_rtc ? rtc[ptr[4:0]] : edid[ptr[6:0]];
    wire [3:0] s_lo = rtc[0][3:0];
    wire [2:0] s_hi = rtc[0][6:4];

    always @(posedge clk) begin
        scl_q <= scl;
        sda_q <= sda;
        ticker = ticker + 1;
        if (ticker >= TICK) begin
            ticker = 0;
            if (rtc[0][7]) rtc[0] <= (s_lo == 9) ? {1'b1, (s_hi == 5) ? 3'd0 : s_hi + 3'd1, 4'd0}
                                                 : {1'b1, s_hi, s_lo + 4'd1};
        end
        if (scl && scl_q && sda_q && !sda) begin            // START
            active = 1; n = 0; addressed = 0; have_ptr = 0; in_ack = 0; sending = 0; sda_low <= 0;
        end
        else if (scl && scl_q && !sda_q && sda) begin       // STOP
            active = 0; sda_low <= 0;
        end
        else if (active && scl && !scl_q) begin             // SCL rises
            if (in_ack) begin
                if (sending && sda) begin active = 0; sda_low <= 0; end    // no ack: the read is over
            end
            else begin
                if (!sending) sr = {sr[6:0], sda};
                n = n + 1;
            end
        end
        else if (active && !scl && scl_q) begin             // SCL falls
            if (in_ack) begin
                in_ack = 0; n = 0; sda_low <= 0;
                if (sending) begin tx = rd_val; ptr = ptr + 1; sda_low <= !tx[7]; end
            end
            else if (n == 8) begin
                in_ack = 1;
                if (!addressed) begin
                    if (sr[7:1] == 7'h6F || sr[7:1] == 7'h50) begin
                        addressed = 1; is_rtc = (sr[7:1] == 7'h6F); rw = sr[0]; sending = sr[0];
                        sda_low <= 1;
                    end
                    else begin active = 0; in_ack = 0; sda_low <= 0; end   // nobody there: no ack
                end
                else if (!rw) begin
                    if (!have_ptr) begin ptr = sr; have_ptr = 1; end
                    else begin if (is_rtc) rtc[ptr[4:0]] <= sr; ptr = ptr + 1; end
                    sda_low <= 1;
                end
                else sda_low <= 0;                          // released for the master's ack
            end
            else if (sending) sda_low <= !tx[3'd7 - n[2:0]];
        end
    end
endmodule
