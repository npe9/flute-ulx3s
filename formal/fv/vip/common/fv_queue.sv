// fv_queue: a small in-order queue for scoreboards (a checker's expected transfers).
// push and pop may come in the same cycle; pop of an empty queue, or push into a full one, is the
// user's assertion to make (outputs n, full).  ents holds every entry, head first, for invariants.
// NW: the width of n (D <= 2**NW - 1; the default 4 serves D up to 15).
`default_nettype none
module fv_queue #(parameter integer W = 8, parameter integer D = 4, parameter integer NW = 4) (
    input  wire           clk, rst,
    input  wire           push, input wire [W-1:0] din,
    input  wire           pop,
    output wire [W-1:0]   head,
    output reg  [NW-1:0]  n,
    output wire           full,
    output wire [W*D-1:0] ents
);
    reg [W-1:0] e [0:D-1];
    integer i;
    localparam [NW-1:0] Z = 0, O = 1;
    initial n = Z;
    always @(posedge clk) begin
        if (pop && n != Z) begin
            for (i = 0; i < D - 1; i = i + 1) e[i] <= e[i + 1];
            if (push) e[n - O] <= din;
        end else if (push && n < D) e[n] <= din;
        n <= n + ((push && (n < D || pop)) ? O : Z) - ((pop && n != Z) ? O : Z);
        if (rst) n <= Z;
    end
    assign head = e[0];
    assign full = n >= D;
    genvar g;
    generate for (g = 0; g < D; g = g + 1) begin : flat
        assign ents[W*g +: W] = e[g];
    end endgenerate
endmodule
`default_nettype wire
