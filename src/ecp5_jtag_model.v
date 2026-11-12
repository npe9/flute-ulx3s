// Simulation model of the ECP5 configuration TAP as JTAGG presents it to user logic (src/Top.v
// includes this under VERILATOR in place of the JTAGG primitive).  IR length 8, IR capture 0x01;
// IDCODE (IR 0xE0, and the DR after Test-Logic-Reset) 0x41113043 (LFE5U-85F); ER1 = IR 0x32,
// ER2 = IR 0x38; any other IR is a 1-bit bypass.
//   JTCK = TCK; JTDI = TDI registered on TCK's rising edge (as the LFE5U-85F does it, see
//   src/JtaggDtm.bsv; `define ECP5_JTAG_TDI_COMB for JTDI = TDI); JSHIFT in Shift-DR; JUPDATE in Update-DR; JRSTN low in
//   Test-Logic-Reset; JCE1 / JCE2 in Capture-DR and Shift-DR while IR = ER1 / ER2.
//   TDO changes on the falling edge: the selected register's bit 0 (JTDO1 / JTDO2 for ER1 / ER2).
module ecp5_jtag_model (
    input  wire TCK, TMS, TDI,
    output reg  TDO,
    output wire JTCK, JTDI, JSHIFT, JUPDATE, JRSTN, JCE1, JCE2, JRTI1, JRTI2,
    input  wire JTDO1, JTDO2
);
    localparam TLR = 4'd0, RTI = 4'd1, SDR = 4'd2, CDR = 4'd3, SHDR = 4'd4, E1DR = 4'd5,
               PDR = 4'd6, E2DR = 4'd7, UDR = 4'd8, SIR = 4'd9, CIR = 4'd10, SHIR = 4'd11,
               E1IR = 4'd12, PIR = 4'd13, E2IR = 4'd14, UIR = 4'd15;
    reg [3:0]  st = TLR;
    reg [7:0]  ir = 8'hE0, ir_sh = 8'h00;
    reg [31:0] dr = 32'h0;
    always @(posedge TCK) begin
        case (st)
            TLR:  st <= TMS ? TLR  : RTI;
            RTI:  st <= TMS ? SDR  : RTI;
            SDR:  st <= TMS ? SIR  : CDR;
            CDR:  st <= TMS ? E1DR : SHDR;
            SHDR: st <= TMS ? E1DR : SHDR;
            E1DR: st <= TMS ? UDR  : PDR;
            PDR:  st <= TMS ? E2DR : PDR;
            E2DR: st <= TMS ? UDR  : SHDR;
            UDR:  st <= TMS ? SDR  : RTI;
            SIR:  st <= TMS ? TLR  : CIR;
            CIR:  st <= TMS ? E1IR : SHIR;
            SHIR: st <= TMS ? E1IR : SHIR;
            E1IR: st <= TMS ? UIR  : PIR;
            PIR:  st <= TMS ? E2IR : PIR;
            E2IR: st <= TMS ? UIR  : SHIR;
            UIR:  st <= TMS ? SDR  : RTI;
        endcase
        if (st == TLR) ir <= 8'hE0;
        if (st == CIR) ir_sh <= 8'h01;
        if (st == SHIR) ir_sh <= {TDI, ir_sh[7:1]};
        if (st == UIR) ir <= ir_sh;
        if (st == CDR) dr <= (ir == 8'hE0) ? 32'h41113043 : 32'h0;
        if (st == SHDR) dr <= (ir == 8'hE0) ? {TDI, dr[31:1]} : {31'b0, TDI};
    end
    wire er1 = (ir == 8'h32), er2 = (ir == 8'h38);
    always @(negedge TCK)
        TDO <= (st == SHIR) ? ir_sh[0]
             : (st == SHDR) ? (er1 ? JTDO1 : er2 ? JTDO2 : dr[0])
             : 1'b0;
`ifdef ECP5_JTAG_TDI_COMB
    assign JTCK = TCK, JTDI = TDI;
`else
    reg tdi_q = 1'b0;
    always @(posedge TCK) tdi_q <= TDI;
    assign JTCK = TCK, JTDI = tdi_q;
`endif
    assign JSHIFT  = (st == SHDR);
    assign JUPDATE = (st == UDR);
    assign JRSTN   = (st != TLR);
    assign JCE1 = er1 && (st == CDR || st == SHDR);
    assign JCE2 = er2 && (st == CDR || st == SHDR);
    assign JRTI1 = er1 && (st == RTI);
    assign JRTI2 = er2 && (st == RTI);
endmodule
