// bram2_lowsets: a stand-in for bsc's BRAM2 (library BRAM2.v, same ports, parameters and
// semantics: write-first per port, one read register, PIPELINED adds a second) that stores only
// the entries whose index bits above the low KEEP bits are zero, KEEP = ADDR_WIDTH - DROP.
// A write elsewhere is dropped (its port's read register still takes the written word, as in
// BRAM2); a read elsewhere returns a free value.  That is an over-approximation of the real RAM
// (whatever word it held there is one of the choices), so a property proved with this stand-in
// holds of the real one; reads within the kept entries are exact.  A counterexample that reads
// outside them must be checked against the real RAM (cover: FV_BRAM_COVER).
//
// Use (ips/mmu_cache): the D-cache's tag RAM is indexed by the set (address [11:6]) and its data
// RAM by {set, word} (address [11:3]); with DROP = 5 and the CPU's addresses held to sets 0 and 1
// (address [11:7] = 0, page-offset bits, so translation keeps them) the two RAMs shrink from
// 64 x 46 and 512 x 128 bits to 2 x 46 and 16 x 128, and the reset / flush loops' writes to the
// other 62 sets are the dropped ones.
`ifndef FV_BRAM_DROP
`define FV_BRAM_DROP 5
`endif
module BRAM2 (CLKA, ENA, WEA, ADDRA, DIA, DOA, CLKB, ENB, WEB, ADDRB, DIB, DOB);
    parameter PIPELINED  = 0;
    parameter ADDR_WIDTH = 1;
    parameter DATA_WIDTH = 1;
    parameter MEMSIZE    = 1;
    localparam integer KEEP = ADDR_WIDTH - `FV_BRAM_DROP;
    input                   CLKA, ENA, WEA;
    input  [ADDR_WIDTH-1:0] ADDRA;
    input  [DATA_WIDTH-1:0] DIA;
    output [DATA_WIDTH-1:0] DOA;
    input                   CLKB, ENB, WEB;
    input  [ADDR_WIDTH-1:0] ADDRB;
    input  [DATA_WIDTH-1:0] DIB;
    output [DATA_WIDTH-1:0] DOB;
    reg [DATA_WIDTH-1:0] RAM [0:(1 << KEEP) - 1];
    reg [DATA_WIDTH-1:0] DOA_R, DOB_R, DOA_R2, DOB_R2;
    (* anyseq *) reg [DATA_WIDTH-1:0] FREE_A, FREE_B;
    wire kept_a = (ADDRA >> KEEP) == 0, kept_b = (ADDRB >> KEEP) == 0;
    wire [KEEP-1:0] ia = ADDRA[KEEP-1:0], ib = ADDRB[KEEP-1:0];
    always @(posedge CLKA) begin
        if (ENA) begin
            if (WEA) begin
                if (kept_a) RAM[ia] <= DIA;
                DOA_R <= DIA;
            end else
                DOA_R <= kept_a ? RAM[ia] : FREE_A;
        end
        DOA_R2 <= DOA_R;
    end
    always @(posedge CLKB) begin
        if (ENB) begin
            if (WEB) begin
                if (kept_b) RAM[ib] <= DIB;
                DOB_R <= DIB;
            end else
                DOB_R <= kept_b ? RAM[ib] : FREE_B;
        end
        DOB_R2 <= DOB_R;
    end
    assign DOA = PIPELINED ? DOA_R2 : DOA_R;
    assign DOB = PIPELINED ? DOB_R2 : DOB_R;
`ifdef FV_BRAM_COVER
    always @(*) cover ((ENA && !WEA && !kept_a) || (ENB && !WEB && !kept_b));
`endif
endmodule
