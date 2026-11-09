// The contract the SDRAM credit proof assumes of its response FIFO, on bsc's SizedFIFO with the
// controller's depth and counter width.  The width is 1 because no control state reads the data.
module fifo_fv (input clk, input enq_i, input deq_i, input d);
    reg [1:0] rst_cnt = 0; wire rst_n = rst_cnt == 2'd3;
    always @(posedge clk) if (!rst_n) rst_cnt <= rst_cnt + 1;
    wire full_n, empty_n, q;
    wire enq = rst_n && enq_i && full_n;     // BSV's implicit conditions
    wire deq = rst_n && deq_i && empty_n;
    SizedFIFO #(.p1width(32'd1), .p2depth(32'd8), .p3cntr_width(32'd3), .guarded(1'd1))
        dut (.RST(rst_n), .CLK(clk), .D_IN(d), .ENQ(enq), .FULL_N(full_n), .D_OUT(q), .DEQ(deq), .EMPTY_N(empty_n), .CLR(1'b0));
    reg [3:0] cnt = 0;
    always @(posedge clk) if (!rst_n) cnt <= 0; else cnt <= cnt + (enq ? 4'd1 : 4'd0) - (deq ? 4'd1 : 4'd0);
`ifndef CAP
 `define CAP 8
`endif
    always @(posedge clk) if (rst_n) begin
        assert (cnt <= 4'd8);
        if (cnt < 4'd`CAP) assert (full_n);
        if (cnt == 0)      assert (!empty_n);
        cover (cnt == 4'd8 && !full_n);
    end
endmodule
