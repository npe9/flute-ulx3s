// soc_info_env: src/SoC_Info.bsv (mkSoC_Info) with every input free and one reset cycle; the checker
// (soc_info_wb.sv) is bound into it.  init's address window and clk_hz are symbolic constants (the
// SoC passes soc_map's soc_info base and lim at every reset completion, and its clock rate).
`default_nettype none
module soc_info_env (
    input wire        clk, en_reset, en_init,
    input wire        awvalid, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire [7:0]  awlen, input wire [2:0] awsize, input wire [1:0] awburst, input wire awlock,
    input wire [3:0]  awcache, input wire [2:0] awprot, input wire [3:0] awqos, input wire [3:0] awregion,
    input wire        wvalid, input wire [63:0] wdata, input wire [7:0] wstrb, input wire wlast,
    input wire        bready,
    input wire        arvalid, input wire [3:0] arid, input wire [63:0] araddr,
    input wire [7:0]  arlen, input wire [2:0] arsize, input wire [1:0] arburst, input wire arlock,
    input wire [3:0]  arcache, input wire [2:0] arprot, input wire [3:0] arqos, input wire [3:0] arregion,
    input wire        rready,
    input wire        en_err, input wire [74:0] err_e,
    input wire        en_retire, en_imiss, en_dmiss, en_ext_irq, en_uart_irq, en_redirect,
    input wire [3:0]  init_id
);
    reg init = 1'b1;                           // one reset cycle (RST_N low), then the reset method only
    always @(posedge clk) init <= 1'b0;
    (* anyconst *) reg [63:0] base, lim;
    (* anyconst *) reg [31:0] hz;
    mkSoC_Info dut (
        .clk_hz(hz), .CLK(clk), .RST_N(!init),
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
        .note_err_e(err_e), .EN_note_err(en_err), .RDY_note_err(),
        .EN_note_retire(en_retire), .RDY_note_retire(), .EN_note_imiss(en_imiss), .RDY_note_imiss(),
        .EN_note_dmiss(en_dmiss), .RDY_note_dmiss(), .EN_note_ext_irq(en_ext_irq), .RDY_note_ext_irq(),
        .EN_note_uart_irq(en_uart_irq), .RDY_note_uart_irq(), .EN_note_redirect(en_redirect),
        .RDY_note_redirect(),
        .tr_wr(), .tr_rd_addr(), .tr_rd());
endmodule
`default_nettype wire
