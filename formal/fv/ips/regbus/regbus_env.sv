// regbus_env: src/AXI4_RegBus.bsv (mkAXI4_RegBus_W) with every input free and one reset cycle; the checker
// (regbus_wb.sv) is bound into it.  FV_WDOG_SHORT: a 7-cycle watchdog, so a bounded check reaches
// a timeout (the SoC's is 255; the proof runs at both).
`default_nettype none
module regbus_env (
    input wire        clk, en_reset,
    input wire        awvalid, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire [7:0]  awlen, input wire [2:0] awsize, input wire [1:0] awburst, input wire awlock,
    input wire [3:0]  awcache, input wire [2:0] awprot, input wire [3:0] awqos, input wire [3:0] awregion,
    input wire        wvalid, input wire [63:0] wdata, input wire [7:0] wstrb, input wire wlast,
    input wire        bready,
    input wire        arvalid, input wire [3:0] arid, input wire [63:0] araddr,
    input wire [7:0]  arlen, input wire [2:0] arsize, input wire [1:0] arburst, input wire arlock,
    input wire [3:0]  arcache, input wire [2:0] arprot, input wire [3:0] arqos, input wire [3:0] arregion,
    input wire        rready,
    input wire        ack, input wire [31:0] ack_rdata
);
    reg init = 1'b1;                           // one reset cycle (RST_N low), then the reset method only
    always @(posedge clk) init <= 1'b0;
`ifdef FV_WDOG_SHORT
    localparam [7:0] WD = 8'd7;
`else
    localparam [7:0] WD = 8'hFF;
`endif
    mkAXI4_RegBus_W #(.wdog_max(WD)) dut (
        .CLK(clk), .RST_N(!init), .EN_reset(en_reset), .RDY_reset(),
        .slave_awvalid(awvalid), .slave_awid(awid), .slave_awaddr(awaddr), .slave_awlen(awlen),
        .slave_awsize(awsize), .slave_awburst(awburst), .slave_awlock(awlock), .slave_awcache(awcache),
        .slave_awprot(awprot), .slave_awqos(awqos), .slave_awregion(awregion), .slave_awready(),
        .slave_wvalid(wvalid), .slave_wdata(wdata), .slave_wstrb(wstrb), .slave_wlast(wlast), .slave_wready(),
        .slave_bvalid(), .slave_bid(), .slave_bresp(), .slave_bready(bready),
        .slave_arvalid(arvalid), .slave_arid(arid), .slave_araddr(araddr), .slave_arlen(arlen),
        .slave_arsize(arsize), .slave_arburst(arburst), .slave_arlock(arlock), .slave_arcache(arcache),
        .slave_arprot(arprot), .slave_arqos(arqos), .slave_arregion(arregion), .slave_arready(),
        .slave_rvalid(), .slave_rid(), .slave_rdata(), .slave_rresp(), .slave_rlast(), .slave_rready(rready),
        .rb_valid(), .rb_we(), .rb_addr(), .rb_wdata(), .rb_wstrb(), .rb_ack_ack(ack), .rb_ack_rdata(ack_rdata),
        .tr_start(), .tr_skip(), .tr_we(), .tr_done(), .tr_timeout(), .tr_wdog());
endmodule
`default_nettype wire
