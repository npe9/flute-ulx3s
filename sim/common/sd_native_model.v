// ================================================================
// sd_native_model.v -- behavioral SDHC card in native SD mode (1- or 4-bit) for the benches.
//
// Synchronous to the bench clock: samples SCK every clk, so SCK must be at most clk/4 (Sd_Host
// runs at most clk/4).  CMD and DAT are sampled on rising SCK and change after falling SCK.
// Open drain style: the model drives a line only while it sends (*_oe), the bench adds pull-ups.
// Backing store: BLOCKS x 512 bytes, preloaded from +sdn_image=<hex> ($readmemh, a byte per line),
// else byte i of block b = i[7:0] ^ b[7:0], 0x55AA at 510 of block 0.  +sdn_trace=1 logs commands.
// Commands: CMD0 2 3 5(no response) 6 7 8 9 10 12 13 16 17 18 24 25 55, ACMD6 13 41 42 51.
// Responses and data carry correct CRCs; a command with a bad CRC7 is ignored.  +sdn_badcrc=N
// corrupts the CRC16 of the Nth data block sent (1 = first), +sdn_badend=N its end bit, to exercise
// the host's checks.
// ================================================================
`default_nettype none
module sd_native_model #(parameter integer BLOCKS = 2048) (
    input  wire       clk,
    input  wire       sck,
    input  wire       cmd_i,
    output reg        cmd_o,
    output reg        cmd_oe,
    input  wire [3:0] dat_i,
    output reg  [3:0] dat_o,
    output reg  [3:0] dat_oe
);
    localparam integer NBYTES = BLOCKS * 512;
    reg [7:0] mem [0:NBYTES-1];
    reg [7:0] blk [0:511];          // block being sent or received
    localparam [21:0] CSIZE = BLOCKS / 1024 - 1;   // capacity (CSIZE+1) x 512 KiB
    integer i, trace, badcrc, badend, nsent;
    reg [8*256-1:0] img;

    initial begin
        for (i = 0; i < NBYTES; i = i + 1) mem[i] = i[7:0] ^ i[16:9];
        mem[510] = 8'h55; mem[511] = 8'hAA;
        if ($value$plusargs ("sdn_image=%s", img)) $readmemh (img, mem);
        if (!$value$plusargs ("sdn_trace=%d", trace)) trace = 0;
        if (!$value$plusargs ("sdn_badcrc=%d", badcrc)) badcrc = 0;
        if (!$value$plusargs ("sdn_badend=%d", badend)) badend = 0;
        nsent = 0;
        cmd_o = 1'b1; cmd_oe = 1'b0; dat_o = 4'hF; dat_oe = 4'h0;
    end

    function automatic [6:0] crc7_step (input [6:0] c, input b);
        reg fb;
        begin fb = c[6] ^ b; crc7_step = {c[5:3], c[2] ^ fb, c[1:0], fb}; end
    endfunction
    function automatic [15:0] crc16_step (input [15:0] c, input b);
        reg fb;
        begin fb = c[15] ^ b; crc16_step = {c[14:12], c[11] ^ fb, c[10:5], c[4] ^ fb, c[3:0], fb}; end
    endfunction

    // card state
    localparam S_IDLE = 4'd0, S_READY = 4'd1, S_IDENT = 4'd2, S_STBY = 4'd3, S_TRAN = 4'd4,
               S_DATA = 4'd5, S_RCV = 4'd6, S_PRG = 4'd7;
    reg [3:0]  st;
    reg        app, wide, ccs_ok;
    reg [15:0] rca;
    reg [3:0]  acmd41_n;
    reg [31:0] lba;
    reg        multi;

    reg        sck_q;
    wire       rise = sck && !sck_q;
    wire       fallw = !sck && sck_q;

    // ---- command receiver ----
    reg [47:0] csh;
    reg [5:0]  cbits;               // 0 = waiting for a start bit
    // ---- response sender ----
    reg [135:0] rsh;
    reg [7:0]   rleft;              // bits still to send
    reg [3:0]   rwait;              // falling edges before the start bit (Ncr)
    // ---- data sender ----
    reg [12:0]  dleft;              // data clocks left in the block
    reg [4:0]   dcrc_left;          // CRC clocks (16) + end bit
    reg [7:0]   dwait;              // falling edges before the start bit
    reg [9:0]   dbyte;              // byte index
    reg         dnib;               // 4-bit: second nibble of the byte
    reg [2:0]   dbit;               // 1-bit: bit within the byte (7 first)
    reg [15:0]  dk0, dk1, dk2, dk3;
    reg [9:0]   dlen;               // bytes per block being sent
    reg         dsend, dbad, dbadend;
    // ---- data receiver (writes) ----
    reg         drecv;              // waiting for / receiving a block
    reg         dgot;               // inside a block (start bit seen)
    reg [12:0]  rcnt, rc;
    reg [15:0]  rk0, rk1, rk2, rk3;
    reg [7:0]   rbyte_sh;
    reg [9:0]   rbyte;
    reg [7:0]   stat_sh;            // CRC status token and busy, sent on DAT0
    reg [5:0]   stat_left;

    reg [31:0] r1_status;
    always @(*) r1_status = {19'b0, st, 1'b1, 2'b0, app, 5'b0};

    task automatic respond48 (input [5:0] idx, input [31:0] body, input crcok);
        reg [6:0] c; integer k; reg [39:0] h;
        begin
            h = {2'b00, idx, body};
            c = 7'd0;
            for (k = 39; k >= 0; k = k - 1) c = crc7_step (c, h[k]);
            rsh   = {h, (crcok ? c : 7'h7F), 1'b1, 88'b0};
            rleft = 8'd48; rwait = 4'd2;
        end
    endtask
    task automatic respond_r2 (input [119:0] body);   // CID/CSD bits 127:8; CRC7 internal
        reg [6:0] c; integer k;
        begin
            c = 7'd0;
            for (k = 119; k >= 0; k = k - 1) c = crc7_step (c, body[k]);
            rsh   = {8'b00111111, body, c, 1'b1};
            rleft = 8'd136; rwait = 4'd2;
        end
    endtask
    task automatic start_data (input [9:0] nbytes);
        begin
            dsend = 1'b1; dlen = nbytes; dbyte = 10'd0; dnib = 1'b0; dbit = 3'd7;
            dleft = wide ? {2'b0, nbytes, 1'b0} : {nbytes, 3'b0};
            dcrc_left = 5'd17; dwait = 8'd4;
            dk0 = 16'd0; dk1 = 16'd0; dk2 = 16'd0; dk3 = 16'd0;
            nsent = nsent + 1; dbad = (nsent == badcrc); dbadend = (nsent == badend);
        end
    endtask
    task automatic load_block (input [31:0] b);
        integer k;
        begin
            for (k = 0; k < 512; k = k + 1)
                blk[k] = (b < BLOCKS) ? mem[b * 512 + k] : 8'h00;
        end
    endtask

    reg [5:0]  ci;
    reg [31:0] ca;
    reg [6:0]  cc;
    integer    k2;
    always @(posedge clk) begin
        sck_q <= sck;

        // ---------------- rising edge: sample CMD and DAT ----------------
        if (rise) begin
            if (cbits == 6'd0) begin
                if (!cmd_i && !cmd_oe) begin cbits = 6'd1; csh = 48'b0; end
            end else begin
                if (cbits != 6'd47) begin
                    csh   = {csh[46:0], cmd_i};
                    cbits = cbits + 6'd1;
                end else begin
                    // csh[45:0] = bits 46..1 (the start bit 47 was not shifted in), cmd_i = the end bit
                    cbits = 6'd0;
                    ci = csh[44:39]; ca = csh[38:7];
                    cc = crc7_step (7'd0, 1'b0);
                    for (k2 = 45; k2 >= 7; k2 = k2 - 1) cc = crc7_step (cc, csh[k2]);
                    if (trace != 0)
                        $display ("[sdn] %sCMD%0d arg %08x%s", app ? "A" : "", ci, ca,
                                  (cc != csh[6:0] || !csh[45] || !cmd_i) ? " (bad frame/CRC: ignored)" : "");
                    if (cc == csh[6:0] && csh[45] && cmd_i) begin
                        if (app) begin
                            app = 1'b0;
                            case (ci)
                                6'd6:  begin wide = (ca[1:0] == 2'b10); respond48 (ci, {r1_status[31:6], 1'b1, 5'b0}, 1); end
                                6'd13: begin respond48 (ci, r1_status | 32'h20, 1);
                                             for (k2 = 0; k2 < 64; k2 = k2 + 1) blk[k2] = 8'h00;
                                             blk[0] = wide ? 8'h80 : 8'h00; start_data (10'd64); st = S_DATA; end
                                6'd41: begin
                                    if (ca[23:0] == 24'd0) respond48 (6'h3F, 32'h00FF8000, 0);  // inquiry
                                    else begin
                                        acmd41_n = acmd41_n + 4'd1;
                                        if (acmd41_n >= 4'd2) st = S_READY;
                                        respond48 (6'h3F, {(acmd41_n >= 4'd2), ca[30], 6'b0, 24'hFF8000}, 0);
                                    end
                                end
                                6'd42: respond48 (ci, r1_status | 32'h20, 1);
                                6'd51: begin respond48 (ci, r1_status | 32'h20, 1);
                                             // SCR: version 2, bus widths 1 and 4, SD 3.0
                                             blk[0] = 8'h02; blk[1] = 8'h35; blk[2] = 8'h80; blk[3] = 8'h00;
                                             blk[4] = 8'h00; blk[5] = 8'h00; blk[6] = 8'h00; blk[7] = 8'h00;
                                             start_data (10'd8); st = S_DATA; end
                                default: ;           // illegal: no response
                            endcase
                        end else
                            case (ci)
                                6'd0:  begin st = S_IDLE; wide = 1'b0; acmd41_n = 4'd0; rca = 16'h0000;
                                             dsend = 1'b0; drecv = 1'b0; end
                                6'd2:  if (st == S_READY) begin
                                           st = S_IDENT;
                                           respond_r2 ({8'h03, 16'h5344, 40'h464C555445, 8'h10,
                                                        32'h12345678, 4'h0, 12'h1A1});
                                       end
                                6'd3:  begin st = S_STBY; rca = 16'h4321;
                                             respond48 (ci, {16'h4321, 3'b000, st, 1'b1, 2'b0, 1'b0, 5'b0}, 1); end
                                6'd6:  begin respond48 (ci, r1_status, 1);
                                             for (k2 = 0; k2 < 64; k2 = k2 + 1) blk[k2] = 8'h00;
                                             blk[0] = 8'h00; blk[1] = 8'h64;        // 100 mA
                                             blk[12] = 8'h80; blk[13] = 8'h03;      // group 1: default + HS
                                             blk[16] = 8'h00;                       // function 0 selected
                                             start_data (10'd64); st = S_DATA; end
                                6'd7:  if (ca[31:16] == rca) begin respond48 (ci, r1_status, 1); st = S_TRAN; end
                                       else st = S_STBY;
                                6'd8:  respond48 (ci, {20'b0, ca[11:8], ca[7:0]}, 1);
                                6'd9:  respond_r2 ({2'b01, 6'b0, 8'h0E, 8'h00, 8'h32, 12'h5B5, 4'h9, 4'h0, 6'b0,
                                                    CSIZE, 1'b0, 1'b1, 7'h7F, 7'h00, 1'b0, 2'b00, 3'b010,
                                                    4'h9, 1'b0, 5'b0, 4'b0000, 2'b00, 2'b00});
                                6'd10: respond_r2 ({8'h03, 16'h5344, 40'h464C555445, 8'h10,
                                                    32'h12345678, 4'h0, 12'h1A1});
                                6'd12: begin respond48 (ci, r1_status, 1);
                                             dsend = 1'b0; drecv = 1'b0; dgot = 1'b0;
                                             dat_oe <= 4'h0; dat_o <= 4'hF;
                                             st = S_TRAN; end
                                6'd13: respond48 (ci, r1_status, 1);
                                6'd16: respond48 (ci, r1_status, 1);
                                6'd17, 6'd18: begin
                                    respond48 (ci, r1_status, 1);
                                    lba = ca + 32'd1; multi = (ci == 6'd18);
                                    load_block (ca); start_data (10'd512); st = S_DATA;
                                end
                                6'd24, 6'd25: begin
                                    respond48 (ci, r1_status, 1);
                                    lba = ca; multi = (ci == 6'd25);
                                    drecv = 1'b1; dgot = 1'b0; st = S_RCV;
                                end
                                6'd55: begin app = 1'b1; respond48 (ci, r1_status | 32'h20, 1); end
                                default: ;           // CMD5, CMD52, ... : no response
                            endcase
                    end
                end
            end
            // write data
            if (drecv && stat_left == 6'd0) begin
                if (!dgot) begin
                    if (!dat_i[0]) begin
                        dgot = 1'b1; rcnt = 13'd0; rbyte = 10'd0;
                        rk0 = 16'd0; rk1 = 16'd0; rk2 = 16'd0; rk3 = 16'd0;
                    end
                end else begin
                    rc = rcnt; rcnt = rcnt + 13'd1;
                    if (rc < (wide ? 13'd1024 + 13'd16 : 13'd4096 + 13'd16)) begin
                        rk0 = crc16_step (rk0, dat_i[0]); rk1 = crc16_step (rk1, dat_i[1]);
                        rk2 = crc16_step (rk2, dat_i[2]); rk3 = crc16_step (rk3, dat_i[3]);
                    end
                    if (rc < (wide ? 13'd1024 : 13'd4096)) begin
                        if (wide) begin
                            rbyte_sh = {rbyte_sh[3:0], dat_i};
                            if (rc[0]) begin blk[rbyte] = rbyte_sh; rbyte = rbyte + 10'd1; end
                        end else begin
                            rbyte_sh = {rbyte_sh[6:0], dat_i[0]};
                            if (rc[2:0] == 3'd7) begin blk[rbyte] = rbyte_sh; rbyte = rbyte + 10'd1; end
                        end
                    end else if (rc == (wide ? 13'd1024 + 13'd16 : 13'd4096 + 13'd16)) begin
                        // end bit: check, store, answer with the CRC status and some busy
                        dgot = 1'b0;
                        if (rk0 == 16'd0 && (!wide || (rk1 == 16'd0 && rk2 == 16'd0 && rk3 == 16'd0))) begin
                            for (k2 = 0; k2 < 512; k2 = k2 + 1)
                                if (lba < BLOCKS) mem[lba * 512 + k2] = blk[k2];
                            if (trace != 0) $display ("[sdn] wrote block %0d", lba);
                            lba = lba + 32'd1;
                            stat_sh = 8'b11001010;        // 2 idle, 0 010 1, then busy
                        end else begin
                            if (trace != 0) $display ("[sdn] write CRC error, block %0d", lba);
                            stat_sh = 8'b11010110;        // 0 101 1
                        end
                        stat_left = 6'd24;
                        if (!multi) drecv = 1'b0;
                    end
                end
            end
        end

        // ---------------- falling edge: drive ----------------
        if (fallw) begin
            // response on CMD
            if (rleft != 8'd0) begin
                if (rwait != 4'd0) rwait = rwait - 4'd1;
                else begin
                    cmd_oe <= 1'b1; cmd_o <= rsh[135];
                    rsh = {rsh[134:0], 1'b1}; rleft = rleft - 8'd1;
                end
            end else begin
                cmd_oe <= 1'b0; cmd_o <= 1'b1;
            end
            // read data on DAT
            if (dsend) begin
                if (dwait != 8'd0) begin
                    dwait = dwait - 8'd1;
                    if (dwait == 8'd0) begin dat_oe <= wide ? 4'hF : 4'h1; dat_o <= 4'h0; end   // start bit
                end else if (dleft != 13'd0) begin
                    dleft = dleft - 13'd1;
                    if (wide) begin
                        dat_o <= dnib ? blk[dbyte][3:0] : blk[dbyte][7:4];
                        dk0 = crc16_step (dk0, dnib ? blk[dbyte][0] : blk[dbyte][4]);
                        dk1 = crc16_step (dk1, dnib ? blk[dbyte][1] : blk[dbyte][5]);
                        dk2 = crc16_step (dk2, dnib ? blk[dbyte][2] : blk[dbyte][6]);
                        dk3 = crc16_step (dk3, dnib ? blk[dbyte][3] : blk[dbyte][7]);
                        if (dnib) dbyte = dbyte + 10'd1;
                        dnib = !dnib;
                    end else begin
                        dat_o <= {3'b111, blk[dbyte][dbit]};
                        dk0 = crc16_step (dk0, blk[dbyte][dbit]);
                        if (dbit == 3'd0) dbyte = dbyte + 10'd1;
                        dbit = dbit - 3'd1;
                    end
                end else if (dcrc_left != 5'd0) begin
                    dcrc_left = dcrc_left - 5'd1;
                    if (dcrc_left == 5'd0) dat_o <= dbadend ? 4'hE : 4'hF;        // end bit (+sdn_badend: DAT0 low)
                    else begin
                        dat_o <= {dk3[15], dk2[15], dk1[15], dk0[15] ^ (dbad && dcrc_left == 5'd8)};
                        dk0 = {dk0[14:0], 1'b0}; dk1 = {dk1[14:0], 1'b0};
                        dk2 = {dk2[14:0], 1'b0}; dk3 = {dk3[14:0], 1'b0};
                    end
                end else begin
                    dat_oe <= 4'h0; dat_o <= 4'hF;
                    if (multi && dlen == 10'd512) begin                           // next block
                        load_block (lba); lba = lba + 32'd1; start_data (10'd512);
                    end else begin
                        dsend = 1'b0; st = S_TRAN;
                    end
                end
            end
            // write: CRC status token and busy on DAT0
            if (stat_left != 6'd0) begin
                stat_left = stat_left - 6'd1;
                if (stat_left > 6'd15) begin
                    dat_oe[0] <= 1'b1; dat_o[0] <= stat_sh[7]; stat_sh = {stat_sh[6:0], 1'b0};
                end else if (stat_left > 6'd0) begin
                    dat_oe[0] <= 1'b1; dat_o[0] <= 1'b0;                           // busy
                end else begin
                    dat_oe[0] <= 1'b0; dat_o[0] <= 1'b1;
                    if (!drecv) st = S_TRAN;
                end
            end
        end
    end

    initial begin
        st = S_IDLE; app = 1'b0; wide = 1'b0; rca = 16'h0; acmd41_n = 4'd0; lba = 32'd0; multi = 1'b0;
        sck_q = 1'b0; cbits = 6'd0; rleft = 8'd0; rwait = 4'd0; dsend = 1'b0; drecv = 1'b0; dgot = 1'b0;
        stat_left = 6'd0; ccs_ok = 1'b1;
    end
endmodule
