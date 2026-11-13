// spdif_env: the environment for src/Spdif_Tx.v -- the DUT with every input free and one reset
// cycle.  No checking here: the checker (spdif_wb.sv) is bound into the DUT.
`default_nettype none
module spdif_env (
    input wire        clk,
    input wire        en, tick,
    input wire [16:0] period,
    input wire [15:0] left, right,
    input wire [3:0]  sfreq
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    spdif_tx dut (.clk(clk), .rst(init), .en(en), .tick(tick), .period(period), .left(left),
        .right(right), .sfreq(sfreq), .out());
endmodule
