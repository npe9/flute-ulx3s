// spi_env: src/AXI4_SPI.bsv (mkAXI4_SPI) with every AXI input free, one reset cycle, then init
// with a free window; MISO of both chip selects looped back to MOSI; the reset method unused.
// The checker (spi_wb.sv) is bound into it.
`default_nettype none
module spi_env (
    input wire        clk,
    input wire [63:0] base, lim,
    input wire        awvalid, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire [7:0]  awlen, input wire [2:0] awsize, input wire [1:0] awburst, input wire awlock,
    input wire [3:0]  awcache, input wire [2:0] awprot, input wire [3:0] awqos, input wire [3:0] awregion,
    input wire        wvalid, input wire [63:0] wdata, input wire [7:0] wstrb, input wire wlast,
    input wire        bready,
    input wire        arvalid, input wire [3:0] arid, input wire [63:0] araddr,
    input wire [7:0]  arlen, input wire [2:0] arsize, input wire [1:0] arburst, input wire arlock,
    input wire [3:0]  arcache, input wire [2:0] arprot, input wire [3:0] arqos, input wire [3:0] arregion,
    input wire        rready
);
    reg [1:0] ph = 2'd0;                       // 0: reset, 1: init, 2: running
    always @(posedge clk) if (ph != 2'd2) ph <= ph + 2'd1;
    wire mosi;
    mkAXI4_SPI dut (
        .CLK(clk), .RST_N(ph != 2'd0), .init_axi4_id(4'd0), .init_addr_base(base), .init_addr_lim(lim),
        .EN_init(ph == 2'd1), .RDY_init(), .EN_reset(1'b0), .RDY_reset(),
        .slave_awvalid(awvalid), .slave_awid(awid), .slave_awaddr(awaddr), .slave_awlen(awlen),
        .slave_awsize(awsize), .slave_awburst(awburst), .slave_awlock(awlock), .slave_awcache(awcache),
        .slave_awprot(awprot), .slave_awqos(awqos), .slave_awregion(awregion), .slave_awready(),
        .slave_wvalid(wvalid), .slave_wdata(wdata), .slave_wstrb(wstrb), .slave_wlast(wlast), .slave_wready(),
        .slave_bvalid(), .slave_bid(), .slave_bresp(), .slave_bready(bready),
        .slave_arvalid(arvalid), .slave_arid(arid), .slave_araddr(araddr), .slave_arlen(arlen),
        .slave_arsize(arsize), .slave_arburst(arburst), .slave_arlock(arlock), .slave_arcache(arcache),
        .slave_arprot(arprot), .slave_arqos(arqos), .slave_arregion(arregion), .slave_arready(),
        .slave_rvalid(), .slave_rid(), .slave_rdata(), .slave_rresp(), .slave_rlast(), .slave_rready(rready),
        .interrupt_req(), .RDY_interrupt_req(), .sclk(), .mosi(mosi), .cs_n(),
        .miso0_v(mosi), .miso1_v(mosi),
        .tr_wr(), .tr_rd(), .tr_tx_enq(), .tr_frame_start(), .tr_frame_end(), .tr_rx_push(), .tr_rx_pop());
endmodule
`default_nettype wire
