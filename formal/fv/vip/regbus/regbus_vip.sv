// regbus_vip: the SoC register bus (src/AXI4_RegBus.bsv <-> Top.v devices), in the style of the
// AXI4 FVIP: one module, the role picks which side's rules are assumed and which are asserted.
//   source (the bridge): valid held with addr/we/wdata/wstrb stable until ack, dropped the cycle
//     after ack; word-aligned addresses; no zero-strobe write.
//   destination (a device): ack exactly one cycle after a take (valid && !ack), never otherwise.
// DUT_IS_DEST=1: a device harness (source rules assumed, destination rules asserted); 0: the bridge.
// The source rules a device check assumes are asserted of src/AXI4_RegBus.bsv by formal/regbus.
// Outputs the decoded transfer for register models: a write at its take, a read at its ack.
`default_nettype none
module regbus_vip #(parameter integer DUT_IS_DEST = 1, parameter integer AW = 12) (
    input  wire          clk,
    input  wire          rst,
    input  wire          valid,
    input  wire          we,
    input  wire [AW-1:0] addr,
    input  wire [31:0]   wdata,
    input  wire [3:0]    wstrb,
    input  wire          ack,
    input  wire [31:0]   rdata,
    output wire          wr,          // a write is taken now (wr_addr/wr_data/wr_strb)
    output wire [AW-1:0] wr_addr,
    output wire [31:0]   wr_data,
    output wire [3:0]    wr_strb,
    output wire          rd,          // a read is answered now: rd_addr, rd_data
    output reg  [AW-1:0] rd_addr,
    output wire [31:0]   rd_data
);
    wire take = valid && !ack;
    reg pend = 1'b0, we_q = 1'b0, ack_q = 1'b0;
    reg [31:0] wd_q; reg [3:0] st_q; reg [AW-1:0] a_q;
    always @(posedge clk) begin
        ack_q <= ack;
        if (take) begin pend <= 1'b1; we_q <= we; a_q <= addr; wd_q <= wdata; st_q <= wstrb; rd_addr <= addr; end
        if (ack) pend <= 1'b0;
        if (rst) begin pend <= 1'b0; ack_q <= 1'b0; end
    end
    assign wr = take && we;  assign wr_addr = addr;  assign wr_data = wdata;  assign wr_strb = wstrb;
    assign rd = ack && !we_q; assign rd_data = rdata;

    // source rules
    wire s_hold   = !(pend && !ack) || (valid && addr == a_q && we == we_q && wdata == wd_q && wstrb == st_q);
    wire s_drop   = !ack_q || !valid;
    wire s_align  = !valid || addr[1:0] == 2'b00;
    wire s_strobe = !(valid && we) || wstrb != 4'h0;
    // destination rules (a one-cycle device)
    wire d_only   = !ack || pend;
    wire d_answer = !pend || ack;
    generate if (DUT_IS_DEST) begin : dest
        always @(*) if (!rst) begin
            assume (s_hold); assume (s_drop); assume (s_align); assume (s_strobe);
            assert (d_only); assert (d_answer);
        end
        always @(*) if (rst) assume (!valid);
    end else begin : src
        always @(*) if (!rst) begin
            assert (s_hold); assert (s_drop); assert (s_align); assert (s_strobe);
            assume (d_only); assume (d_answer);
        end
    end endgenerate
endmodule
