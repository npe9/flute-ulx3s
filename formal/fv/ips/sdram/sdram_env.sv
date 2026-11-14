// sdram_env: src/Sdram_Controller.bsv (mkSdram_Controller_50, the SoC's controller body at the
// shipping 50 MHz) with every input free and one reset cycle; the checker (sdram_wb.sv) is bound
// into it.  The request and response methods are guarded: a free wish, taken when ready.
// Power-up pause: 2 clocks, so a bounded check reaches requests; FV_PWR_REAL: the SoC's 10000
// (200 us).
`default_nettype none
module sdram_env (
    input wire         clk,
    input wire         want_put, input wire [311:0] req_in,
    input wire         want_get,
    input wire [15:0]  dq_in
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
`ifdef FV_PWR_REAL
    localparam [15:0] PWR = 16'd10000;
`else
    localparam [15:0] PWR = 16'd2;
`endif
    wire rdy_put, rdy_get;
    mkSdram_Controller_50 #(.t_powerup(PWR)) dut (
        .CLK(clk), .RST_N(!init),
        .EN_mem_server_request_put(want_put && rdy_put), .mem_server_request_put(req_in),
        .RDY_mem_server_request_put(rdy_put),
        .EN_mem_server_response_get(want_get && rdy_get), .mem_server_response_get(),
        .RDY_mem_server_response_get(rdy_get),
        .init_done(), .sdram_cke(), .sdram_cs_n(), .sdram_ras_n(), .sdram_cas_n(), .sdram_we_n(),
        .sdram_ba(), .sdram_a(), .sdram_dqm(), .sdram_dq_out(), .sdram_dq_oe(), .sdram_dq_in_v(dq_in),
        .tr_take(), .tr_chunk());
endmodule
`default_nettype wire
