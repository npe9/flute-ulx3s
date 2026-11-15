// sim/jtagg_dtm/tb.v: src/JtaggDtm.bsv (mkJtaggDtm) behind src/ecp5_jtag_model.v, the busy case of
// debug spec 0.13.2: a dmi scan captured while a request is in flight reads op 3, and that scan's
// update must be ignored.  The debug module here answers 800 clocks after each request, mid-scan.
// Run: iverilog -g2012 -DBSV_NO_INITIAL_BLOCKS -y $(scripts/bsc_lib.sh) sim/jtagg_dtm/tb.v
//      src/ecp5_jtag_model.v <bsc Verilog with mkJtaggDtm>   (the gate uses formal/fv's build)
`timescale 1ns/1ps
module tb;
    reg clk = 0, rst_n = 0; always #1 clk = !clk;
    reg TCK = 0, TMS = 1, TDI = 0; wire TDO;
    wire JTCK, JTDI, JSHIFT, JUPDATE, JRSTN, JCE1, JCE2; wire jtdo;
    ecp5_jtag_model tap (.TCK(TCK), .TMS(TMS), .TDI(TDI), .TDO(TDO), .JTCK(JTCK), .JTDI(JTDI),
        .JSHIFT(JSHIFT), .JUPDATE(JUPDATE), .JRSTN(JRSTN), .JCE1(JCE1), .JCE2(JCE2), .JRTI1(), .JRTI2(),
        .JTDO1(jtdo), .JTDO2(jtdo));
    wire rdy_get; wire [135:0] req; reg en_get = 0, en_put = 0; reg [71:0] rsp = 0;
    mkJtaggDtm dut (.CLK(clk), .RST_N(rst_n), .pins_v({JCE2, JCE1, JRSTN, JUPDATE, JSHIFT, JTDI, JTCK}),
        .tdo(jtdo), .EN_client_request_get(en_get), .client_request_get(req), .RDY_client_request_get(rdy_get),
        .client_response_put(rsp), .EN_client_response_put(en_put), .RDY_client_response_put(),
        .tr_capture(), .tr_shift(), .tr_update(), .tr_ignored(), .tr_rsp());
    // debug module: takes each request, answers 800 clocks later
    integer nreq = 0, wait_n = -1;
    always @(posedge clk) begin
        en_get <= 0; en_put <= 0;
        if (rdy_get && !en_get && wait_n < 0) begin
            en_get <= 1; nreq = nreq + 1; wait_n = 800;
            $display("t=%0t request %0d: op %0d addr %h data %h", $time, nreq, req[135:128], req[70:64], req[31:0]);
        end else if (wait_n > 0) wait_n = wait_n - 1;
        else if (wait_n == 0) begin en_put <= 1; rsp <= {8'd0, 64'h5a5a}; wait_n = -1; $display("t=%0t response", $time); end
    end
    task tck_cycle(input tms, input tdi, output tdo_s);
        begin TMS = tms; TDI = tdi; repeat (20) @(posedge clk); TCK = 1; repeat (20) @(posedge clk); tdo_s = TDO; TCK = 0; end
    endtask
    reg o; integer i; reg [40:0] din, dout;
    task ir(input [7:0] v);
        begin tck_cycle(1,0,o); tck_cycle(1,0,o); tck_cycle(0,0,o); tck_cycle(0,0,o);   // SelDR SelIR CapIR ShIR
            for (i = 0; i < 8; i = i + 1) tck_cycle(i == 7, v[i], o);
            tck_cycle(1,0,o); tck_cycle(0,0,o); end                                      // UpdIR RTI
    endtask
    task dr(input [40:0] v, output [40:0] r);
        begin tck_cycle(1,0,o); tck_cycle(0,0,o); tck_cycle(0,0,o);                      // SelDR CapDR ShDR
            for (i = 0; i < 41; i = i + 1) begin tck_cycle(i == 40, v[i], o); r[i] = o; end
            tck_cycle(1,0,o); tck_cycle(0,0,o); end                                      // UpdDR RTI
    endtask
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (6) tck_cycle(1,0,o); tck_cycle(0,0,o);                                   // TLR, RTI
        ir(8'h32);
        dr({7'h10, 32'h1, 2'd2}, dout);                                                   // write 0x10 <- 1
        dr({7'h11, 32'h0, 2'd1}, dout);                                                   // read 0x11, captured mid-flight
        $display("scan 2 captured op %0d (3 = busy)", dout[1:0]);
        repeat (3000) @(posedge clk);
        $display("requests: %0d (the busy scan's read must not be sent: expect 1)", nreq);
        if (nreq == 1) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
