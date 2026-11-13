// sd_cmd_mon: SD bus VIP, host side of CMD (SD Physical Layer spec 4.7: command token).  Samples
// the line on rising CLK while the host drives it.  Every host frame must be 48 bits: start 0,
// transmission 1, index, argument, CRC7 (checked by long division), end 1; the host releases the
// line after it (a new frame starts with a 0).  Outputs the frame for an IP-specific check.
`default_nettype none
module sd_cmd_mon (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,          // native SD mode on these pins
    input  wire        sck,
    input  wire        cmd,
    input  wire        cmd_oe,      // the host drives CMD
    output reg  [5:0]  n,           // bits of the current frame seen (0 = none)
    output reg  [47:0] sh,          // the bits so far, last in bit 0
    output wire        done,        // a whole frame has just been seen: idx, arg
    output wire [5:0]  idx,
    output wire [31:0] arg,
    output reg         sck_q        // CLK one system clock ago (for induction invariants)
);
    `include "crc_ref.svh"
    always @(posedge clk) sck_q <= sck;
    wire rise = en && sck && !sck_q;
    wire [47:0] f = {sh[46:0], cmd};
    assign done = rise && cmd_oe && n == 6'd47;
    assign idx  = f[45:40];
    assign arg  = f[39:8];
    always @(posedge clk) begin
        if (rise && cmd_oe) begin
            sh <= f;
            n  <= (n == 6'd47) ? 6'd0 : n + 6'd1;
        end
        if (rst || !en) n <= 6'd0;
    end
    always @(*) if (!rst && rise && cmd_oe) begin
        if (n == 6'd0)  assert (cmd == 1'b0);                       // start bit
        if (n == 6'd1)  assert (cmd == 1'b1);                       // transmission bit: host
        if (n == 6'd47) assert (cmd == 1'b1 && f[7:1] == crc7_ld40 (f[47:8]));   // CRC7, end bit
    end
    // the host drives the whole frame: no release in the middle
    always @(*) if (!rst && rise && n != 6'd0) assert (cmd_oe);
endmodule
