// sim/sdh_ut/tb.v: src/Sd_Host.v against sim/common/sd_native_model.v (run.sh)
`timescale 1ns/1ps
`default_nettype none
module tb;
    reg clk = 0, rst = 1;
    always #10 clk = !clk;                       // 50 MHz
    reg         rb_valid = 0, rb_we = 0;
    reg  [11:0] rb_addr = 0;
    reg  [31:0] rb_wdata = 0;
    wire        rb_ack;
    wire [31:0] rb_rdata;
    reg         esp32_en = 0, esp32_strap = 0;
    wire        clk_o, cmd_o, cmd_oe, spi_miso;
    wire [3:0]  dat_o, dat_oe;
    wire        m_cmd_o, m_cmd_oe;
    wire [3:0]  m_dat_o, m_dat_oe;
    // the bus: open lines float high (pull-ups)
    wire cmd_line = cmd_oe ? cmd_o : m_cmd_oe ? m_cmd_o : 1'b1;
    wire [3:0] dat_line;
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : dl
        assign dat_line[g] = dat_oe[g] ? dat_o[g] : m_dat_oe[g] ? m_dat_o[g] : 1'b1;
    end endgenerate
    integer fails = 0, conflicts = 0;
    always @(posedge clk) begin
        if (cmd_oe && m_cmd_oe) conflicts = conflicts + 1;
        if ((dat_oe & m_dat_oe) != 0) conflicts = conflicts + 1;
    end

    sd_host dut (.clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr),
                 .rb_wdata(rb_wdata), .rb_wstrb(4'hF), .rb_ack(rb_ack), .rb_rdata(rb_rdata),
                 .spi_sclk(1'b0), .spi_mosi(1'b1), .spi_cs_n(1'b1), .spi_miso(spi_miso),
                 .esp32_en(esp32_en), .esp32_strap(esp32_strap),
                 .clk_o(clk_o), .cmd_o(cmd_o), .cmd_oe(cmd_oe), .cmd_i(cmd_line),
                 .dat_o(dat_o), .dat_oe(dat_oe), .dat_i(dat_line));
    sd_native_model #(.BLOCKS(2048)) card (.clk(clk), .sck(clk_o), .cmd_i(cmd_line), .cmd_o(m_cmd_o),
                 .cmd_oe(m_cmd_oe), .dat_i(dat_line), .dat_o(m_dat_o), .dat_oe(m_dat_oe));

    // ---- wire monitor: host-driven CMD frames and DAT0 bits, sampled on rising SD clock ----
    reg clk_oq = 0;
    reg [47:0] mon; integer mon_n = 0; reg [47:0] last_frame;
    reg [4200:0] dmon; integer dmon_n = 0;
    always @(posedge clk) begin
        clk_oq <= clk_o;
        if (clk_o && !clk_oq) begin
            if (cmd_oe) begin mon = {mon[46:0], cmd_o}; mon_n = mon_n + 1;
                              if (mon_n == 48) begin last_frame = mon; mon_n = 0; end end
            else mon_n = 0;
            if (dat_oe[0]) begin dmon = {dmon[4199:0], dat_o[0]}; dmon_n = dmon_n + 1; end
        end
    end

    integer dbg = 0;
    always @(posedge clk) if (dbg != 0 && dut.fall && dut.dst != 0)
        $display ("  fall dst %0d dcnt %0d dat_q %h byt %h dsh %h line %h", dut.dst, dut.dcnt, dut.dat_q, dut.byt, dut.dsh, dat_line);
    task check (input [8*64-1:0] what, input ok);
        begin if (!ok) begin fails = fails + 1; $display ("FAIL %0s", what); end
              else $display ("ok   %0s", what); end
    endtask
    task wr (input [11:0] a, input [31:0] d);
        begin @(posedge clk); rb_valid <= 1; rb_we <= 1; rb_addr <= a; rb_wdata <= d;
              @(posedge clk); while (!rb_ack) @(posedge clk); rb_valid <= 0; @(posedge clk); end
    endtask
    reg [31:0] rv;
    task rd (input [11:0] a);
        begin @(posedge clk); rb_valid <= 1; rb_we <= 0; rb_addr <= a;
              @(posedge clk); while (!rb_ack) @(posedge clk); rv = rb_rdata; rb_valid <= 0; @(posedge clk); end
    endtask
    // issue a command, wait for it; returns STATUS in rv
    task cmd (input [5:0] idx, input [31:0] a, input [1:0] rt, input nocrc, input data, input wrd);
        begin
            wr (12'h08, a);
            wr (12'h0C, {19'b0, wrd, data, nocrc, rt, 2'b0, idx});
            rd (12'h10);
            while (rv[0]) rd (12'h10);
        end
    endtask
    task wait_dat0_high; begin rd (12'h10); while (!rv[9]) rd (12'h10); end endtask
    integer k, b, bad;
    reg [31:0] w;
    reg [31:0] ctrl;
    initial begin
        if ($test$plusargs ("vcd")) begin $dumpfile ("sdh.vcd"); $dumpvars (0, tb); end
        repeat (5) @(posedge clk); rst = 0;
        rd (12'h00); check ("ID", rv == 32'h53444831);
        rd (12'h04); check ("CTRL resets to WPROT, DIV 62, SPI mode", rv == 32'h003E0004);
        // the ESP32 interlock: MODE without the ESP32 in reset is not native
        esp32_en = 1;
        wr (12'h04, 32'h0001000D);           // MODE, WPROT, CLKEN, DIV 1
        rd (12'h10); check ("ESP32 running: not native", !rv[12]);
        check ("ESP32 running: pins are SPI0's", clk_o == 1'b0 && cmd_oe && dat_oe == 4'b1000);
        esp32_en = 0; esp32_strap = 1;
        rd (12'h10); check ("strap held: not native", !rv[12]);
        esp32_strap = 0;
        rd (12'h10); check ("native", rv[12]);
        wr (12'h04, 32'h003E000D);           // 400 kHz for init
        repeat (2000) @(posedge clk);        // 74+ clocks
        cmd (6'd0, 32'h0, 2'd0, 0, 0, 0);
        check ("CMD0 done", rv[1] && !rv[2]);
        check ("CMD0 on the wire: 40 00 00 00 00 95", last_frame == 48'h400000000095);
        cmd (6'd8, 32'h1AA, 2'd1, 0, 0, 0);
        check ("CMD8 on the wire ends in 87", last_frame[7:0] == 8'h87 && last_frame[47:40] == 8'h48);
        rd (12'h14); check ("CMD8 R7 echoes 1AA", rv[11:0] == 12'h1AA);
        rd (12'h10); check ("CMD8 response CRC ok", !rv[3] && !rv[2]);
        cmd (6'd5, 32'h0, 2'd1, 1, 0, 0);
        check ("CMD5 (SDIO probe) times out", rv[2]);
        k = 0;
        rv = 0;
        while (k < 10 && !rv[31]) begin
            cmd (6'd55, 32'h0, 2'd1, 0, 0, 0);
            cmd (6'd41, 32'h40FF8000, 2'd1, 1, 0, 0);
            rd (12'h14); k = k + 1;
        end
        check ("ACMD41 ready, CCS", rv[31] && rv[30]);
        cmd (6'd2, 32'h0, 2'd2, 1, 0, 0);
        rd (12'h14); check ("CMD2 CID: MID 03, OEM 'SD'", rv[31:8] == 24'h035344);
        rd (12'h20); check ("CID ends with its CRC7 and the end bit", rv[0] == 1'b1);
        cmd (6'd3, 32'h0, 2'd1, 0, 0, 0);
        rd (12'h14); check ("CMD3 RCA 4321", rv[31:16] == 16'h4321);
        cmd (6'd9, 32'h43210000, 2'd2, 1, 0, 0);
        rd (12'h14); check ("CSD v2", rv[31:30] == 2'b01);
        rd (12'h1C); w = rv; rd (12'h18);
        check ("CSD C_SIZE 1 (1 MiB card)", {rv[5:0], w[31:16]} == 22'd1);
        cmd (6'd7, 32'h43210000, 2'd1, 0, 0, 0);
        rd (12'h10); check ("CMD7 select", rv[1] && !rv[2] && !rv[3]);
        wr (12'h04, 32'h0001000D);           // 12.5 MHz
        // ACMD51: the 8-byte SCR, 1-bit
        wr (12'h24, 8); wr (12'h28, 1);
        cmd (6'd55, 32'h43210000, 2'd1, 0, 0, 0);
        dbg = 1;
        cmd (6'd51, 32'h0, 2'd1, 0, 1, 0);
        rd (12'h10); while (!rv[8] && !rv[7]) rd (12'h10);
        dbg = 0;
        rd (12'h30); $display ("  SCR %08x", rv); check ("SCR word 0 (1-bit)", rv == 32'h00803502);
        rd (12'h30);
        rd (12'h10); check ("SCR: done, no CRC error", rv[5] && !rv[6] && !rv[7] && !rv[4]);
        // ACMD6: 4-bit
        cmd (6'd55, 32'h43210000, 2'd1, 0, 0, 0);
        cmd (6'd6, 32'h2, 2'd1, 0, 0, 0);
        wr (12'h04, 32'h0001000F);           // WIDE
        // CMD17: block 5
        wr (12'h24, 512); wr (12'h28, 1);
        cmd (6'd17, 32'd5, 2'd1, 0, 1, 0);
        rd (12'h10); while (!rv[8] && !rv[7]) rd (12'h10);
        bad = 0;
        for (k = 0; k < 128; k = k + 1) begin
            rd (12'h30);
            w = {8'(k*4+3) ^ 8'd5, 8'(k*4+2) ^ 8'd5, 8'(k*4+1) ^ 8'd5, 8'(k*4) ^ 8'd5};
            if (rv != w) begin if (bad == 0) $display ("  word %0d: %08x want %08x", k, rv, w); bad = bad + 1; end
        end
        check ("CMD17 4-bit block 5 contents", bad == 0);
        rd (12'h10); check ("CMD17 done, CRC ok", rv[5] && !rv[6] && !rv[4]);
        // CMD18: blocks 9..11, the clock held between them
        wr (12'h28, 3);
        cmd (6'd18, 32'd9, 2'd1, 0, 1, 0);
        bad = 0;
        for (b = 0; b < 3; b = b + 1) begin
            rd (12'h10); while (!rv[8] && !rv[7]) rd (12'h10);
            repeat (3000) @(posedge clk);     // slow software: the clock must hold
            for (k = 0; k < 128; k = k + 1) begin
                rd (12'h30);
                w = {8'(k*4+3) ^ 8'(9+b), 8'(k*4+2) ^ 8'(9+b), 8'(k*4+1) ^ 8'(9+b), 8'(k*4) ^ 8'(9+b)};
                if (rv != w) begin if (bad == 0) $display ("  blk %0d word %0d: %08x want %08x", b, k, rv, w); bad = bad + 1; end
            end
        end
        check ("CMD18 3 blocks with a slow reader", bad == 0);
        rd (12'h10); check ("CMD18 done, no CRC error", rv[5] && !rv[6] && rv[31:16] == 0);
        cmd (6'd12, 32'h0, 2'd1, 0, 0, 0);
        wait_dat0_high;
        check ("CMD12", 1);
        // write protect: CMD24 refused, DAT never driven
        wr (12'h28, 1);
        cmd (6'd24, 32'd7, 2'd1, 0, 1, 1);
        rd (12'h10); check ("WPROT refuses CMD24", rv[10] && rv[1] && !rv[4]);
        cmd (6'd38, 32'd0, 2'd1, 0, 0, 0);
        rd (12'h10); check ("WPROT refuses CMD38 (erase)", rv[10]);
        // write (sim only): block 7 = all 0xFF in 1-bit mode, then 4-bit block 8
        wr (12'h04, 32'h0001000B);           // MODE, WIDE, CLKEN, no WPROT
        cmd (6'd55, 32'h43210000, 2'd1, 0, 0, 0);
        cmd (6'd6, 32'h0, 2'd1, 0, 0, 0);
        wr (12'h04, 32'h00010009);           // 1-bit
        wr (12'h28, 1);
        dmon_n = 0;
        cmd (6'd24, 32'd7, 2'd1, 0, 1, 1);
        for (k = 0; k < 128; k = k + 1) wr (12'h30, 32'hFFFFFFFF);
        rd (12'h10); while (rv[4]) rd (12'h10);
        check ("CMD24 1-bit: done, status token ok", rv[5] && !rv[11] && !rv[7]);
        check ("CRC16 of 512 x FF on the wire is 7FA1", dmon_n == 1 + 4096 + 16 + 1 && dmon[16:1] == 16'h7FA1);
        cmd (6'd55, 32'h43210000, 2'd1, 0, 0, 0);
        cmd (6'd6, 32'h2, 2'd1, 0, 0, 0);
        wr (12'h04, 32'h0001000B);
        wr (12'h28, 2);
        cmd (6'd25, 32'd7, 2'd1, 0, 1, 1);
        for (b = 0; b < 2; b = b + 1) begin
            rd (12'h10); while (!rv[8] && rv[4]) rd (12'h10);
            for (k = 0; k < 128; k = k + 1) wr (12'h30, 32'hA5000000 + b * 32'h10000 + k);
        end
        rd (12'h10); while (rv[4]) rd (12'h10);
        check ("CMD25 4-bit 2 blocks: done, status ok", rv[5] && !rv[11] && !rv[7]);
        cmd (6'd12, 32'h0, 2'd1, 0, 0, 0);
        wait_dat0_high;
        wr (12'h28, 2);
        cmd (6'd18, 32'd7, 2'd1, 0, 1, 0);
        bad = 0;
        for (b = 0; b < 2; b = b + 1) begin
            rd (12'h10); while (!rv[8] && !rv[7]) rd (12'h10);
            for (k = 0; k < 128; k = k + 1) begin
                rd (12'h30); if (rv != 32'hA5000000 + b * 32'h10000 + k) begin
                    if (bad < 4) $display ("  blk %0d word %0d: %08x want %08x", b, k, rv, 32'hA5000000 + b * 32'h10000 + k);
                    bad = bad + 1; end
            end
        end
        check ("written blocks 7, 8 read back", bad == 0);
        cmd (6'd12, 32'h0, 2'd1, 0, 0, 0);
        wait_dat0_high;
        // a corrupted CRC16 is caught
        wr (12'h28, 1);
        card.badcrc = card.nsent + 1;
        cmd (6'd17, 32'd3, 2'd1, 0, 1, 0);
        rd (12'h10); while (!rv[8] && !rv[7]) rd (12'h10);
        for (k = 0; k < 128; k = k + 1) rd (12'h30);
        rd (12'h10); check ("corrupted data CRC flagged", rv[6]);
        wr (12'h28, 1);
        card.badend = card.nsent + 1;
        cmd (6'd17, 32'd3, 2'd1, 0, 1, 0);
        rd (12'h10); while (!rv[8] && !rv[7]) rd (12'h10);
        for (k = 0; k < 128; k = k + 1) rd (12'h30);
        rd (12'h10); check ("missing end bit flagged", rv[6]);
        // abort, then leaving native mode restores the SPI pins
        wr (12'h34, 0);
        wr (12'h04, 32'h00010004);
        rd (12'h10); check ("SPI mode again", !rv[12] && cmd_oe && dat_oe == 4'b1000);
        check ("host and card never drove a line together", conflicts == 0);
        $display ("%0d failures", fails);
        if (fails == 0) $display ("SDH_UT PASS"); else $display ("SDH_UT FAIL");
        $finish;
    end
    initial begin #400000000; $display ("SDH_UT FAIL timeout"); $finish; end
endmodule
