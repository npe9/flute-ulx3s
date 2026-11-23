// ================================================================
// rb_slice: a register slice on the register bus (protocol in src/AXI4_RegBus.bsv): the request is
// registered on its way to the device and the answer on its way back, so the device is off the
// bridge's broadcast nets (rb_addr / rb_wdata go to every small device).  NOT IN USE: tried in
// front of game2d's VDP (2026-11-23) to let its logic leave the CPU's fetch region; it did not
// (placement is congestion-driven, not net-driven: notes/soc-family-plan.md, P0 timing) and the
// seeds came out no better (s3 48.4 / s5 50.2 against 53.2 / 51.1 without it).  Kept, with its
// proof, for a device that needs its bus registered.
//
// Upstream (the bridge's side): a device -- a request is taken when valid with nothing in flight
// (valid && !busy; busy holds through the ack cycle) and answered by up_ack, one cycle, the cycle after the device's
// ack (so a device answering N cycles after its take is answered here N + 2 after this take).  Downstream (the device's
// side): a source -- valid held with the request stable until ack, dropped the cycle after.
// formal/fv/ips/rb_slice proves both sides' rules and that every transfer passes unchanged.
// ================================================================
module rb_slice (
    input  wire        clk,
    input  wire        rst,
    // upstream: from the bridge
    input  wire        up_valid,
    input  wire        up_we,
    input  wire [31:0] up_addr,
    input  wire [31:0] up_wdata,
    input  wire [3:0]  up_wstrb,
    output reg         up_ack,
    output reg  [31:0] up_rdata,
    // downstream: to the device
    output reg         dn_valid,
    output reg         dn_we,
    output reg  [31:0] dn_addr,
    output reg  [31:0] dn_wdata,
    output reg  [3:0]  dn_wstrb,
    input  wire        dn_ack,
    input  wire [31:0] dn_rdata
);
    reg busy = 1'b0;
    wire take = up_valid && !busy;
    always @(posedge clk) begin
        up_ack <= 1'b0;
        if (take) begin
            busy <= 1'b1;
            dn_valid <= 1'b1; dn_we <= up_we; dn_addr <= up_addr; dn_wdata <= up_wdata;
            dn_wstrb <= up_wstrb;
        end
        if (dn_valid && dn_ack) begin
            dn_valid <= 1'b0;
            up_ack <= 1'b1; up_rdata <= dn_rdata;
        end
        if (up_ack) busy <= 1'b0;
        if (rst) begin busy <= 1'b0; dn_valid <= 1'b0; up_ack <= 1'b0; end
    end
endmodule
