// uart_dmi_env: an instance of src/Uart_DMI_Bridge.bsv's mkUart_DMI_Bridge_P (Uart_DMI_Bridge_Fv.bsv:
// short timeouts, or the SoC's with FV_REAL) with every input free and one reset cycle; the checker
// (uart_dmi_wb.sv) is bound into it.
`ifndef UD_TOP
`ifdef FV_REAL
`define UD_TOP mkUart_DMI_Bridge_Real
`define UD_TF 50000000
`define UD_TM 500000
`else
`define UD_TOP mkUart_DMI_Bridge_Fv
`define UD_TF 24
`define UD_TM 10
`endif
`endif
`default_nettype none
module uart_dmi_env (
    input wire       clk, en_put, en_con, en_dbg, en_req, en_rsp,
    input wire [7:0] b, input wire [71:0] rsp
);
    reg init = 1'b1;                           // one reset cycle (RST_N low)
    always @(posedge clk) init <= 1'b0;
    `UD_TOP dut (.CLK(clk), .RST_N(!init),
        .rx_from_uart_put(b), .EN_rx_from_uart_put(en_put), .RDY_rx_from_uart_put(),
        .EN_rx_to_console_get(en_con), .rx_to_console_get(), .RDY_rx_to_console_get(),
        .EN_dbg_tx_get(en_dbg), .dbg_tx_get(), .RDY_dbg_tx_get(), .dbg_tx_pending(),
        .EN_client_request_get(en_req), .client_request_get(), .RDY_client_request_get(),
        .client_response_put(rsp), .EN_client_response_put(en_rsp), .RDY_client_response_put(),
        .tr_feed(), .tr_drop(), .tr_rsp_lost(), .tr_timeout(), .tr_dmi_done());
endmodule
`default_nettype wire
