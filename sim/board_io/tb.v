// Unit bench for src/Board_IO.v: register-level RTC write and read, EDID read and checksum, a NACK,
// repeated start, clock stretching, abandoning a stuck transfer, buttons and switches.
`timescale 1ns/1ps
module tb;
    reg clk = 0; always #10 clk = ~clk;
    reg rst = 1;
    reg rb_valid = 0, rb_we = 0; reg [15:0] rb_addr = 0; reg [31:0] rb_wdata = 0; reg [3:0] rb_wstrb = 0;
    wire rb_ack; wire [31:0] rb_rdata;
    reg [6:0] btn = 7'b0000001; reg [3:0] sw = 4'b0101;
    wire scl_low, sda_low, m_sda_low; reg stretch = 0;
    wire scl = !(scl_low || stretch);
    wire sda = !(sda_low || m_sda_low);
    board_io dut (.clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr),
                  .rb_wdata(rb_wdata), .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata),
                  .btn_i(btn), .sw_i(sw), .esp32_tx_i(1'b0), .esp32_strap(), .scl_i(scl), .sda_i(sda), .scl_low(scl_low), .sda_low(sda_low));
    i2c_slave_model #(.TICK(1000000000)) m (.clk(clk), .scl(scl), .sda(sda), .sda_low(m_sda_low));
    integer errs = 0, i, sum;
    reg [31:0] q;
    task wr; input [15:0] a; input [7:0] d; begin
        @(negedge clk); rb_valid = 1; rb_we = 1; rb_addr = a; rb_wdata = d; rb_wstrb = 4'hF;
        @(posedge clk); while (!rb_ack) @(posedge clk);
        @(negedge clk); rb_valid = 0; end endtask
    task rd; input [15:0] a; begin
        @(negedge clk); rb_valid = 1; rb_we = 0; rb_addr = a; rb_wstrb = 0;
        @(posedge clk); while (!rb_ack) @(posedge clk);
        #1 q = rb_rdata; @(negedge clk); rb_valid = 0; end endtask
    task waitdone; integer g; begin
        g = 0; rd (16'h6010);
        while (q[1] && g < 20000) begin rd (16'h6010); g = g + 1; end
        if (q[1]) begin $display ("FAIL transfer never ended"); errs = errs + 1; end
        wr (16'h6010, 8'h01); end endtask
    task txb; input [7:0] d; input [7:0] cr; begin wr (16'h600C, d); wr (16'h6010, cr); waitdone; end endtask
    task rxb; input [7:0] cr; begin wr (16'h6010, cr); waitdone; rd (16'h600C); end endtask
    task check; input [255:0] what; input [31:0] got; input [31:0] exp; begin
        if (got !== exp) begin $display ("FAIL %0s got %h want %h", what, got, exp); errs = errs + 1; end
        else $display ("ok   %0s %h", what, got); end endtask
    initial begin
        repeat (5) @(posedge clk); rst = 0; repeat (5) @(posedge clk);
        rd (16'h8000); check ("gpio id", q, 32'h47504931);
        rd (16'h8004); check ("buttons all up (PWR is active low)", q, 32'h0);
        btn = 7'b1000000; repeat (4) @(posedge clk); rd (16'h8004); check ("PWR and RIGHT pressed", q, 32'h41);
        rd (16'h8008); check ("switches", q, 32'h5);
        rd (16'h601C); check ("i2c id", q, 32'h49324331);
        wr (16'h6000, 8'd3); wr (16'h6004, 8'd0); wr (16'h6008, 8'h80);
        rd (16'h6000); check ("prer", q, 3);
        // RTC: write 0x80 + 0x25 to register 0, read it back through a repeated start
        txb (8'hDE, 8'h90); check ("rtc addr ack", (rd_sr(0)), 0);
        txb (8'h00, 8'h10); txb (8'hA5, 8'h50);
        rd (16'h6010); check ("rtc write acked", q[7], 0); check ("bus free after STOP", q[6], 0);
        check ("register landed", m.rtc[0], 8'hA5);
        txb (8'hDE, 8'h90); txb (8'h00, 8'h10);
        txb (8'hDF, 8'h90);                         // repeated START, read
        rd (16'h6010); check ("rtc read addr ack", q[7], 0);
        rxb (8'h68); check ("rtc read", q, 8'hA5);  // RD + STO + no ack
        // EDID: 128 bytes, header and checksum
        txb (8'hA0, 8'h90); txb (8'h00, 8'h10); txb (8'hA1, 8'h90);
        sum = 0;
        for (i = 0; i < 128; i = i + 1) begin
            rxb (i == 127 ? 8'h68 : 8'h20);
            if (i == 1) check ("edid header", q, 8'hFF);
            sum = sum + q;
        end
        check ("edid checksum", sum & 255, 0);
        // nobody at 0x10
        txb (8'h20, 8'h90); rd (16'h6010); check ("no ack from absent device", q[7], 1);
        txb (8'h00, 8'h40);
        // clock stretching stalls the transfer without losing bits
        stretch = 0; txb (8'hDE, 8'h90);
        wr (16'h600C, 8'h00); wr (16'h6010, 8'h10);
        repeat (20) @(posedge clk); stretch = 1; repeat (300) @(posedge clk);
        rd (16'h6010); check ("still in progress when stretched", q[1], 1);
        stretch = 0; waitdone; rd (16'h6010); check ("acked after stretch", q[7], 0);
        txb (8'h00, 8'h40);
        // a stuck bus is abandoned by clearing EN
        wr (16'h600C, 8'hDE); wr (16'h6010, 8'h90); repeat (10) @(posedge clk); stretch = 1;
        repeat (200) @(posedge clk); wr (16'h6008, 8'h00); repeat (3) @(posedge clk);
        rd (16'h6010); check ("EN=0 ends the transfer", q[1], 0); check ("lines released", {scl_low, sda_low}, 0);
        stretch = 0;
        if (errs == 0) $display ("PASS"); else $display ("FAILED %0d", errs);
        $finish;
    end
    function [31:0] rd_sr; input d; rd_sr = dut.rxack; endfunction
    initial #200000000 begin $display ("FAIL timeout"); $finish; end
endmodule
