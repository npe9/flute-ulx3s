// ================================================================
// sd_spi_model.v -- behavioral SDHC card in SPI mode for the Verilator benches.
//
// Synchronous to the bench clock: samples SCK/MOSI/CS every clk, so SCK must be at most clk/2
// (the SPI host's fastest setting).  Mode 0: MOSI sampled on rising SCK, MISO changes after
// falling SCK.  Backing store: BLOCKS x 512 bytes, preloaded with +sd_image=<hex file>
// ($readmemh, one byte per line) when given, else a pattern (byte i = i[7:0] ^ block number,
// 0x55AA at 510 of block 0); +sd_none makes the card absent
// (MISO stays 1); +sd_trace=1 logs CS edges and commands, +sd_trace=2 also every byte.  Commands: CMD0/1/5(illegal)/6/8/9/10/12/13/16/17/18/24/25/55/58/59,
// ACMD13/41/51; data blocks carry a correct CRC16 (Linux mmc_spi checks it).
// ================================================================
`default_nettype none
module sd_spi_model #(parameter integer BLOCKS = 2048) (
    input  wire clk,
    input  wire sck,
    input  wire mosi,
    input  wire cs_n,
    output reg  miso
);
    localparam integer NBYTES = BLOCKS * 512;
    reg [7:0] mem [0:NBYTES-1];

    // output queue
    reg [7:0]  outq [0:2047];
    reg [10:0] oq_h, oq_t;
    wire [10:0] oq_n = oq_t - oq_h;

    reg       sck_q, cs_q;
    reg [7:0] rx_sh;
    reg [2:0] bitcnt;         // bits received in the current byte
    reg [7:0] tx_sh;

    // command parser / card state
    reg [2:0]  cidx;          // bytes of the current command collected (0 = waiting for 01xxxxxx)
    reg [47:0] cbuf;
    reg        idle, app, absent;
    reg [3:0]  acmd41_n;
    // multi-block read
    reg        mrd;
    reg [31:0] mrd_lba;
    // write states: 0 none, 1 wait token (single), 2 wait token (multi), 3 data
    reg [1:0]  wst;
    reg        wmulti;
    reg [31:0] w_lba;
    reg [9:0]  w_n;           // bytes of block + CRC received
    integer    i;
    integer    trace;
    reg [63:0] cyc;
    reg [8*256-1:0] fname;

    function [15:0] crc16_byte (input [15:0] c, input [7:0] b);
        integer k; reg [15:0] r; reg x;
        begin
            r = c;
            for (k = 7; k >= 0; k = k - 1) begin
                x = r[15] ^ b[k];
                r = {r[14:0], 1'b0} ^ (x ? 16'h1021 : 16'h0000);
            end
            crc16_byte = r;
        end
    endfunction

    task push (input [7:0] b);
        begin outq[oq_t] = b; oq_t = oq_t + 1; end
    endtask

    // data block: token, bytes from mem (or a constant pattern src), CRC16
    task push_block_mem (input [31:0] byte_addr, input integer n);
        integer k; reg [15:0] c; reg [7:0] b;
        begin
            push (8'hFF); push (8'hFE);
            c = 16'h0000;
            for (k = 0; k < n; k = k + 1) begin
                b = (byte_addr + k < NBYTES) ? mem[byte_addr + k] : 8'h00;
                push (b); c = crc16_byte (c, b);
            end
            push (c[15:8]); push (c[7:0]);
        end
    endtask

    reg [7:0] reg_blk [0:63];
    task push_block_reg (input integer n);
        integer k; reg [15:0] c;
        begin
            push (8'hFF); push (8'hFE);
            c = 16'h0000;
            for (k = 0; k < n; k = k + 1) begin push (reg_blk[k]); c = crc16_byte (c, reg_blk[k]); end
            push (c[15:8]); push (c[7:0]);
        end
    endtask

    // C_SIZE: capacity = (C_SIZE + 1) * 512 KiB
    wire [21:0] c_size = (BLOCKS / 1024) - 1;

    task exec_cmd (input [5:0] cmd, input [31:0] arg);
        integer k;
        reg [7:0] r1;
        begin
            r1 = idle ? 8'h01 : 8'h00;
            if (trace != 0) $display ("[sd] %0d %sCMD%0d arg %08x idle %b", cyc, app ? "A" : "", cmd, arg, idle);
            push (8'hFF);                                  // NCR
            if (app) begin
                app = 1'b0;
                case (cmd)
                    6'd41: begin
                        if (acmd41_n < 2) acmd41_n = acmd41_n + 1; else idle = 1'b0;
                        push (idle ? 8'h01 : 8'h00);
                    end
                    6'd51: begin                           // SCR: SD 2.0, 1/4-bit bus
                        push (r1);
                        for (k = 0; k < 8; k = k + 1) reg_blk[k] = 8'h00;
                        reg_blk[0] = 8'h02; reg_blk[1] = 8'h35; reg_blk[2] = 8'h80;
                        push_block_reg (8);
                    end
                    6'd13: begin                           // SD status (R2 + 64 bytes)
                        push (r1); push (8'h00);
                        for (k = 0; k < 64; k = k + 1) reg_blk[k] = 8'h00;
                        push_block_reg (64);
                    end
                    default: begin push (r1); end          // ACMD22/23 etc.: plain R1
                endcase
            end
            else case (cmd)
                6'd0:  begin idle = 1'b1; acmd41_n = 0; mrd = 1'b0; wst = 0; push (8'h01); end
                6'd8:  begin push (r1); push (8'h00); push (8'h00); push ({4'h0, arg[11:8]}); push (arg[7:0]); end
                6'd55: begin app = 1'b1; push (r1); end
                6'd58: begin push (r1); push (idle ? 8'h40 : 8'hC0); push (8'hFF); push (8'h80); push (8'h00); end
                6'd59, 6'd16: push (r1);
                6'd13: begin push (r1); push (8'h00); end
                6'd9: begin                                // CSD v2.0
                    push (r1);
                    reg_blk[0] = 8'h40; reg_blk[1] = 8'h0E; reg_blk[2] = 8'h00; reg_blk[3] = 8'h32;
                    reg_blk[4] = 8'h5B; reg_blk[5] = 8'h59; reg_blk[6] = 8'h00;
                    reg_blk[7] = {2'b00, c_size[21:16]}; reg_blk[8] = c_size[15:8]; reg_blk[9] = c_size[7:0];
                    reg_blk[10] = 8'h7F; reg_blk[11] = 8'h80; reg_blk[12] = 8'h0A; reg_blk[13] = 8'h40;
                    reg_blk[14] = 8'h00; reg_blk[15] = 8'h01;
                    push_block_reg (16);
                end
                6'd10: begin                               // CID
                    push (r1);
                    reg_blk[0] = 8'h03; reg_blk[1] = "S"; reg_blk[2] = "D"; reg_blk[3] = "S";
                    reg_blk[4] = "I"; reg_blk[5] = "M"; reg_blk[6] = "0"; reg_blk[7] = "1";
                    reg_blk[8] = 8'h10; reg_blk[9] = 8'h12; reg_blk[10] = 8'h34; reg_blk[11] = 8'h56;
                    reg_blk[12] = 8'h78; reg_blk[13] = 8'h01; reg_blk[14] = 8'h9A; reg_blk[15] = 8'h01;
                    push_block_reg (16);
                end
                6'd6: begin                                // SWITCH_FUNC: no high-speed support
                    push (r1);
                    for (k = 0; k < 64; k = k + 1) reg_blk[k] = 8'h00;
                    reg_blk[13] = 8'h01;                   // group 1 supports function 0 only
                    push_block_reg (64);
                end
                6'd17: begin push (r1); push_block_mem (arg * 512, 512); end
                6'd18: begin push (r1); push_block_mem (arg * 512, 512); mrd = 1'b1; mrd_lba = arg + 1; end
                6'd12: begin oq_h = oq_t; mrd = 1'b0; push (8'hFF); push (8'h00); end
                6'd24: begin push (r1); wst = 1; wmulti = 1'b0; w_lba = arg; end
                6'd25: begin push (r1); wst = 2; wmulti = 1'b1; w_lba = arg; end
                default: push (r1 | 8'h04);                // illegal command (CMD1, CMD5, ...)
            endcase
        end
    endtask

    reg [15:0] w_crc;
    reg [7:0]  wbuf [0:511];

    task got_byte (input [7:0] b);
        integer k;
        begin
            if (trace > 1) $display ("[sd] %0d rx %02x tx-q %0d", cyc, b, oq_n);
            if (wst == 1 || wst == 2) begin
                if (b == 8'hFE || (wst == 2 && b == 8'hFC)) begin wst = 3; w_n = 0; w_crc = 0; end
                else if (wst == 2 && b == 8'hFD) begin wst = 0; push (8'hFF); push (8'h00); push (8'h00); end
            end
            else if (wst == 3) begin
                if (w_n < 512) begin wbuf[w_n] = b; w_crc = crc16_byte (w_crc, b); end
                w_n = w_n + 1;
                if (w_n == 514) begin
                    for (k = 0; k < 512; k = k + 1)
                        if (w_lba * 512 + k < NBYTES) mem[w_lba * 512 + k] = wbuf[k];
                    push (8'h05); push (8'h00); push (8'h00); push (8'h00);   // accepted, busy
                    w_lba = w_lba + 1;
                    wst = wmulti ? 2 : 0;
                end
            end
            else if (cidx == 0) begin
                if (b[7:6] == 2'b01) begin cbuf = {b, 40'b0}; cidx = 1; end
            end
            else begin
                cbuf = cbuf | ({40'b0, b} << (8 * (5 - cidx)));
                cidx = cidx + 1;
                if (cidx == 6) begin
                    cidx = 0;
                    exec_cmd (cbuf[45:40], cbuf[39:8]);
                end
            end
        end
    endtask

    initial begin
        // default contents: byte i = i[7:0] ^ block number, MBR signature in block 0
        for (i = 0; i < NBYTES; i = i + 1) mem[i] = i[7:0] ^ i[16:9];
        mem[510] = 8'h55; mem[511] = 8'hAA;
        absent = $test$plusargs ("sd_none");
        if (! $value$plusargs ("sd_trace=%d", trace)) trace = 0;
        cyc = 0;
        if ($value$plusargs ("sd_image=%s", fname)) $readmemh (fname, mem);
        oq_h = 0; oq_t = 0; sck_q = 0; cs_q = 1; bitcnt = 0; tx_sh = 8'hFF; miso = 1'b1;
        cidx = 0; idle = 1'b1; app = 1'b0; acmd41_n = 0; mrd = 1'b0; wst = 0; wmulti = 1'b0;
    end

    // Model state is updated with blocking assignments (only this block reads it); MISO,
    // which the DUT samples, is non-blocking.
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (trace != 0 && cs_n != cs_q)
            $display ("[sd] %0d cs_n %b (queued %0d dropped on rise)", cyc, cs_n, cs_n ? oq_n : 11'd0);
        if (cs_n) begin
            bitcnt = 0;
            if (!cs_q) begin tx_sh = 8'hFF; oq_h = oq_t; mrd = 1'b0; end
            miso <= 1'b1;
        end
        else if (!absent) begin
            if (cs_q) begin                                // CS fell: present the next byte
                tx_sh = (oq_n != 0) ? outq[oq_h] : 8'hFF;
                if (oq_n != 0) oq_h = oq_h + 1;
                miso <= tx_sh[7];
            end
            else if (sck && !sck_q) begin                  // rising: sample
                rx_sh  = {rx_sh[6:0], mosi};
                bitcnt = bitcnt + 1;
                if (bitcnt == 0) got_byte (rx_sh);         // 8 bits in (bitcnt wrapped)
            end
            else if (!sck && sck_q) begin                  // falling: next bit / next byte
                if (bitcnt == 0) begin
                    if (mrd && oq_n < 8) begin push_block_mem (mrd_lba * 512, 512); mrd_lba = mrd_lba + 1; end
                    tx_sh = (oq_n != 0) ? outq[oq_h] : 8'hFF;
                    if (oq_n != 0) oq_h = oq_h + 1;
                end
                else
                    tx_sh = {tx_sh[6:0], 1'b1};
                miso <= tx_sh[7];
            end
        end
        sck_q = sck;
        cs_q  = cs_n;
    end
endmodule
`default_nettype wire
