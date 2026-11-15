// jtagg_dtm_env: src/JtaggDtm.bsv (mkJtaggDtm) with one reset cycle; the checker (jtagg_dtm_wb.sv)
// is bound into it.  The JTAGG pins are free (the checker states their timing), or with FV_TAP
// come from vip/jtag/ecp5_jtagg_vip (the configuration TAP, TMS / TDI free); the debug module's
// side is free.
`default_nettype none
module jtagg_dtm_env (
    input wire        clk,
    input wire [6:0]  pins_free, input wire go, tms, tdi,
    input wire        en_get, en_put, input wire [71:0] rsp
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire [6:0] pins; wire tdo;
`ifdef FV_TAP
    wire jtck, jtdi, jshift, jupdate, jrstn, jce1, jce2;
    ecp5_jtagg_vip #(.TH(5), .TL(1)) tap (.clk(clk), .rst(init), .go(go), .tms(tms), .tdi(tdi),
        .jtck(jtck), .jtdi(jtdi), .jshift(jshift), .jupdate(jupdate), .jrstn(jrstn), .jce1(jce1), .jce2(jce2),
        .rise(), .fall(), .cap1(), .cap2(), .sh1(), .sh2(), .up1(), .up2(), .tlr(), .fsh1(), .fsh2(),
        .tdi_in(), .st(), .ir());
    assign pins = {jce2, jce1, jrstn, jupdate, jshift, jtdi, jtck};
`else
    assign pins = pins_free;
`endif
    mkJtaggDtm dut (.CLK(clk), .RST_N(!init), .pins_v(pins), .tdo(tdo),
        .EN_client_request_get(en_get), .client_request_get(), .RDY_client_request_get(),
        .client_response_put(rsp), .EN_client_response_put(en_put), .RDY_client_response_put(),
        .tr_capture(), .tr_shift(), .tr_update(), .tr_ignored(), .tr_rsp());
endmodule
`default_nettype wire
