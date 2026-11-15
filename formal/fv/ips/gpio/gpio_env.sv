// gpio_env: src/AXI4_GPIO.bsv (mkAXI4_GPIO) with every input free and one reset cycle; the checker
// (gpio_wb.sv) is bound into it.  init's address window is a symbolic constant (the SoC passes
// soc_map's accel0 base and lim at every reset completion); init itself is free.
`default_nettype none
module gpio_env (
    input wire        clk, en_reset, en_init, btn1,
    input wire        awvalid, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire [7:0]  awlen, input wire [2:0] awsize, input wire [1:0] awburst, input wire awlock,
    input wire [3:0]  awcache, input wire [2:0] awprot, input wire [3:0] awqos, input wire [3:0] awregion,
    input wire        wvalid, input wire [63:0] wdata, input wire [7:0] wstrb, input wire wlast,
    input wire        bready,
    input wire        arvalid, input wire [3:0] arid, input wire [63:0] araddr,
    input wire [7:0]  arlen, input wire [2:0] arsize, input wire [1:0] arburst, input wire arlock,
    input wire [3:0]  arcache, input wire [2:0] arprot, input wire [3:0] arqos, input wire [3:0] arregion,
    input wire        rready,
    // the master port (unused by the GPIO): the fabric side is free
    input wire        m_awready, m_wready, m_bvalid, input wire [3:0] m_bid, input wire [1:0] m_bresp,
    input wire        m_arready, m_rvalid, input wire [3:0] m_rid, input wire [63:0] m_rdata,
    input wire [1:0]  m_rresp, input wire m_rlast, input wire [3:0] init_id
);
    reg init = 1'b1;                           // one reset cycle (RST_N low), then the reset method only
    always @(posedge clk) init <= 1'b0;
    (* anyconst *) reg [63:0] base, lim;
    mkAXI4_GPIO dut (
        .CLK(clk), .RST_N(!init),
        .init_axi4_id(init_id), .init_addr_base(base), .init_addr_lim(lim), .EN_init(en_init), .RDY_init(),
        .EN_reset(en_reset), .RDY_reset(),
        .slave_awvalid(awvalid), .slave_awid(awid), .slave_awaddr(awaddr), .slave_awlen(awlen),
        .slave_awsize(awsize), .slave_awburst(awburst), .slave_awlock(awlock), .slave_awcache(awcache),
        .slave_awprot(awprot), .slave_awqos(awqos), .slave_awregion(awregion), .slave_awready(),
        .slave_wvalid(wvalid), .slave_wdata(wdata), .slave_wstrb(wstrb), .slave_wlast(wlast), .slave_wready(),
        .slave_bvalid(), .slave_bid(), .slave_bresp(), .slave_bready(bready),
        .slave_arvalid(arvalid), .slave_arid(arid), .slave_araddr(araddr), .slave_arlen(arlen),
        .slave_arsize(arsize), .slave_arburst(arburst), .slave_arlock(arlock), .slave_arcache(arcache),
        .slave_arprot(arprot), .slave_arqos(arqos), .slave_arregion(arregion), .slave_arready(),
        .slave_rvalid(), .slave_rid(), .slave_rdata(), .slave_rresp(), .slave_rlast(), .slave_rready(rready),
        .interrupt_req(), .RDY_interrupt_req(),
        .master_awvalid(), .master_awid(), .master_awaddr(), .master_awlen(), .master_awsize(),
        .master_awburst(), .master_awlock(), .master_awcache(), .master_awprot(), .master_awqos(),
        .master_awregion(), .master_awready(m_awready),
        .master_wvalid(), .master_wdata(), .master_wstrb(), .master_wlast(), .master_wready(m_wready),
        .master_bvalid(m_bvalid), .master_bid(m_bid), .master_bresp(m_bresp), .master_bready(),
        .master_arvalid(), .master_arid(), .master_araddr(), .master_arlen(), .master_arsize(),
        .master_arburst(), .master_arlock(), .master_arcache(), .master_arprot(), .master_arqos(),
        .master_arregion(), .master_arready(m_arready),
        .master_rvalid(m_rvalid), .master_rid(m_rid), .master_rdata(m_rdata), .master_rresp(m_rresp),
        .master_rlast(m_rlast), .master_rready(),
        .leds(), .btn1_v(btn1), .tr_wr(), .tr_rd());
endmodule
`default_nettype wire
