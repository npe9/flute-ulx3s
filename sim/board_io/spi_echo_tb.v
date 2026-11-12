`timescale 1ns/1ps
// unit check of sim/common/spi_echo_model.v: two words, each as 2 x 8 clocks with a pause
module tb;
    reg clk = 0, sck = 0, mosi = 0, cs_n = 1; wire miso;
    always #5 clk = ~clk;
    spi_echo_model m (.clk(clk), .sck(sck), .mosi(mosi), .cs_n(cs_n), .miso(miso));
    reg [15:0] got; integer i, errs = 0;
    task word (input [15:0] w, input [15:0] exp);
        begin
            cs_n = 0; repeat (4) @(posedge clk);
            for (i = 15; i >= 0; i = i - 1) begin
                mosi = w[i]; repeat (3) @(posedge clk);
                sck = 1; got[i] = miso; repeat (3) @(posedge clk);
                sck = 0; if (i == 8) repeat (20) @(posedge clk);
            end
            repeat (4) @(posedge clk); cs_n = 1; repeat (6) @(posedge clk);
            if (got !== exp) begin errs = errs + 1; $display("got %h exp %h", got, exp); end
        end
    endtask
    initial begin
        word (16'h1234, 16'hA5C3); word (16'hBEEF, 16'h1234); word (16'h0000, 16'hBEEF);
        $display("%s", errs ? "FAIL" : "PASS"); $finish;
    end
endmodule
