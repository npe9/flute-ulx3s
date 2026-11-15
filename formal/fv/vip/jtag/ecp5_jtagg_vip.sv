// ecp5_jtagg_vip: the ECP5 configuration TAP as its JTAGG primitive presents it to user logic, for
// formal on one system clock.  IEEE 1149.1 TAP controller, IR length 8 (capture 0x01, IDCODE 0xE0
// after Test-Logic-Reset); ER1 = IR 0x32, ER2 = IR 0x38.  TCK is a register toggled when the
// free input `go` says so, each phase lasting at least TH (high) / TL (low) system clocks; TMS and
// TDI are free and taken on TCK's rising edge.  Outputs, as on the LFE5U-85F:
//   JTCK = TCK; JTDI = TDI registered on TCK's rising edge; JSHIFT in Shift-DR; JUPDATE in
//   Update-DR; JRSTN low in Test-Logic-Reset; JCE1 / JCE2 in Capture-DR and Shift-DR while IR is
//   ER1 / ER2.  The TAP takes TDO from JTDO1 / JTDO2 (by IR) on TCK's falling edge in Shift-DR.
// Events (one clock wide, in the clock whose end the TAP's registers change in):
//   rise: a rising TCK edge; st, ir: the state and IR it leaves; tms, tdi: the inputs it takes
//   cap1 / cap2: leaving Capture-DR with ER1 / ER2; sh1 / sh2: leaving Shift-DR with ER1 / ER2
//   up1 / up2: leaving Update-DR with ER1 / ER2; tlr: in Test-Logic-Reset
//   fall: a falling TCK edge; fsh1 / fsh2 the TAP in Shift-DR with ER1 / ER2 (it takes JTDO then)
`default_nettype none
module ecp5_jtagg_vip #(parameter integer TH = 5, parameter integer TL = 5) (
    input  wire       clk, rst,
    input  wire       go, tms, tdi,
    output wire       jtck, jtdi, jshift, jupdate, jrstn, jce1, jce2,
    output wire       rise, fall, cap1, cap2, sh1, sh2, up1, up2, tlr, fsh1, fsh2,
    output wire       tdi_in, output reg [3:0] st, output reg [7:0] ir
);
    localparam [3:0] TLR = 4'd0, RTI = 4'd1, SDR = 4'd2, CDR = 4'd3, SHDR = 4'd4, E1DR = 4'd5,
                     PDR = 4'd6, E2DR = 4'd7, UDR = 4'd8, SIR = 4'd9, CIR = 4'd10, SHIR = 4'd11,
                     E1IR = 4'd12, PIR = 4'd13, E2IR = 4'd14, UIR = 4'd15;
    reg       tck = 1'b0, tdi_q = 1'b0;
    reg [7:0] ir_sh = 8'h00;
    reg [7:0] ph = 8'd0;                       // clocks the current TCK phase has lasted, saturating
    initial begin st = TLR; ir = 8'hE0; end
    wire may = tck ? (ph >= TH - 1) : (ph >= TL - 1);
    wire tog = !rst && go && may;
    assign rise = tog && !tck, fall = tog && tck;
    reg [3:0] nst;
    always @(*) case (st)
        TLR:  nst = tms ? TLR  : RTI;   RTI:  nst = tms ? SDR  : RTI;
        SDR:  nst = tms ? SIR  : CDR;   CDR:  nst = tms ? E1DR : SHDR;
        SHDR: nst = tms ? E1DR : SHDR;  E1DR: nst = tms ? UDR  : PDR;
        PDR:  nst = tms ? E2DR : PDR;   E2DR: nst = tms ? UDR  : SHDR;
        UDR:  nst = tms ? SDR  : RTI;   SIR:  nst = tms ? TLR  : CIR;
        CIR:  nst = tms ? E1IR : SHIR;  SHIR: nst = tms ? E1IR : SHIR;
        E1IR: nst = tms ? UIR  : PIR;   PIR:  nst = tms ? E2IR : PIR;
        E2IR: nst = tms ? UIR  : SHIR;  default: nst = tms ? SDR : RTI;   // UIR
    endcase
    always @(posedge clk) begin
        if (rst) begin
            tck <= 1'b0; ph <= 8'd0; st <= TLR; ir <= 8'hE0; ir_sh <= 8'h00; tdi_q <= 1'b0;
        end else begin
            ph <= tog ? 8'd0 : (ph == 8'hFF ? ph : ph + 8'd1);
            if (tog) tck <= !tck;
            if (rise) begin
                st <= nst; tdi_q <= tdi;
                if (st == TLR)  ir <= 8'hE0;
                if (st == CIR)  ir_sh <= 8'h01;
                if (st == SHIR) ir_sh <= {tdi, ir_sh[7:1]};
                if (st == UIR)  ir <= ir_sh;
            end
        end
    end
    wire er1 = (ir == 8'h32), er2 = (ir == 8'h38);
    assign jtck = tck, jtdi = tdi_q;
    assign jshift = (st == SHDR), jupdate = (st == UDR), jrstn = (st != TLR);
    assign jce1 = er1 && (st == CDR || st == SHDR), jce2 = er2 && (st == CDR || st == SHDR);
    assign cap1 = rise && st == CDR && er1,  cap2 = rise && st == CDR && er2;
    assign sh1  = rise && st == SHDR && er1, sh2  = rise && st == SHDR && er2;
    assign up1  = rise && st == UDR && er1,  up2  = rise && st == UDR && er2;
    assign tlr  = st == TLR;
    assign fsh1 = fall && st == SHDR && er1, fsh2 = fall && st == SHDR && er2;
    assign tdi_in = tdi;
endmodule
`default_nettype wire
