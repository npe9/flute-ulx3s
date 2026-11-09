// Unit bench for src/Audio.v: reset values and silence, volume, FIFO order, drop and underrun, and
// the sigma-delta's mean level against the sample.
`timescale 1ns/1ps
module tb;
    reg clk = 0; always #10 clk = ~clk;
    reg rst = 1, rb_valid = 0, rb_we = 0; reg [11:0] rb_addr = 0; reg [31:0] rb_wdata = 0; reg [3:0] rb_wstrb = 0;
    wire rb_ack; wire [31:0] rb_rdata; wire [3:0] al, ar;
    audio dut (.clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
               .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata), .audio_l(al), .audio_r(ar));
    integer errs = 0, i, sum_l, sum_r; reg [31:0] q;
    task wr; input [11:0] a; input [31:0] d; begin
        @(negedge clk); rb_valid = 1; rb_we = 1; rb_addr = a; rb_wdata = d; rb_wstrb = 4'hF;
        @(posedge clk); while (!rb_ack) @(posedge clk);
        @(negedge clk); rb_valid = 0; end endtask
    task rd; input [11:0] a; begin
        @(negedge clk); rb_valid = 1; rb_we = 0; rb_addr = a; rb_wstrb = 0;
        @(posedge clk); while (!rb_ack) @(posedge clk);
        #1 q = rb_rdata; @(negedge clk); rb_valid = 0; end endtask
    task check; input [255:0] w; input [31:0] g; input [31:0] e; begin
        if (g !== e) begin $display ("FAIL %0s got %h want %h", w, g, e); errs = errs + 1; end
        else $display ("ok   %0s %h", w, g); end endtask
    task mean; input integer n; begin
        sum_l = 0; sum_r = 0;
        for (i = 0; i < n; i = i + 1) begin @(posedge clk); #1 sum_l = sum_l + al; sum_r = sum_r + ar; end end endtask
    // n * mean(code) * 4096, in offset binary, within 1 code-step over the window
    task near; input [255:0] w; input integer sum; input integer n; input integer u; integer got; begin
        got = (sum * 4096) / n;
        if (got < u - 64 || got > u + 64) begin $display ("FAIL %0s mean %0d want %0d", w, got, u); errs = errs + 1; end
        else $display ("ok   %0s mean %0d want %0d", w, got, u); end endtask
    initial begin
        repeat (5) @(posedge clk); rst = 0; repeat (20) @(posedge clk);
        rd (12'h000); check ("id", q, 32'h41554431);
        rd (12'h008); check ("volume resets to mute", q, 0);
        check ("silent at reset", {al, ar}, 8'h88);
        wr (12'h004, 2); mean (4096); near ("tone on but muted", sum_l, 4096, 32768);
        wr (12'h004, 0); wr (12'h008, 8); wr (12'h00C, 3);          // a sample every 4 clocks
        rd (12'h00C); check ("rate", q, 3);
        // order: push a known ramp with the player stopped, then play it
        for (i = 0; i < 256; i = i + 1) wr (12'h014, 32'h2000_1000 + (i * 32'h0001_0001));
        rd (12'h018); check ("full", q[8:0], 256);
        wr (12'h014, 32'hDEADBEEF); rd (12'h018); check ("drop set", q[16], 1);
        wr (12'h018, 0); rd (12'h018); check ("sticky cleared", q[17:16], 0);
        check ("first slot", dut.mem[0], {16'h2000, 16'h1000}); check ("last slot", dut.mem[255], {16'h20FF, 16'h10FF});
        begin : order
            reg [31:0] exp; integer n; exp = {16'h2000, 16'h1000}; n = 0;
            wr (12'h004, 1);
            while (n < 256) begin
                @(posedge clk);
                if (dut.pop) begin
                    #1 if (dut.cur !== exp) begin $display ("FAIL order at %0d got %h want %h", n, dut.cur, exp); errs = errs + 1; end
                    exp = exp + 32'h0001_0001; n = n + 1;
                end
            end
            $display ("ok   256 samples played in order");
        end
        repeat (40) @(posedge clk);
        rd (12'h018); check ("drained", q[8:0], 0); check ("underrun set", q[17], 1);
        check ("last sample held", dut.cur, {16'h20FF, 16'h10FF});
        // the sigma-delta's mean is the sample's level, in offset binary
        wr (12'h014, {16'hC000, 16'h3123}); repeat (50) @(posedge clk);
        mean (40960);
        near ("mean left", sum_l, 40960, 32'h3123 + 32768); near ("mean right", sum_r, 40960, 32768 - 16384);
        wr (12'h008, 7); repeat (20) @(posedge clk); mean (40960);
        near ("volume 7 halves it", sum_l, 40960, (32'h3123 >> 1) + 32768);
        wr (12'h008, 0); repeat (20) @(posedge clk); mean (4096); near ("volume 0 mutes", sum_l, 4096, 32768);
        if (errs == 0) $display ("PASS"); else $display ("FAILED %0d", errs);
        $finish;
    end
    initial #50000000 begin $display ("FAIL timeout"); $finish; end
endmodule
