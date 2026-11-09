// Formal harness for src/Audio.v (formal/audio/audio.sby), unbounded by k-induction.
//   bus:     rb_ack one cycle per request, one cycle after it; ID; a write to a full FIFO is dropped
//            and flagged, never stalls; volume resets to mute and outputs start at silence
//   FIFO:    level = pushes - pops within 0..256; a symbolic slot keeps what was written and is what
//            the player takes: samples come out unchanged and in order, nothing lost or repeated
//   DAC:     outside the clipped top code, each output step conserves the level exactly:
//            code * 4096 + next accumulator = sample + accumulator, so the mean output is the sample
//   muted:   at volume 0 the sample register holds silence
module audio_fv (input clk, input rb_valid_i, input rb_we, input [11:0] rb_addr, input [31:0] rb_wdata,
                 input [3:0] rb_wstrb);
    reg [1:0] rc = 0; wire rst = rc != 2'd3;
    always @(posedge clk) if (rst) rc <= rc + 1;
    reg pv = 0; always @(posedge clk) pv <= 1;
    (* anyconst *) reg [7:0] idx;
    wire rb_ack; wire [31:0] rb_rdata; wire [3:0] al, ar;
    wire [31:0] slot, q, cur; wire [7:0] wp, rp; wire [8:0] level; wire pop; wire [11:0] acc; wire [15:0] u, rc2, rate; wire do_pop, dpush; wire [3:0] volume;
    wire rb_valid = rb_valid_i && !rst;
    reg ack_q = 0, valid_q = 0; reg [11:0] addr_q; reg we_q; reg [31:0] wd_q; reg [3:0] st_q;
    always @(posedge clk) begin ack_q <= rb_ack; valid_q <= rb_valid; addr_q <= rb_addr; we_q <= rb_we; wd_q <= rb_wdata; st_q <= rb_wstrb; end
    always @(*) if (pv && !rst) begin
        if (valid_q && !ack_q) assume (rb_valid && rb_addr == addr_q && rb_we == we_q && rb_wdata == wd_q && rb_wstrb == st_q);
        if (ack_q) assume (!rb_valid);
        assume (rb_addr[1:0] == 0);
    end
    audio #(.RATE_RESET(16'd2)) dut (.clk(clk), .rst(rst), .rb_valid(rb_valid), .rb_we(rb_we), .rb_addr(rb_addr), .rb_wdata(rb_wdata),
               .rb_wstrb(rb_wstrb), .rb_ack(rb_ack), .rb_rdata(rb_rdata), .audio_l(al), .audio_r(ar),
               .f_idx(idx), .f_slot(slot), .f_wp(wp), .f_rp(rp), .f_level(level), .f_pop(pop), .f_q(q), .f_cur(cur),
               .f_acc_l(acc), .f_u_l(u), .f_rate_cnt(rc2), .f_rate(rate), .f_do_pop(do_pop), .f_push(dpush), .f_volume(volume));
    wire take = rb_valid && !rb_ack;
    wire is_push = take && rb_we && rb_addr[5:2] == 4'd5 && rb_wstrb == 4'hF;
    wire full = level[8], empty = level == 0;

    // ---------------- bus ----------------
    always @(posedge clk) if (pv && !rst && $past(pv)) begin
        if ($past(rst)) assert (!rb_ack && al == 4'h8 && ar == 4'h8 && level == 0 && wp == 0 && rp == 0);
        if (!$past(rst)) begin
            if (rb_ack) assert ($past(rb_valid) && !$past(rb_ack));
            if ($past(rb_valid) && !$past(rb_ack)) assert (rb_ack);
            if (rb_ack && !we_q && addr_q[5:2] == 0) assert (rb_rdata == 32'h41554431);
        end
    end
    reg [3:0] vol = 0;
    always @(posedge clk) if (rst) vol <= 0; else if (take && rb_we && rb_wstrb != 0 && rb_addr[5:2] == 4'd2) vol <= rb_wdata[3:0];

    always @(*) if (pv && !rst) assert (vol == volume);

    // ---------------- FIFO ----------------
    always @(*) if (pv) begin
        assert (level <= 9'd256);
        assert (wp == rp + level[7:0]);
    end
    // the symbolic slot: its value while it holds a sample
    reg [31:0] val = 0; reg held = 0;
    always @(posedge clk) begin
        if (rst) held <= 0;
        else begin
            if (is_push && !full && wp == idx) begin val <= rb_wdata; held <= 1; end
            else if (do_pop && rp == idx) held <= 0;
        end
    end
    wire [8:0] dist = {1'b0, idx} - {1'b0, rp};          // slots ahead of the reader
    wire [7:0] d8 = idx - rp;
    always @(*) if (pv && !rst) begin
        assert (held == ({1'b0, d8} < level));
        if (held) assert (slot == val);
        if (is_push && full) assert (!dpush);
    end
    // what it delivers: the cycle after the slot's pop, the sample is the value written to it
    reg pop_idx = 0; reg [31:0] pop_val = 0;
    always @(posedge clk) begin
        pop_idx <= !rst && do_pop && rp == idx;
        if (do_pop && rp == idx) pop_val <= val;
    end
    reg pop_idx2 = 0; always @(posedge clk) pop_idx2 <= !rst && pop_idx;
    // q is mem[rp] of a cycle ago: an element ready at a sample time was in RAM a cycle ago
    reg [7:0] rp_q = 0; always @(posedge clk) rp_q <= rp;
    always @(*) if (pv && !rst && pop_idx) assert (pop && rp_q == idx && rp == idx + 8'd1 && q == pop_val);
    always @(*) if (pv && !rst && pop_idx2) assert (cur == pop_val);
    // ---------------- DAC ----------------
    reg [15:0] u_q = 16'h8000; reg [11:0] acc_q = 0;
    always @(posedge clk) begin u_q <= u; acc_q <= acc; end
    always @(posedge clk) if (pv && !rst && !$past(rst) && $past(pv)) begin
        if (u_q[15:12] != 4'hF) assert ({1'b0, al, 12'b0} + {5'b0, acc} == {1'b0, u_q} + {5'b0, acc_q});
        else assert (al == 4'hF);
        assert (ar <= 4'hF);
    end
    always @(posedge clk) if (pv && !rst && !$past(rst) && $past(vol) == 0) assert (u == 16'h8000);

    // ---------------- reachability ----------------
    always @(posedge clk) if (pv && !rst) begin
        cover (pop_idx2 && pop_val == 32'h1234ABCD);
        cover (level == 9'd2 && pop);
    end
endmodule
