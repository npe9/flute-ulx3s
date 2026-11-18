// mmu_cache_env: Flute's D-side mkMMU_Cache (src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv, as the SoC
// instantiates it: dmem_not_imem = 1) with every input free and one reset cycle.  The checker
// (mmu_cache_wb.sv) is bound into it and states the CPU's and the fabric's obligations.
`default_nettype none
module mmu_cache_env (
    input wire        clk,
    input wire        en_verb, input wire [3:0] verb,
    input wire        en_rst_req, en_rst_rsp,
    input wire [1:0]  req_op, input wire [2:0] req_f3, input wire [6:0] req_amo_funct7,
    input wire [31:0] req_addr, input wire [63:0] req_st_value, input wire [1:0] req_priv,
    input wire        req_sum, req_mxr, input wire [31:0] req_satp, input wire en_req,
    input wire        en_kill,
    input wire        en_fl_req, en_fl_rsp, en_tlb_flush,
    input wire        awready, wready,
    input wire        bvalid, input wire [3:0] bid, input wire [1:0] bresp,
    input wire        arready,
    input wire        rvalid, input wire [3:0] rid, input wire [63:0] rdata, input wire [1:0] rresp,
    input wire        rlast,
    input wire        en_ddr4, input wire [408:0] pmp
);
    reg init = 1'b1;                           // one reset cycle (RST_N low)
    always @(posedge clk) init <= 1'b0;
    mkMMU_Cache #(.dmem_not_imem(1'b1)) dut (
        .CLK(clk), .RST_N(!init),
        .set_verbosity_verbosity(verb), .EN_set_verbosity(en_verb), .RDY_set_verbosity(),
        .EN_server_reset_request_put(en_rst_req), .RDY_server_reset_request_put(),
        .EN_server_reset_response_get(en_rst_rsp), .RDY_server_reset_response_get(),
        .req_op(req_op), .req_f3(req_f3), .req_amo_funct7(req_amo_funct7), .req_addr(req_addr),
        .req_st_value(req_st_value), .req_priv(req_priv), .req_sstatus_SUM(req_sum),
        .req_mstatus_MXR(req_mxr), .req_satp(req_satp), .EN_req(en_req),
        .valid(), .addr(), .cword(), .st_amo_val(), .exc(), .exc_code(),
        .EN_ma_kill_echo(en_kill),
        .EN_server_flush_request_put(en_fl_req), .RDY_server_flush_request_put(),
        .EN_server_flush_response_get(en_fl_rsp), .RDY_server_flush_response_get(),
        .EN_tlb_flush(en_tlb_flush), .RDY_tlb_flush(),
        .mem_master_awvalid(), .mem_master_awid(), .mem_master_awaddr(), .mem_master_awlen(),
        .mem_master_awsize(), .mem_master_awburst(), .mem_master_awlock(), .mem_master_awcache(),
        .mem_master_awprot(), .mem_master_awqos(), .mem_master_awregion(), .mem_master_awready(awready),
        .mem_master_wvalid(), .mem_master_wdata(), .mem_master_wstrb(), .mem_master_wlast(),
        .mem_master_wready(wready),
        .mem_master_bvalid(bvalid), .mem_master_bid(bid), .mem_master_bresp(bresp), .mem_master_bready(),
        .mem_master_arvalid(), .mem_master_arid(), .mem_master_araddr(), .mem_master_arlen(),
        .mem_master_arsize(), .mem_master_arburst(), .mem_master_arlock(), .mem_master_arcache(),
        .mem_master_arprot(), .mem_master_arqos(), .mem_master_arregion(), .mem_master_arready(arready),
        .mem_master_rvalid(rvalid), .mem_master_rid(rid), .mem_master_rdata(rdata),
        .mem_master_rresp(rresp), .mem_master_rlast(rlast), .mem_master_rready(),
        .EN_ma_ddr4_ready(en_ddr4), .RDY_ma_ddr4_ready(),
        .mv_status(), .mv_busy(), .mv_perf_miss(), .RDY_mv_perf_miss(), .ma_pmp_t(pmp));
endmodule
`default_nettype wire
