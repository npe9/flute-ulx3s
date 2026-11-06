// Formal harness for video_fb (src/Video_DVI.v), system (register-bus) side.
// Assumes the register-bus contract of src/AXI4_RegBus.bsv; checks the device's half of it and
// that the pixel RAM, palette and control registers read back what was written.
// Single formal clock: pclk is the same clock here (as in the Verilator benches); the
// two-clock behaviour is a separate multiclock job.
// Pixel RAM shrunk to 36 words in 8-word banks: the same 5 banks with a partial last one, bank
// muxes and address decode as the 38400-word part, small enough for an unbounded (pdr) proof.
module video_fb_fv (
    input wire        clk,
    input wire        rb_valid,
    input wire        rb_we,
    input wire [31:0] rb_addr,
    input wire [31:0] rb_wdata,
    input wire [3:0]  rb_wstrb
);
    localparam FB_WORDS = 36, BANK_BITS = 3;

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst = init;

    wire        rb_ack;
    wire [31:0] rb_rdata;
    wire [9:0]  tr, tg, tb;
    wire        ptog;
    wire [23:0] dbg_rgb;
    wire        dbg_de, dbg_hs, dbg_vs;

    video_fb #(.FB_WORDS (FB_WORDS), .BANK_BITS (BANK_BITS)) dut (.clk (clk), .rst (rst),
                  .rb_valid (rb_valid), .rb_we (rb_we), .rb_addr (rb_addr),
                  .rb_wdata (rb_wdata), .rb_wstrb (rb_wstrb),
                  .rb_ack (rb_ack), .rb_rdata (rb_rdata),
                  .pclk (clk), .tmds_r (tr), .tmds_g (tg), .tmds_b (tb), .ptog (ptog),
                  .dbg_rgb (dbg_rgb), .dbg_de (dbg_de), .dbg_hs (dbg_hs), .dbg_vs (dbg_vs),
                  .f_sw (sw), .f_sp (sp), .f_word (f_word), .f_pal (f_pal), .f_mode (f_mode));
    wire [31:0] f_word;
    wire [23:0] f_pal;
    wire [2:0]  f_mode;

    // ---------------- bridge contract (assumptions) ----------------
    reg past_valid_q = 1'b0;
    always @(posedge clk) past_valid_q <= 1'b1;

    always @(*) begin
        if (init) assume (!rb_valid);
        assume (rb_addr[1:0] == 2'b00);
        // the bridge only addresses the two windows (0xC001_0xxx control, 0xC1xx_xxxx RAM)
        assume (rb_addr[31:25] == 7'h60);
        assume (rb_addr[24] || rb_addr[23:12] == 12'h010);
    end
    always @(posedge clk) if (past_valid_q) begin
        // held, stable, until the ack cycle
        if ($past(rb_valid) && !$past(rb_ack)) begin
            assume (rb_valid);
            assume (rb_we    == $past(rb_we));
            assume (rb_addr  == $past(rb_addr));
            assume (rb_wdata == $past(rb_wdata));
            assume (rb_wstrb == $past(rb_wstrb));
        end
        // dropped the cycle after the ack
        if ($past(rb_ack)) assume (!rb_valid);
    end

    // ---------------- device half of the contract ----------------
    reg [3:0] wait_cnt = 0;      // cycles the current request has been waiting
    always @(posedge clk)
        wait_cnt <= (rb_valid && !rb_ack) ? wait_cnt + 1 : 0;

    always @(*) if (!init) begin
        assert (!rb_ack || rb_valid);                    // ack only for a pending request
        assert (wait_cnt <= 4'd5);                       // a read is acked 5 cycles after it appears
        if (rb_valid && rb_we) assert (wait_cnt <= 4'd1);  // a write the cycle after
        if (rb_ack) assert (wait_cnt == (rb_we ? 4'd1 : 4'd5));   // exactly
    end
    always @(posedge clk) if (past_valid_q && !init)
        if ($past(rb_ack)) assert (!rb_ack);             // one-cycle pulse

    // ---------------- pixel RAM: one symbolic word ----------------
    (* anyconst *) reg [15:0] sw;
    always @(*) assume (sw < FB_WORDS);
    wire is_fb  = rb_addr[24];
    wire hit_sw = is_fb && rb_addr[23:18] == 0 && rb_addr[17:2] == sw;
    reg [31:0] shadow;
    reg [3:0]  known = 4'b0;
    wire wack = !init && rb_valid && rb_ack && rb_we;     // a write the device has taken
    integer b;
    always @(posedge clk) if (wack && hit_sw)
        for (b = 0; b < 4; b = b + 1)
            if (rb_wstrb[b]) begin shadow[8*b +: 8] <= rb_wdata[8*b +: 8]; known[b] <= 1'b1; end
    always @(*) if (!init && rb_ack && !rb_we && hit_sw)
        for (b = 0; b < 4; b = b + 1)
            if (known[b]) assert (rb_rdata[8*b +: 8] == shadow[8*b +: 8]);

    // reads with no RAM behind them return 0
    wire fb_unbacked = is_fb && (rb_addr[23:18] != 0 || rb_addr[17:2] >= FB_WORDS);
    always @(*) if (!init && rb_ack && !rb_we && fb_unbacked) assert (rb_rdata == 32'b0);

    // ---------------- palette: one symbolic entry, from its reset value ----------------
    (* anyconst *) reg [7:0] sp;
    function [23:0] pal_reset (input [7:0] k);
        case (k)
            0: pal_reset = 24'h000000;  1: pal_reset = 24'h0000AA;  2: pal_reset = 24'h00AA00;
            3: pal_reset = 24'h00AAAA;  4: pal_reset = 24'hAA0000;  5: pal_reset = 24'hAA00AA;
            6: pal_reset = 24'hAA5500;  7: pal_reset = 24'hAAAAAA;  8: pal_reset = 24'h555555;
            9: pal_reset = 24'h5555FF; 10: pal_reset = 24'h55FF55; 11: pal_reset = 24'h55FFFF;
           12: pal_reset = 24'hFF5555; 13: pal_reset = 24'hFF55FF; 14: pal_reset = 24'hFFFF55;
           15: pal_reset = 24'hFFFFFF;
           default: pal_reset = { k[7:5], k[7:5], k[7:6], k[4:2], k[4:2], k[4:3],
                                  k[1:0], k[1:0], k[1:0], k[1:0] };
        endcase
    endfunction
    wire is_pal = !is_fb && rb_addr[11:10] == 2'b01;
    wire hit_sp = is_pal && rb_addr[9:2] == sp;
    reg [23:0] pshadow;
    always @(posedge clk) begin
        if (init) pshadow <= pal_reset (sp);
        else if (wack && hit_sp) pshadow <= rb_wdata[23:0];
    end
    always @(*) if (!init && rb_ack && !rb_we && hit_sp)
        assert (rb_rdata == { 8'b0, pshadow });

    // ---------------- control registers ----------------
    wire is_ctl = !is_fb && rb_addr[11:10] == 2'b00;
    reg [2:0] mshadow = 3'd0;
    always @(posedge clk)
        if (wack && is_ctl && rb_addr[9:2] == 8'h01 && rb_wstrb[0])
            mshadow <= rb_wdata[2:0];
    always @(*) if (!init && rb_ack && !rb_we && is_ctl) begin
        case (rb_addr[9:2])
            8'h00: assert (rb_rdata == 32'h56494431);
            8'h01: assert (rb_rdata == { 29'b0, mshadow });
            8'h02: assert (rb_rdata[31:1] == 0);
            8'h03: ;                                         // frame counter
            8'h04: assert (rb_rdata == FB_WORDS * 4);
            default: assert (rb_rdata == 32'b0);
        endcase
    end
    // reads of the rest of the window (0x800-0xFFF) return 0
    always @(*) if (!init && rb_ack && !rb_we && !is_fb && rb_addr[11])
        assert (rb_rdata == 32'b0);

    // ---------------- invariants (what makes the prove task inductive) ----------------
    // Pixel RAM writes land the cycle after the ack, with the shadow.  Palette and MODE
    // writes land at the take, one cycle before the shadow: skip that ack cycle.
    wire ack_pal  = rb_ack && rb_we && hit_sp;
    wire ack_mode = rb_ack && rb_we && is_ctl && rb_addr[9:2] == 8'h01 && rb_wstrb[0];
    always @(*) if (!init) begin
        for (b = 0; b < 4; b = b + 1)
            if (known[b]) assert (f_word[8*b +: 8] == shadow[8*b +: 8]);
        if (!ack_pal)  assert (f_pal  == pshadow);
        if (!ack_mode) assert (f_mode == mshadow);
    end

    // ---------------- reachability ----------------
    always @(*) if (!init) begin
        cover (rb_ack && !rb_we && hit_sw && known == 4'hF);
        cover (rb_ack && !rb_we && hit_sp && pshadow != pal_reset (sp));
    end
endmodule
