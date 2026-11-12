// Unit bench for src/JtaggDtm.bsv through src/ecp5_jtag_model.v (the ECP5 configuration TAP as
// JTAGG shows it), with a fake debug module answering Control_Req.  Checks: IDCODE at IR 0xE0,
// dtmcs at ER2 (version 1, abits 7, idle 1), dmi write then read back at ER1, dmistat busy (3)
// when a scan lands while a request is in flight and its clearing by dmireset, and that the TAP's
// own data registers (IDCODE) never start a DMI request.
//   sim/jtagg/run.sh  (needs build/<b>/verilog/mkJtaggDtm.v from a bsc build with JTAG_TAP)
`timescale 1ns/1ps
module tb_jtagg;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                       // 50 MHz
    reg tck = 0, tms = 1, tdi = 0;
    wire tdo;
    wire jtck, jtdi, jshift, jupdate, jrstn, jce1, jce2, jrti1, jrti2, jtdo;
    ecp5_jtag_model tap (.TCK(tck), .TMS(tms), .TDI(tdi), .TDO(tdo),
        .JTCK(jtck), .JTDI(jtdi), .JSHIFT(jshift), .JUPDATE(jupdate), .JRSTN(jrstn),
        .JCE1(jce1), .JCE2(jce2), .JRTI1(jrti1), .JRTI2(jrti2), .JTDO1(jtdo), .JTDO2(jtdo));

    wire [135:0] req;                            // {op[7:0], arg1[63:0], arg2[63:0]}
    wire req_rdy, rsp_rdy;
    reg  req_en = 0, rsp_en = 0;
    reg  [71:0] rsp = 0;                         // {status[7:0], result[63:0]}
    mkJtaggDtm dut (.CLK(clk), .RST_N(rst_n),
        .pins_v({jce2, jce1, jrstn, jupdate, jshift, jtdi, jtck}),
        .tdo(jtdo),
        .client_request_get(req), .RDY_client_request_get(req_rdy), .EN_client_request_get(req_en),
        .client_response_put(rsp), .EN_client_response_put(rsp_en), .RDY_client_response_put(rsp_rdy));

    // fake debug module: 128 words; answers after `delay` clocks
    reg [31:0] mem [0:127];
    integer delay = 4, nreq = 0, k;
    initial for (k = 0; k < 128; k = k + 1) mem[k] = 32'h1000 + k;
    reg busy = 0; integer cnt = 0; reg [135:0] cur;
    always @(posedge clk) begin
        req_en <= 0; rsp_en <= 0;
        if (!busy && req_rdy && !req_en) begin req_en <= 1; cur <= req; busy <= 1; cnt <= delay; nreq <= nreq + 1; end
        else if (busy && !req_en) begin
            if (cnt > 0) cnt <= cnt - 1;
            else if (rsp_rdy) begin
                busy <= 0; rsp_en <= 1;
                if (cur[135:128] == 8'd11) begin mem[cur[70:64]] <= cur[31:0]; rsp <= 72'h0; end
                else rsp <= {8'h00, 32'h0, mem[cur[70:64]]};
            end
        end
    end

    integer errs = 0;
    task check(input [8*48-1:0] what, input [63:0] got, input [63:0] exp);
        if (got !== exp) begin errs = errs + 1; $display("FAIL %0s: got %h exp %h", what, got, exp); end
        else $display("ok   %0s = %h", what, got);
    endtask
    // TCK period 2 us (the FT231X bit-bangs slower than this)
    task clk1(input m, input d, output o);
        begin tms = m; tdi = d; #1000; o = tdo; tck = 1; #1000; tck = 0; end
    endtask
    reg o;
    task tlr; integer i; begin for (i = 0; i < 6; i = i + 1) clk1(1, 0, o); clk1(0, 0, o); end endtask
    task irscan(input [7:0] v);
        integer i; begin
            clk1(1, 0, o); clk1(1, 0, o); clk1(0, 0, o); clk1(0, 0, o);   // Sel-DR, Sel-IR, Cap-IR, Shift-IR
            for (i = 0; i < 8; i = i + 1) clk1(i == 7, v[i], o);
            clk1(1, 0, o); clk1(0, 0, o);                                  // Update-IR, RTI
        end
    endtask
    task drscan(input integer n, input [63:0] v, output [63:0] r);
        integer i; begin
            r = 0;
            clk1(1, 0, o); clk1(0, 0, o); clk1(0, 0, o);                   // Sel-DR, Cap-DR, Shift-DR
            for (i = 0; i < n; i = i + 1) begin clk1(i == n - 1, v[i], o); r[i] = o; end
            clk1(1, 0, o); clk1(0, 0, o);                                  // Update-DR, RTI
        end
    endtask
    function [63:0] dmi(input [6:0] a, input [31:0] d, input [1:0] op); dmi = {a, d, op}; endfunction

    reg [63:0] r;
    integer n0;
    initial begin
        #200 rst_n = 1; #200;
        tlr;
        drscan(32, 0, r);                  check("IDCODE after reset", r, 64'h41113043);
        irscan(8'hE0); drscan(32, 0, r);   check("IDCODE at IR 0xE0", r, 64'h41113043);
        check("no DMI request from the TAP's own registers", nreq, 0);
        irscan(8'h38); drscan(32, 0, r);   check("dtmcs", r, 64'h00001071);
        irscan(8'h32);
        drscan(41, dmi(7'h10, 32'hdeadbeef, 2), r);
        drscan(41, dmi(7'h10, 0, 1), r);   check("dmi after write: op", r[1:0], 0);
        drscan(41, dmi(0, 0, 0), r);       check("dmi read 0x10", r, {7'h10, 32'hdeadbeef, 2'b00});
        drscan(41, dmi(7'h44, 0, 1), r);
        drscan(41, dmi(0, 0, 0), r);       check("dmi read 0x44", r, {7'h44, 32'h00001044, 2'b00});
        check("requests so far", nreq, 3);
        delay = 400000;                    // the next request stays in flight for 8 ms
        drscan(41, dmi(7'h11, 0, 1), r);
        drscan(41, dmi(0, 0, 0), r);       check("scan while in flight: busy", r[1:0], 3);
        n0 = nreq;
        drscan(41, dmi(7'h12, 0, 1), r);   // ignored: busy is sticky
        irscan(8'h38); drscan(32, 0, r);   check("dtmcs dmistat busy", r[11:10], 3);
        #9000000;                          // the request finishes
        drscan(32, 0, r);                  check("dtmcs still busy (sticky)", r[11:10], 3);
        drscan(32, 64'h10000, r);          // dmireset
        drscan(32, 0, r);                  check("dtmcs after dmireset", r, 64'h00001071);
        check("no request while busy", nreq, n0);
        delay = 4;
        irscan(8'h32); drscan(41, dmi(0, 0, 0), r);
                                           check("dmi data from the finished read", r, {7'h11, 32'h00001011, 2'b00});
        tlr; drscan(32, 0, r);             check("IDCODE after a second reset", r, 64'h41113043);
        if (errs) $display("jtagg: FAIL (%0d)", errs); else $display("jtagg: PASS");
        $finish;
    end
endmodule
