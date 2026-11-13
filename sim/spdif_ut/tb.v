// S/PDIF end to end through src/Audio.v: plays NFRAMES stereo samples at 44.1 kHz (RATE 1133,
// 50 MHz) with SPDIF PINS = 1 and SFREQ = SFQ, and writes the ring-2 line as run lengths in
// clocks (runs.txt), plus the samples pushed (samples.txt).  decode.py recovers the stream the
// way a receiver would, from timing alone.
`timescale 1ns/1ps
module tb;
    parameter NFRAMES = 420;
    parameter SFQ = 4'h2;
    reg clk = 0; always #10 clk = ~clk;
    reg rst = 1, rb_valid = 0, rb_we = 0; reg [11:0] rb_addr = 0; reg [31:0] rb_wdata = 0; reg [3:0] rb_wstrb = 0;
    wire rb_ack; wire [31:0] rb_rdata; wire [3:0] al, ar, av;
    audio dut (.clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
               .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata), .audio_l(al), .audio_r(ar), .audio_v(av));
    task wr; input [11:0] a; input [31:0] d; begin
        @(negedge clk); rb_valid = 1; rb_we = 1; rb_addr = a; rb_wdata = d; rb_wstrb = 4'hF;
        @(negedge clk); while (!rb_ack) @(negedge clk);
        rb_valid = 0; rb_we = 0;
    end endtask
    task rd; input [11:0] a; output [31:0] d; begin
        @(negedge clk); rb_valid = 1; rb_we = 0; rb_addr = a;
        @(negedge clk); while (!rb_ack) @(negedge clk);
        d = rb_rdata; rb_valid = 0;
    end endtask
    integer fr, fs, n, run; reg last; reg [31:0] st, s;
    initial begin
        fr = $fopen("runs.txt", "w"); fs = $fopen("samples.txt", "w");
        repeat (5) @(posedge clk); rst = 0;
        wr (12'h01C, {20'b0, SFQ, 4'b0, 4'h1});        // S/PDIF on ring-2 bit 0
        rd (12'h01C, st); if (st != {20'b0, SFQ, 4'b0, 4'h1}) $display("FAIL SPDIF readback %h", st);
        n = 0;
        while (n < 200) begin s = {16'hA000 ^ n[15:0] * 16'd37, 16'h1234 + n[15:0] * 16'd1021}; wr (12'h014, s); $fwrite(fs, "%h\n", s); n = n + 1; end
        wr (12'h004, 32'd1);                             // play
        while (n < NFRAMES) begin
            rd (12'h018, st);
            if (st[8:0] < 9'd200) begin
                s = {16'hA000 ^ n[15:0] * 16'd37, 16'h1234 + n[15:0] * 16'd1021}; wr (12'h014, s); $fwrite(fs, "%h\n", s); n = n + 1;
            end else repeat (500) @(posedge clk);
        end
        repeat (1134 * 210) @(posedge clk);              // drain
        $fclose(fs); $fclose(fr); $display("tb: done"); $finish;
    end
    initial begin run = 0; last = 0; end
    always @(posedge clk) if (!rst) begin
        if (av[0] != last) begin $fwrite(fr, "%0d %0d\n", last, run); run = 1; last = av[0]; end
        else run = run + 1;
        if (av[3:1] != 3'b0) $display("FAIL: PINS = 1 but audio_v = %b", av);
    end
endmodule
