// ================================================================
// Sd_Host.v -- microSD host in native SD mode (1- or 4-bit bus), programmed I/O.
//
// Register window 0xC000_D000 on the register bus (Top.v decodes rb_addr[15:12] == 0xD):
//   0x00 ID       'SDH1'
//   0x04 CTRL     [0] MODE   1 = this host owns the card pins (only while the ESP32 is held in
//                            reset with its strap released: board_io gpio1 0x0C == 0)
//                 [1] WIDE   4-bit data bus (else DAT0 only)
//                 [2] WPROT  write protect, set by reset: write commands (CMD24/25/27/28/29/38/42/56
//                            and any command with CMD[12]) are refused, and DAT is never driven
//                 [3] CLKEN  run the card clock
//                 [27:16] DIV  half period = max(DIV,1)+1 system clocks (reset 62: 397 kHz at 50 MHz;
//                            DIV 1 = 12.5 MHz, the fastest)
//   0x08 ARG      command argument
//   0x0C CMD      write starts a command (ignored while one is in flight):
//                 [5:0] index  [9:8] response 0 none, 1 48-bit, 2 136-bit (R2)
//                 [10] no CRC check (R3)  [11] data transfer  [12] data direction: write
//   0x10 STATUS   [0] command busy [1] command done [2] response timeout [3] response CRC error
//                 [4] data busy [5] data done [6] data CRC error [7] data timeout
//                 [8] buffer ready (read: a block waits in the buffer; write: the buffer wants a block)
//                 [9] DAT0 level [10] refused by WPROT [11] write CRC status not 010
//                 [12] native mode active  [31:16] blocks remaining
//   0x14..0x20 RESP0..3  48-bit response: RESP0 = bits 39:8 (card status / OCR), RESP1 = index;
//                 136-bit: RESP0 = bits 127:96 .. RESP3 = bits 31:0 (bit 0 = end bit)
//   0x24 BLKSIZE  bytes per block, a multiple of 4, 4..512
//   0x28 BLKCNT   blocks to transfer (written before the data command)
//   0x2C DTMO     data timeout in card clocks (start bit / busy), reset 0xFFFFFF
//   0x30 FIFO     read: next word of the received block; write: next word of the block to send.
//                 First byte on the wire in bits 7:0.
//   0x34 ABORT    write: stop the data path and empty the buffer
//
// Timing: commands and data are driven on the falling card-clock edge and sampled on the system
// clock edge that launches the next falling edge (a full low+high period after the card's launch
// edge less one system clock), so a 14 ns card output delay plus pad delays fits even at 12.5 MHz.
// A received block is held in the 512-byte buffer and the card clock stops (low) until software
// has read it all, so multi-block reads need no second buffer.
//
// Pins: the card's six lines are shared with SPI0's SPI mode (clk, MOSI = CMD, MISO = DAT0,
// CS = DAT3) and with the ESP32's GPIO2 strap on DAT0.  The mux is here so the checks
// (formal/fv/ips/sdh) see it: outside native mode the pins are exactly SPI0 plus the strap.
// ================================================================
`default_nettype none
module sd_host (
    input  wire        clk,
    input  wire        rst,
    // register bus
    input  wire        rb_valid,
    input  wire        rb_we,
    input  wire [11:0] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_wstrb,
    output reg         rb_ack,
    output reg  [31:0] rb_rdata,
    // SPI0 (SPI mode) and the ESP32 strap, passed through outside native mode
    input  wire        spi_sclk,
    input  wire        spi_mosi,
    input  wire        spi_cs_n,
    output wire        spi_miso,
    input  wire        esp32_en,
    input  wire        esp32_strap,
    // pads: Top.v makes the tristates
    output wire        clk_o,
    output wire        cmd_o,
    output wire        cmd_oe,
    input  wire        cmd_i,
    output wire [3:0]  dat_o,
    output wire [3:0]  dat_oe,
    input  wire [3:0]  dat_i
);
    // ---------------- registers ----------------
    reg        mode, wide, wprot, clken;
    reg [11:0] div;
    reg [31:0] arg;
    reg [12:0] cmdreg;
    reg [31:0] resp0, resp1, resp2, resp3;
    reg [9:0]  blksize;
    reg [15:0] blkcnt;
    reg [23:0] dtmo;
    reg        c_done, c_tmo, c_crc, d_done, d_crc, d_tmo, wp_rej, wr_err;

    wire native = mode && !esp32_en && !esp32_strap;

    function automatic is_write_cmd (input [5:0] i);
        is_write_cmd = (i == 6'd24) || (i == 6'd25) || (i == 6'd27) || (i == 6'd28) || (i == 6'd29)
                    || (i == 6'd38) || (i == 6'd42) || (i == 6'd56);
    endfunction
    // x^7 + x^3 + 1 and x^16 + x^12 + x^5 + 1, MSB first, zero initial value
    function automatic [6:0] crc7_step (input [6:0] c, input b);
        reg fb;
        begin
            fb = c[6] ^ b;
            crc7_step = {c[5:3], c[2] ^ fb, c[1:0], fb};
        end
    endfunction
    function automatic [15:0] crc16_step (input [15:0] c, input b);
        reg fb;
        begin
            fb = c[15] ^ b;
            crc16_step = {c[14:12], c[11] ^ fb, c[10:5], c[4] ^ fb, c[3:0], fb};
        end
    endfunction

    // ---------------- card clock ----------------
    reg        sclk;
    reg [11:0] ccnt;
    reg        rx_ready;                         // a received block waits in the buffer
    reg [2:0]  dst;
    localparam D_IDLE = 3'd0, D_RSTART = 3'd1, D_RDATA = 3'd2, D_RCRC = 3'd3, D_WFILL = 3'd4,
               D_WSEND = 3'd5, D_WSTAT = 3'd6, D_WBUSY = 3'd7;
    wire [11:0] div_e = (div == 12'd0) ? 12'd1 : div;
    wire run   = native && clken;
    wire hold  = rx_ready && (dst == D_RSTART) && !sclk;   // stop low until software drains it
    // stopping (CLKEN or MODE cleared) finishes a high phase first: no runt pulse
    wire edge_ = (ccnt == 12'd0) && (run ? !hold : sclk);
    wire fall  = edge_ && sclk && native;        // drive and sample here: every falling edge the card sees
    reg  cmd_q;                                  // input samples
    reg  [3:0] dat_q;

    // ---------------- command path ----------------
    localparam C_IDLE = 3'd0, C_SEND = 3'd1, C_WAIT = 3'd2, C_RESP = 3'd3, C_END = 3'd4;
    reg [2:0]   cst;
    reg [7:0]   cn;                              // bit counter / response timeout
    reg [39:0]  csh;                             // bits still to send
    reg [6:0]   crc7;
    reg         cout, coe;
    reg [126:0] rsh;
    wire [1:0]  rtype = cmdreg[9:8];
    wire [7:0]  rlast = (rtype == 2'd2) ? 8'd135 : 8'd47;

    // ---------------- data path ----------------
    reg [12:0]  dcnt;                            // bit times within the block
    reg [23:0]  dto;
    reg [15:0]  k0, k1, k2, k3;                  // CRC16 per DAT line
    reg [7:0]   byt;                             // byte being assembled (read)
    reg [31:0]  dsh;                             // word being assembled / sent
    reg [6:0]   bptr;                            // buffer word pointer (data path)
    reg [6:0]   cptr;                            // buffer word pointer (CPU side)
    reg         tx_full;                         // software has written a whole block
    reg [3:0]   dout;
    reg         doe;
    reg [3:0]   wst;                             // write CRC status token (after its start bit)
    reg [1:0]   wgap;                            // clocks since the response (Nwr >= 2)
    wire [6:0]  wlast = blksize[8:2] - 7'd1;    // words per block less one (512 -> 127)
    wire [12:0] dbits = wide ? {2'b0, blksize, 1'b0} : {blksize, 3'b0};   // data clocks per block
    wire        bdone = wide ? dcnt[0] : (dcnt[2:0] == 3'd7);              // last clock of a byte
    wire        wdone = wide ? (dcnt[2:0] == 3'd7) : (dcnt[4:0] == 5'd31); // last clock of a word
    wire [7:0]  nbyt  = wide ? {byt[3:0], dat_q} : {byt[6:0], dat_q[0]};

    // the buffer: one read port, one write port
    reg  [31:0] mem [0:127];
    reg  [31:0] q;
    reg         we_m, we_d;
    reg  [6:0]  wa_m;
    reg  [31:0] wd_m;
    wire tx_dir = (dst == D_WFILL) || (dst == D_WSEND) || (dst == D_WSTAT) || (dst == D_WBUSY);
    wire [6:0] rd_a = tx_dir ? bptr : cptr;
    always @(posedge clk) begin
        q <= mem[rd_a];
        if (we_m) mem[wa_m] <= wd_m;
    end

    // ---------------- pins ----------------
    assign clk_o  = native ? sclk : spi_sclk;
    assign cmd_o  = native ? cout : spi_mosi;
    assign cmd_oe = native ? coe  : 1'b1;
    assign dat_o  = native ? dout : {spi_cs_n, 3'b000};
    assign dat_oe = native ? ((doe && !wprot) ? (wide ? 4'hF : 4'h1) : 4'h0)
                           : {1'b1, 2'b00, esp32_strap && spi_cs_n};
    assign spi_miso = native ? 1'b1 : dat_i[0];

    // ---------------- register bus ----------------
    wire take = rb_valid && !rb_ack;
    wire wr   = take && rb_we && (rb_wstrb == 4'hF);
    wire rd   = take && !rb_we;
    wire [3:0] a = rb_addr[5:2];
    wire a_lo = (rb_addr[11:6] == 6'd0);
    wire cmd_go  = wr && a_lo && (a == 4'd3) && (cst == C_IDLE) && native;
    wire cmd_wp  = rb_wdata[12] || is_write_cmd (rb_wdata[5:0]);
    wire cmd_ok  = cmd_go && !(wprot && cmd_wp);
    wire fifo_rd = rd && a_lo && (a == 4'd12) && rx_ready && !tx_dir;
    wire fifo_wr = wr && a_lo && (a == 4'd12) && (dst == D_WFILL) && !tx_full;
    wire abort   = wr && a_lo && (a == 4'd13);
    wire dbusy   = (dst != D_IDLE);
    wire [15:0] status_lo = {3'b0, native, wr_err, wp_rej, dat_q[0],
                             (rx_ready || (dst == D_WFILL && !tx_full)), d_tmo, d_crc, d_done, dbusy,
                             c_crc, c_tmo, c_done, (cst != C_IDLE)};

    always @(posedge clk) begin
        rb_ack <= 1'b0;
        we_m   <= 1'b0;
        we_d   <= we_m;
        if (take) begin
            rb_ack   <= 1'b1;
            rb_rdata <= 32'b0;
            if (!rb_we && a_lo)
                case (a)
                    4'd0:  rb_rdata <= 32'h53444831;
                    4'd1:  rb_rdata <= {4'b0, div, 12'b0, clken, wprot, wide, mode};
                    4'd2:  rb_rdata <= arg;
                    4'd3:  rb_rdata <= {19'b0, cmdreg};
                    4'd4:  rb_rdata <= {blkcnt, status_lo};
                    4'd5:  rb_rdata <= resp0;
                    4'd6:  rb_rdata <= resp1;
                    4'd7:  rb_rdata <= resp2;
                    4'd8:  rb_rdata <= resp3;
                    4'd9:  rb_rdata <= {22'b0, blksize};
                    4'd10: rb_rdata <= {16'b0, blkcnt};
                    4'd11: rb_rdata <= {8'b0, dtmo};
                    4'd12: rb_rdata <= fifo_rd ? q : 32'b0;
                    default: ;
                endcase
            if (wr && a_lo)
                case (a)
                    4'd1:  begin mode <= rb_wdata[0]; wide <= rb_wdata[1]; wprot <= rb_wdata[2];
                                 clken <= rb_wdata[3]; div <= rb_wdata[27:16]; end
                    4'd2:  arg <= rb_wdata;
                    4'd9:  if (!dbusy) blksize <= (rb_wdata[9:2] == 8'd0) ? 10'd4 : {rb_wdata[9:2], 2'b00};
                    4'd10: if (!dbusy) blkcnt <= rb_wdata[15:0];
                    4'd11: dtmo <= rb_wdata[23:0];
                    default: ;
                endcase
        end
        if (fifo_rd) begin
            cptr <= (cptr == wlast) ? 7'd0 : cptr + 7'd1;
            if (cptr == wlast) rx_ready <= 1'b0;
        end
        if (fifo_wr) begin
            we_m <= 1'b1; wa_m <= cptr; wd_m <= rb_wdata;
            cptr <= (cptr == wlast) ? 7'd0 : cptr + 7'd1;
            if (cptr == wlast) tx_full <= 1'b1;
        end

        // ---- card clock ----
        if (!run && !sclk) begin
            ccnt <= div_e;
        end else if (ccnt != 12'd0) begin
            ccnt <= ccnt - 12'd1;
        end else if (edge_) begin
            sclk <= !sclk;
            ccnt <= div_e;
        end
        cmd_q <= cmd_i;
        dat_q <= dat_i;

        // ---- command path ----
        if (cmd_go) begin
            cmdreg <= rb_wdata[12:0];
            c_done <= 1'b0; c_tmo <= 1'b0; c_crc <= 1'b0;
            wp_rej <= !cmd_ok;
            if (cmd_ok) begin
                cst  <= C_SEND;
                csh  <= {2'b01, rb_wdata[5:0], arg};
                crc7 <= 7'd0;
                cn   <= 8'd0;
            end else
                c_done <= 1'b1;
        end else if (!native) begin
            cst <= C_IDLE; coe <= 1'b0; cout <= 1'b1;
        end else if (fall)
            case (cst)
                C_SEND: begin
                    coe <= 1'b1;
                    cn  <= cn + 8'd1;
                    if (cn < 8'd40) begin
                        cout <= csh[39];
                        csh  <= {csh[38:0], 1'b0};
                        crc7 <= crc7_step (crc7, csh[39]);
                    end else if (cn < 8'd47) begin
                        cout <= crc7[6];
                        crc7 <= {crc7[5:0], 1'b0};
                    end else begin
                        cout <= 1'b1;            // end bit
                        cn   <= 8'd0;
                        cst  <= (rtype == 2'd0) ? C_END : C_WAIT;
                    end
                end
                C_END: begin                     // release after the end bit's period
                    coe <= 1'b0; cout <= 1'b1;
                    cst <= C_IDLE; c_done <= 1'b1;
                end
                C_WAIT: begin
                    coe <= 1'b0; cout <= 1'b1;
                    cn  <= cn + 8'd1;
                    if (coe) ;                   // the end bit's own period: the line is still ours
                    else if (!cmd_q) begin
                        cst  <= C_RESP; cn <= 8'd1; rsh <= 127'b0;
                        crc7 <= crc7_step (7'd0, 1'b0);
                    end else if (cn == 8'd255) begin
                        cst <= C_IDLE; c_tmo <= 1'b1; c_done <= 1'b1;
                    end
                end
                C_RESP: begin
                    cn  <= cn + 8'd1;
                    rsh <= {rsh[125:0], cmd_q};
                    if (cn < 8'd40) crc7 <= crc7_step (crc7, cmd_q);
                    if (cn == rlast) begin
                        cst <= C_IDLE; c_done <= 1'b1;
                        if (rtype == 2'd2) begin
                            resp0 <= rsh[126:95]; resp1 <= rsh[94:63];
                            resp2 <= rsh[62:31];  resp3 <= {rsh[30:0], cmd_q};
                        end else begin
                            resp0 <= rsh[38:7];  resp1 <= {26'b0, rsh[44:39]};
                            resp2 <= 32'b0;      resp3 <= 32'b0;
                            c_crc <= !cmdreg[10] && ((rsh[6:0] != crc7) || !cmd_q);
                        end
                    end
                end
                default: cst <= C_IDLE;
            endcase

        // ---- data path ----
        if (cmd_ok && rb_wdata[11]) begin       // a data command arms it
            d_done <= 1'b0; d_crc <= 1'b0; d_tmo <= 1'b0; wr_err <= 1'b0;
            bptr <= 7'd0; cptr <= 7'd0; rx_ready <= 1'b0; tx_full <= 1'b0;
            doe  <= 1'b0; dout <= 4'hF;
            dst  <= rb_wdata[12] ? D_WFILL : D_RSTART;
            dto  <= dtmo;
            wgap <= 2'd0;
        end else if (abort || !native) begin
            dst <= D_IDLE; doe <= 1'b0; dout <= 4'hF;
            rx_ready <= 1'b0; tx_full <= 1'b0; bptr <= 7'd0; cptr <= 7'd0;
        end else if (fall)
            case (dst)
                D_RSTART:
                    if (!dat_q[0]) begin
                        dst <= D_RDATA; dcnt <= 13'd0;
                        k0 <= 16'd0; k1 <= 16'd0; k2 <= 16'd0; k3 <= 16'd0;
                    end else if (dto == 24'd0) begin
                        dst <= D_IDLE; d_tmo <= 1'b1; d_done <= 1'b1;
                    end else
                        dto <= dto - 24'd1;
                D_RDATA: begin
                    dcnt <= dcnt + 13'd1;
                    k0 <= crc16_step (k0, dat_q[0]);
                    k1 <= crc16_step (k1, dat_q[1]);
                    k2 <= crc16_step (k2, dat_q[2]);
                    k3 <= crc16_step (k3, dat_q[3]);
                    byt <= nbyt;
                    if (bdone) dsh <= {nbyt, dsh[31:8]};          // first byte ends in bits 7:0
                    if (wdone) begin
                        we_m <= 1'b1; wa_m <= bptr; wd_m <= {nbyt, dsh[31:8]};
                        bptr <= bptr + 7'd1;
                    end
                    if (dcnt == dbits - 13'd1) begin dst <= D_RCRC; dcnt <= 13'd0; end
                end
                D_RCRC: begin                    // 16 CRC bits per line, then the end bit
                    dcnt <= dcnt + 13'd1;
                    if (dcnt < 13'd16) begin
                        k0 <= crc16_step (k0, dat_q[0]);
                        k1 <= crc16_step (k1, dat_q[1]);
                        k2 <= crc16_step (k2, dat_q[2]);
                        k3 <= crc16_step (k3, dat_q[3]);
                    end else begin
                        // the data followed by its CRC divides to 0; the end bit is 1
                        if ((k0 != 16'd0) || !dat_q[0]
                            || (wide && (k1 != 16'd0 || k2 != 16'd0 || k3 != 16'd0 || dat_q != 4'hF)))
                            d_crc <= 1'b1;
                        rx_ready <= 1'b1; bptr <= 7'd0; cptr <= 7'd0;
                        dto <= dtmo;
                        if (blkcnt <= 16'd1) begin
                            blkcnt <= 16'd0; dst <= D_IDLE; d_done <= 1'b1;
                        end else begin
                            blkcnt <= blkcnt - 16'd1; dst <= D_RSTART;
                        end
                    end
                end
                D_WFILL: begin                   // wait for the response and a whole block
                    if (cst == C_IDLE && c_done && wgap != 2'd3) wgap <= wgap + 2'd1;
                    if (cst == C_IDLE && c_done && (c_tmo || c_crc)) begin
                        dst <= D_IDLE; d_done <= 1'b1;
                    end else if (wgap == 2'd3 && tx_full && !we_m && !we_d) begin
                        dst  <= D_WSEND; dcnt <= 13'd0;
                        doe  <= 1'b1; dout <= 4'h0;                   // start bit
                        k0 <= 16'd0; k1 <= 16'd0; k2 <= 16'd0; k3 <= 16'd0;
                        dsh  <= q; bptr <= bptr + 7'd1;               // q = word 0
                    end
                end
                D_WSEND: begin
                    dcnt <= dcnt + 13'd1;
                    if (dcnt < dbits) begin      // byte 0 of dsh, MSB first
                        if (wide) begin
                            dout <= dcnt[0] ? dsh[3:0] : dsh[7:4];
                            k0 <= crc16_step (k0, dcnt[0] ? dsh[0] : dsh[4]);
                            k1 <= crc16_step (k1, dcnt[0] ? dsh[1] : dsh[5]);
                            k2 <= crc16_step (k2, dcnt[0] ? dsh[2] : dsh[6]);
                            k3 <= crc16_step (k3, dcnt[0] ? dsh[3] : dsh[7]);
                            if (dcnt[0]) dsh <= {8'b0, dsh[31:8]};
                        end else begin
                            dout <= {3'b111, dsh[7]};
                            k0 <= crc16_step (k0, dsh[7]);
                            dsh <= (dcnt[2:0] == 3'd7) ? {8'b0, dsh[31:8]} : {dsh[31:8], dsh[6:0], 1'b0};
                        end
                        if (wdone && dcnt != dbits - 13'd1) begin
                            dsh <= q; bptr <= bptr + 7'd1;
                        end
                    end else if (dcnt < dbits + 13'd16) begin
                        dout <= {k3[15], k2[15], k1[15], k0[15]};
                        k0 <= {k0[14:0], 1'b0}; k1 <= {k1[14:0], 1'b0};
                        k2 <= {k2[14:0], 1'b0}; k3 <= {k3[14:0], 1'b0};
                    end else if (dcnt == dbits + 13'd16) begin
                        dout <= 4'hF;            // end bit
                    end else begin
                        doe <= 1'b0; dst <= D_WSTAT; dcnt <= 13'd0; dto <= dtmo;
                    end
                end
                D_WSTAT: begin                   // CRC status on DAT0: 0 s2 s1 s0 1
                    if (dcnt != 13'd0 || !dat_q[0]) begin
                        dcnt <= dcnt + 13'd1;
                        wst  <= {wst[2:0], dat_q[0]};
                        if (dcnt == 13'd4) begin
                            if ({wst[2:0], dat_q[0]} != 4'b0101) wr_err <= 1'b1;
                            dst <= D_WBUSY;
                        end
                    end else if (dto == 24'd0) begin
                        dst <= D_IDLE; d_tmo <= 1'b1; d_done <= 1'b1;
                    end else
                        dto <= dto - 24'd1;
                end
                D_WBUSY:                         // the card holds DAT0 low while programming
                    if (dat_q[0]) begin
                        bptr <= 7'd0; cptr <= 7'd0; tx_full <= 1'b0; dto <= dtmo;
                        if (blkcnt <= 16'd1 || wr_err) begin
                            blkcnt <= (blkcnt == 16'd0) ? 16'd0 : blkcnt - 16'd1;
                            dst <= D_IDLE; d_done <= 1'b1;
                        end else begin
                            blkcnt <= blkcnt - 16'd1; dst <= D_WFILL;
                        end
                    end else if (dto == 24'd0) begin
                        dst <= D_IDLE; d_tmo <= 1'b1; d_done <= 1'b1;
                    end else
                        dto <= dto - 24'd1;
                default: ;
            endcase

        if (rst) begin
            rb_ack <= 1'b0; rb_rdata <= 32'b0; we_m <= 1'b0; we_d <= 1'b0;
            mode <= 1'b0; wide <= 1'b0; wprot <= 1'b1; clken <= 1'b0; div <= 12'd62;
            arg <= 32'b0; cmdreg <= 13'b0; blksize <= 10'd512; blkcnt <= 16'd0; dtmo <= 24'hFFFFFF;
            resp0 <= 32'b0; resp1 <= 32'b0; resp2 <= 32'b0; resp3 <= 32'b0;
            c_done <= 1'b0; c_tmo <= 1'b0; c_crc <= 1'b0; wp_rej <= 1'b0;
            d_done <= 1'b0; d_crc <= 1'b0; d_tmo <= 1'b0; wr_err <= 1'b0;
            sclk <= 1'b0; ccnt <= 12'd62;
            cst <= C_IDLE; coe <= 1'b0; cout <= 1'b1; cn <= 8'd0;
            dst <= D_IDLE; doe <= 1'b0; dout <= 4'hF; dcnt <= 13'd0;
            bptr <= 7'd0; cptr <= 7'd0; rx_ready <= 1'b0; tx_full <= 1'b0; wgap <= 2'd0;
        end
    end

endmodule
