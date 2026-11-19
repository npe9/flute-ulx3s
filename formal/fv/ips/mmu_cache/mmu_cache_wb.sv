// mmu_cache_wb: deadlock freedom of Flute's D-side mkMMU_Cache, as bounded liveness (safety
// counters), bound into the DUT (no RTL changes).  The hangs this core had (AGENTS.md E8, E8b,
// E8c) were all at this module's request / busy contract, so that is what is checked: given a CPU
// that keeps the contract and a fair fabric, every request is answered, busy always drops, every
// reset or flush completes, and every read beat and write response is taken.
//
// Assumed (the environment's obligations, stated at the ports):
//   CPU (CPU_Stage2 / Near_Mem_Caches, the RLD-4 + E8 contract):
//     - one cache reset request after power-on reset (CPU reset), its response taken when ready;
//     - an op enters Stage2 with ma_kill_echo, only when Stage2 is empty (no request owed or
//       launched and unanswered, or its answer arrives this cycle), and only outside a reset or
//       flush; a dmem op (free choice) is then launched with req in the first cycle mv_busy is
//       low (rl_launch_dmem_req), and Stage2 waits for valid;
//     - FENCE / FENCE.I flush (server_flush) and SFENCE.VMA (tlb_flush, also !mv_busy) only with
//       Stage2 empty; flush responses taken when ready;
//     - req fields: op LD / ST / AMO, an f3 the decoder can produce for it; address, data,
//       privilege, SUM, MXR and satp free except address [11:7] = 0 (two of the 64 cache
//       sets, so the RAMs can be the small exact stand-in vip/bsclib/bram2_lowsets.v); the PMP table free but fixed; ma_ddr4_ready held high
//       (the SoC pulses it every cycle once the SDRAM is initialized).
//   Fabric (AXI4 slave, burst-capable): AR, AW, W accepted within L cycles of being offered; read
//     bursts answered in order, each beat within L cycles, RID = ARID, RLAST on beat ARLEN, beats
//     held until taken; one B per write burst once its AW and its last W are in, in order, within
//     L cycles, BID = AWID, held until taken; RRESP / BRESP free (errors included).
// Asserted:
//   K_RSP:  a launched request is answered (valid) within K_RSP cycles;
//   K_BUSY: outside a reset or flush, mv_busy is never high K_BUSY cycles in a row;
//   K_IDLE: nor K_IDLE cycles in a row with nothing owed: no request launched and unanswered,
//           no AR / AW / W offered, no read burst or write response outstanding (E8b / E25: a
//           hold state counted as busy is exactly this, and the CPU then waits forever);
//   K_WAIT: a launched request unanswered never waits K_WAIT cycles in a row with nothing owed by
//           the fabric (no AR / AW / W offered, nothing outstanding).  The longest such run seen
//           is 9 (a uDTLB fill, a re-request, then the refill's AR); K_WAIT = 16.  With K_IDLE
//           this is the hang half of deadlock freedom, free of latency: a wait the fabric
//           doesn't owe ends within a few cycles;
//   K_RST:  a reset or flush request gets its response within K_RST cycles;
//   K_R / K_B: a read beat / write response offered is taken within K_R / K_B cycles;
//   the master side of AXI4: AR / AW / W held, with stable payload, until accepted.
`default_nettype none
module mmu_cache_wb (
    input wire        clk, rst_n,
    input wire [3:0]  wr_ctr,     // the cache's ctr_wr_rsps_pending (for the lemma)
    input wire [4:0]  st,         // the cache's rg_state (Module_State, MODULE_PRERESET = 0)
    input wire [7:0]  snap_cnt,   // the cache's rg_snap_cnt (CACHE_SNAPSHOT's word counter)
    input wire        ar_enqs, ar_deqs,   // rg_ar_enqs / rg_ar_deqs: an AR staged when they differ
    input wire [1:0]  epoch,      // the cache's rg_epoch (the low ARID / AWID bits; stale R / B dropped)
    input wire [2:0]  rf_cw,      // the low bits of rg_cset_cword_in_cache: the refill's next word
    input wire        r_ne,       // the transactor's R FIFO (FIFO2) not empty; rready is its not-full
    input wire        b_ne,       // the transactor's B FIFO (FIFO2) not empty; bready is its not-full
    input wire        kecho,      // the cache's rg_kill_echo (RLD-4: set by ma_kill_echo, cleared by req)
    input wire [1:0]  rq_op, input wire [2:0] rq_f3, input wire [31:0] rq_addr,   // rg_op / rg_f3 / rg_addr (written only by req)
    input wire        u_any_d, u_any, u_byp,   // rg_u_any's D_IN (a uDTLB entry matches now), rg_u_any (last cycle), rg_udtlb_bypass
    input wire        u_cq, u_cn, u_pq, u_pn, u_tq, u_tn,   // the uDTLB's ctx / pmp / tlb seq and seen bits
    input wire [408:0] rg_pmp_in,  // the cache's rg_pmp (ma_pmp_t registered every cycle)
    input wire        age_seen, req_seq,   // rg_age_seen / rg_req_seq: the probe waits a cycle after req / REREQ
    input wire        en_verb,
    input wire        en_rst_req, rdy_rst_req, en_rst_rsp, rdy_rst_rsp,
    input wire [1:0]  req_op, input wire [2:0] req_f3, input wire [31:0] req_addr, input wire en_req,
    input wire        valid, exc,
    input wire        en_kill,
    input wire        en_fl_req, rdy_fl_req, en_fl_rsp, rdy_fl_rsp, en_tlb_flush, rdy_tlb_flush,
    input wire        awvalid, awready, input wire [3:0] awid, input wire [63:0] awaddr,
    input wire [7:0]  awlen,
    input wire        wvalid, wready, input wire [63:0] wdata, input wire [7:0] wstrb, input wire wlast,
    input wire        bvalid, bready, input wire [3:0] bid,
    input wire        arvalid, arready, input wire [3:0] arid, input wire [63:0] araddr,
    input wire [7:0]  arlen,
    input wire        rvalid, rready, input wire [3:0] rid, input wire [63:0] rdata,
    input wire [1:0]  rresp, input wire rlast, input wire [1:0] bresp,
    input wire        en_ddr4, input wire [408:0] pmp,
    input wire        busy
);
`ifndef FV_L
`define FV_L 2
`endif
`ifndef FV_K_RSP
`define FV_K_RSP 96
`endif
`ifndef FV_K_BUSY
`define FV_K_BUSY 96
`endif
`ifndef FV_K_RST
`define FV_K_RST 96
`endif
`ifndef FV_K_IDLE
`define FV_K_IDLE 4
`endif
`ifndef FV_K_WAIT
`define FV_K_WAIT 16
`endif
    localparam integer L = `FV_L, K_RSP = `FV_K_RSP, K_BUSY = `FV_K_BUSY, K_RST = `FV_K_RST,
                       K_IDLE = `FV_K_IDLE, K_WAIT = `FV_K_WAIT;
    // a refill's AR leaves before CACHE_SNAPSHOT (cwords_per_cline + 2 = 10 cycles) has read the
    // victim's other-way words, so its beats can wait that long in the 2-entry R FIFO
`ifndef FV_K_R
`define FV_K_R 16
`endif
`ifndef FV_K_B
`define FV_K_B 16
`endif
    localparam integer K_R = `FV_K_R, K_B = `FV_K_B;
    // FV_ASSUME_PROVEN: the properties abc pdr proves on the 1 KB build (safet) become assumptions,
    // sound once proved, so a k-induction counterexample is about what is still open (K_WAIT)
`ifdef FV_ASSUME_PROVEN
`define FV_PROVEN assume
`else
`define FV_PROVEN assert
`endif
    wire rst = !rst_n;

    // ---------------- the CPU ----------------
    reg booted = 1'b0;     // the boot reset request has been made
    reg rst_out = 1'b0;    // a reset or flush is outstanding (no Stage2 traffic meanwhile)
    reg stg = 1'b0;        // a dmem op in Stage2, not yet launched
    reg pend = 1'b0;       // launched, not yet answered
    (* anyseq *) reg dm;   // the op entering Stage2 is a dmem op
    wire s2_empty = !stg && (!pend || valid);
    always @(*) begin
        assume (!en_verb && en_ddr4);
        assume (en_rst_req == (rst_n && !booted && rdy_rst_req));
        assume (en_rst_rsp == rdy_rst_rsp);
        assume (en_fl_rsp == rdy_fl_rsp);
        if (en_fl_req) assume (rdy_fl_req && booted && !rst_out && !stg && !pend);
        if (en_tlb_flush) assume (rdy_tlb_flush && booted && !rst_out && !stg && !pend && !busy);
        if (en_kill) assume (booted && !rst_out && s2_empty && !en_fl_req && !en_tlb_flush);
        assume (en_req == (booted && !rst_out && stg && !busy));
        if (en_req) begin
            assume (req_op != 2'd3);
            assume (req_addr[11:7] == 5'd0);    // cache sets 0 and 1 (vip/bsclib/bram2_lowsets.v)
            if (req_op == 2'd0) assume (req_f3 != 3'd6 && req_f3 != 3'd7);    // LB..LD, LBU, LHU
            if (req_op == 2'd1) assume (req_f3[2] == 1'b0);                   // SB..SD
            if (req_op == 2'd2) assume (req_f3 == 3'd2);                      // AMO*.W, LR.W, SC.W
        end
    end
    always @(posedge clk) begin
        if (en_rst_req) booted <= 1'b1;
        if (en_rst_req || en_fl_req) rst_out <= 1'b1;
        if (en_rst_rsp || en_fl_rsp) rst_out <= 1'b0;
        if (pend && valid) pend <= 1'b0;
        if (en_kill) stg <= dm;
        if (en_req) begin stg <= 1'b0; pend <= 1'b1; end
        if (rst) begin booted <= 1'b0; rst_out <= 1'b0; stg <= 1'b0; pend <= 1'b0; end
    end
    reg [408:0] pmp0;
    always @(posedge clk) pmp0 <= pmp;
    reg past = 1'b0;
    always @(posedge clk) past <= 1'b1;
    always @(*) if (past) assume (pmp == pmp0);

    // ---------------- the fabric ----------------
    // AR / AW / W acceptance within L cycles
    reg [3:0] c_ar = 0, c_aw = 0, c_w = 0;
    always @(posedge clk) begin
        c_ar <= (arvalid && !arready) ? c_ar + 1 : 0;
        c_aw <= (awvalid && !awready) ? c_aw + 1 : 0;
        c_w  <= (wvalid && !wready) ? c_w + 1 : 0;
        if (rst) begin c_ar <= 0; c_aw <= 0; c_w <= 0; end
    end
    always @(*) begin
        if (arvalid && c_ar >= L) assume (arready);
        if (awvalid && c_aw >= L) assume (awready);
        if (wvalid && c_w >= L) assume (wready);
    end
    wire ar_hs = arvalid && arready, aw_hs = awvalid && awready, w_hs = wvalid && wready;
    wire r_hs = rvalid && rready, b_hs = bvalid && bready;
    // read bursts in order
    wire [11:0] ar_h; wire [3:0] ar_n;
    fv_queue #(.W(12), .D(4)) qar (.clk(clk), .rst(rst), .push(ar_hs), .din({arid, arlen}),
        .pop(r_hs && rlast), .head(ar_h), .n(ar_n), .full(), .ents());
    reg [7:0] beat = 0;
    always @(posedge clk) begin
        if (r_hs) beat <= rlast ? 8'd0 : beat + 8'd1;
        if (rst) beat <= 0;
    end
    reg [3:0] c_rv = 0;
    always @(posedge clk) begin
        c_rv <= (ar_n != 0 && !rvalid) ? c_rv + 1 : 0;
        if (rst) c_rv <= 0;
    end
    always @(*) begin
        if (rvalid) assume (ar_n != 0 && rid == ar_h[11:8] && rlast == (beat == ar_h[7:0]));
        if (ar_n != 0 && c_rv >= L) assume (rvalid);
    end
    reg rv_q = 0, bv_q = 0; reg [70:0] r_q; reg [5:0] b_q;
    always @(posedge clk) begin
        rv_q <= rvalid && !rready; r_q <= {rid, rdata, rresp, rlast};
        bv_q <= bvalid && !bready; b_q <= {bid, bresp};
        if (rst) begin rv_q <= 0; bv_q <= 0; end
    end
    always @(*) begin
        if (rv_q) assume (rvalid && {rid, rdata, rresp, rlast} == r_q);
        if (bv_q) assume (bvalid && {bid, bresp} == b_q);
    end
    // write responses: one per burst whose AW and last W are both in, in AW order
    wire [3:0] aw_h; wire [3:0] aw_n;
    // depth 15: the cache allows 15 writes in flight (ctr_wr_rsps_pending, 4 bits, blocks at max)
    wire [59:0] aw_ents;
    fv_queue #(.W(4), .D(15)) qaw (.clk(clk), .rst(rst), .push(aw_hs), .din(awid),
        .pop(b_hs), .head(aw_h), .n(aw_n), .full(), .ents(aw_ents));
    reg [3:0] n_wl = 0;    // last beats in, not yet answered
    always @(posedge clk) begin
        n_wl <= n_wl + ((w_hs && wlast) ? 1 : 0) - (b_hs ? 1 : 0);
        if (rst) n_wl <= 0;
    end
    wire b_owed = aw_n != 0 && n_wl != 0;
    reg [3:0] c_bv = 0;
    always @(posedge clk) begin
        c_bv <= (b_owed && !bvalid) ? c_bv + 1 : 0;
        if (rst) c_bv <= 0;
    end
    always @(*) begin
        if (bvalid) assume (b_owed && bid == aw_h);
        if (b_owed && c_bv >= L) assume (bvalid);
    end

    // ---------------- the cache ----------------
    // master-side AXI4: valid held, payload stable, until the handshake
    reg arv_q = 0, awv_q = 0, wv_q = 0; reg [75:0] ar_p; reg [75:0] aw_p; reg [72:0] w_p;
    always @(posedge clk) begin
        arv_q <= arvalid && !arready; ar_p <= {arid, araddr, arlen};
        awv_q <= awvalid && !awready; aw_p <= {awid, awaddr, awlen};
        wv_q  <= wvalid && !wready;   w_p  <= {wdata, wstrb, wlast};
        if (rst) begin arv_q <= 0; awv_q <= 0; wv_q <= 0; end
    end
    always @(*) if (rst_n) begin
        if (arv_q) `FV_PROVEN (arvalid && {arid, araddr, arlen} == ar_p);
        if (awv_q) `FV_PROVEN (awvalid && {awid, awaddr, awlen} == aw_p);
        if (wv_q)  `FV_PROVEN (wvalid && {wdata, wstrb, wlast} == w_p);
        `FV_PROVEN (ar_n < 2);                 // one read burst at a time (each FSM path waits for its R)
        // the fabric holds no more writes than the cache counts (each AW counted when enqueued,
        // uncounted only when its B is popped; one boot reset, so never cleared with writes in
        // flight): with D = 15 the write queue cannot overflow, with no timing argument
        `FV_PROVEN (aw_n <= wr_ctr);
        // every write and read the fabric holds carries the current epoch (one boot reset), so
        // the transactor takes each B / R the fabric gives
        for (int i = 0; i < 15; i++) if (i < aw_n) assert (aw_ents[4*i +: 4] == {2'b00, epoch});
        if (ar_n != 0) assert (ar_h[11:8] == {2'b00, epoch});
        // an AR offered or staged only in a state awaiting its read (the same 7 states)
        if (arvalid || ar_enqs != ar_deqs)
            assert (st == 5'd9 || st == 5'd10 || st == 5'd13 || st == 5'd14 ||
                    st == 5'd15 || st == 5'd23 || st == 5'd26);
        // a state working on a request has it pending (uDTLB fill, page walk, refill, AMO, IO)
        if ((st >= 5'd5 && st <= 5'd18) || (st >= 5'd21 && st <= 5'd23) || st >= 5'd25) assert (pend);
        // a kill-echo is raised only with Stage2 empty and cleared by the next req, so a pending
        // request never has it set (else EXCEPTION_RSP / LD_RSP would exit unanswered)
        if (pend) assert (!kecho);
        // req leaves READY, and the only ways back are the kill-echo exits and reset
        if (pend) assert (st > 5'd2);
        // rg_state is one of the 27 Module_State values (5 bits; 27..31 unused)
        assert (st <= 5'd26);
        // and an op is staged in Stage2 only once the previous one is answered (s2_empty)
        if (stg) assert (!pend);
        // the latched request (rg_op / rg_f3 / rg_addr, written only by req) is one the
        // environment allows
        if (pend) begin
            assert (rq_op != 2'd3 && rq_addr[11:7] == 5'd0);
            if (rq_op == 2'd0) assert (rq_f3 != 3'd6 && rq_f3 != 3'd7);
            if (rq_op == 2'd1) assert (rq_f3[2] == 1'b0);
            if (rq_op == 2'd2) assert (rq_f3 == 3'd2);
        end
        // the fabric model's own consistency: the beat counter is within the head burst
        if (ar_n == 0) assert (beat == 0); else assert (beat <= ar_h[7:0]);
        // R beats wait in the transactor only in a state awaiting a read, with no AR offered or
        // staged; a one-beat read's beat only once the fabric has finished it
        if (r_ne) begin
            assert (!arvalid && ar_enqs == ar_deqs);
            assert (st == 5'd9 || st == 5'd10 || st == 5'd13 || st == 5'd14 ||
                    st == 5'd15 || st == 5'd23 || st == 5'd26);
            if (!(st == 5'd13 || st == 5'd14 || st == 5'd15)) assert (ar_n == 0 && rready);
        end
        // refill progress: words taken + beats buffered + beats the fabric owes (+ 8 for an AR not
        // yet accepted) is the line; before CACHE_START_REFILL fires, nothing of it exists
        if (st == 5'd13) assert (!arvalid && ar_enqs == ar_deqs && ar_n == 0 && !r_ne);
        // the snapshot reads the line before any word is taken (rl_cache_snapshot ends at cnt 9)
        if (st == 5'd14) assert (rf_cw == 3'd0 && snap_cnt <= 8'd9);
        if (st == 5'd14 || st == 5'd15)
            assert ({1'b0, rf_cw} + (!r_ne ? 4'd0 : rready ? 4'd1 : 4'd2)
                    + (ar_n != 0 ? 4'd8 - beat[3:0] : 4'd0)
                    + ((arvalid || ar_enqs != ar_deqs) ? 4'd8 : 4'd0) == 4'd8);
        // a one-beat read (a PTE or IO read) in its waiting state: exactly one beat in flight,
        // offered or staged, held by the fabric, or buffered in the transactor
        if (st == 5'd9 || st == 5'd10 || st == 5'd23 || st == 5'd26)
            assert (((arvalid || ar_enqs != ar_deqs) ? 4'd1 : 4'd0) + (ar_n != 0 ? 4'd1 : 4'd0)
                    + (!r_ne ? 4'd0 : rready ? 4'd1 : 4'd2) == 4'd1);
        // a refill reads a line (8 beats on the 1 KB and 8 KB builds), a PTE or IO read one beat
        if (arvalid) assert (arlen == ((st == 5'd13 || st == 5'd14 || st == 5'd15) ? 8'd7 : 8'd0));
        if (ar_n != 0) assert (ar_h[7:0] == ((st == 5'd13 || st == 5'd14 || st == 5'd15) ? 8'd7 : 8'd0));
        // exactly: counted = held by the fabric + offered (the 1-entry AW FIFO) + answered but
        // not yet popped (the 2-entry B FIFO), so a nonzero count always has something owed
        assert ({1'b0, wr_ctr} == {1'b0, aw_n} + (awvalid ? 5'd1 : 5'd0) + (!b_ne ? 5'd0 : bready ? 5'd1 : 5'd2));
        // a read burst outstanding only in a state waiting for its R beats (PTW_LEVEL_1 / _0,
        // CACHE_START_REFILL / SNAPSHOT / REFILL, IO_AWAITING_READ_RSP / _AMO_READ_RSP): a lemma
        // toward ar_n < 2 and K_R
        // the environment's own consistency: ops only while booted and not resetting, and the
        // cache out of its reset states then (k-induction starts from arbitrary states)
        if (pend || stg) `FV_PROVEN (booted && !rst_out);
        if (booted && !rst_out) `FV_PROVEN (st != 5'd0 && st != 5'd1);
        if (ar_n != 0) `FV_PROVEN (!arvalid && ar_enqs == ar_deqs);   // nothing offered or staged
        if (ar_n != 0) `FV_PROVEN (st == 5'd9 || st == 5'd10 || st == 5'd13 || st == 5'd14 ||
                               st == 5'd15 || st == 5'd23 || st == 5'd26);
    end
    // the uDTLB keeps a request's translation: once it hits (or the fill writes an entry), it hits
    // until the request is answered, so a request never fills twice and never refills without
    // a translation.  hit is the uDTLB's combinational hit, hit_r the registered one
    // (rl_probe_and_immed_rsp's, a cycle behind the entries).
    wire u_fresh = (u_cq == u_cn) && (u_pq == u_pn) && (u_tq == u_tn);
    wire u_hit   = (u_fresh && u_any_d) || u_byp;
    wire u_hit_r = (u_fresh && u_any) || u_byp;
    reg u_ok = 1'b0, u_ok1 = 1'b0;
    always @(posedge clk) begin
        u_ok  <= pend && !en_req && (u_ok || u_hit);
        u_ok1 <= u_ok && !en_req;
        if (rst) begin u_ok <= 1'b0; u_ok1 <= 1'b0; end
    end
    always @(*) if (rst_n) begin
        if (pend) assert (rg_pmp_in == pmp);   // so ma_pmp never toggles pmp_seq mid-request (the table is fixed; pend implies no reset last cycle)
        if (pend && u_ok) assert (u_hit);
        if (pend && u_ok1) assert (u_hit_r);
        if (pend && (st == 5'd13 || st == 5'd14 || st == 5'd15)) assert (u_ok);
        // req and CACHE_REREQ toggle rg_req_seq and enter RUNNING; only RUNNING ages it, so the
        // probe always sees a rg_u_any captured from the current request's address
        if (st != 5'd3) assert (age_seen == req_seq);
        if (pend && st == 5'd3 && age_seen == req_seq) assert (u_any == u_any_d);
    end
    // bounded liveness
    reg [1:0] req_op_q;
    always @(posedge clk) if (en_req) req_op_q <= req_op;
    reg [7:0] c_rsp = 0, c_busy = 0, c_rst = 0, c_idle = 0; reg [4:0] c_rr = 0, c_br = 0;
    wire axi_owed = arvalid || awvalid || wvalid || ar_n != 0 || aw_n != 0;
    wire owed = pend || axi_owed;
    reg [7:0] c_wait = 0;    // a launched op unanswered with nothing owed by the fabric
    always @(posedge clk) begin
        c_wait <= (pend && !valid && !axi_owed) ? c_wait + 1 : 0;
        if (rst) c_wait <= 0;
    end
    // ghost: the uDTLB fill already happened in this fabric-free wait (UDTLB_FILL2 seen)
    wire wait_on = pend && !valid && !axi_owed;
    reg fill_done = 1'b0;
    always @(posedge clk) begin
        if (st == 5'd7 && wait_on) fill_done <= 1'b1;
        if (!wait_on) fill_done <= 1'b0;
        if (rst) fill_done <= 1'b0;
    end
    always @(*) if (rst_n && fill_done && wait_on) begin
        assert (st != 5'd5);   // the uDTLB hits after a fill (a lemma toward K_WAIT)
    end
    // and the wait so far is short on each side of it: K_WAIT's inductive step
    always @(*) if (rst_n && wait_on) begin
        if (!fill_done) assert (c_wait <= 6);
        else assert (c_wait <= 12);
    end
    always @(posedge clk) begin
        c_rsp  <= (pend && !valid) ? c_rsp + 1 : 0;
        c_busy <= (busy && !rst_out) ? c_busy + 1 : 0;   // a reset / flush: K_RST
        c_idle <= (busy && !rst_out && !owed) ? c_idle + 1 : 0;
        c_rst  <= (rst_out && !en_rst_rsp && !en_fl_rsp) ? c_rst + 1 : 0;
        c_rr   <= (rvalid && !rready) ? c_rr + 1 : 0;
        c_br   <= (bvalid && !bready) ? c_br + 1 : 0;
        if (rst) begin c_rsp <= 0; c_busy <= 0; c_rst <= 0; c_idle <= 0; c_rr <= 0; c_br <= 0; end
    end
    always @(*) if (rst_n) begin
        assert (c_rsp < K_RSP);
        assert (c_busy < K_BUSY);
        `FV_PROVEN (c_idle < K_IDLE);
        assert (c_wait < K_WAIT);
        assert (c_rst < K_RST);
        `FV_PROVEN (c_rr < K_R);
        `FV_PROVEN (c_br < K_B);
        // per-state bound on an R beat's wait, a lemma toward K_R: the 2-entry R FIFO only backs
        // up while CACHE_SNAPSHOT reads the victim line (rg_snap_cnt <= cwords_per_cline + 1),
        // and CACHE_REFILL drains it; every other state takes a beat the cycle it is offered
        if (st == 5'd14) `FV_PROVEN (c_rr <= snap_cnt);
        else if (st == 5'd15) `FV_PROVEN (c_rr <= 10);
        else `FV_PROVEN (c_rr == 0);
    end
`ifdef FV_REACH
    // Reachability by a failing assertion (abc bmc3 is far faster here than smtbmc's cover):
    // the expected result is FAIL, its trace the witness.  The refill takes ~50 steps past reset.
    always @(*) if (rst_n) assert (!(r_hs && rlast && ar_h[7:0] != 0));
`endif
`ifdef FV_COVER
    always @(*) if (rst_n) begin
        cover (booted && !rst_out);                       // reset done
        cover (pend && valid && req_op_q == 2'd0);        // a load answered
        cover (pend && valid && req_op_q == 2'd1);        // a store answered
        cover (pend && valid && req_op_q == 2'd2);        // an AMO answered
        cover (r_hs && rlast && ar_h[7:0] != 0);          // a refill burst completed
        cover (pend && valid && exc);                     // an exception answered
        cover (rst_out && booted && en_fl_rsp);           // a flush completed
    end
`endif
endmodule

bind mkMMU_Cache mmu_cache_wb wb (
    .wr_ctr(ctr_wr_rsps_pending_crg), .st(rg_state), .snap_cnt(rg_snap_cnt),
    .ar_enqs(rg_ar_enqs), .ar_deqs(rg_ar_deqs), .b_ne(\master_xactor_f_wr_resp$EMPTY_N ), .r_ne(\master_xactor_f_rd_data$EMPTY_N ), .rf_cw(rg_cset_cword_in_cache[2:0]), .epoch(rg_epoch), .kecho(rg_kill_echo), .rq_op(rg_op), .rq_f3(rg_f3), .rq_addr(rg_addr), .u_any_d(\rg_u_any$D_IN ), .u_any(rg_u_any), .u_byp(rg_udtlb_bypass),
    .u_cq(rg_udtlb_ctx_seq), .u_cn(rg_udtlb_ctx_seen), .u_pq(rg_udtlb_pmp_seq), .u_pn(rg_udtlb_pmp_seen),
    .u_tq(rg_udtlb_tlb_seq), .u_tn(rg_udtlb_tlb_seen), .rg_pmp_in(rg_pmp), .age_seen(rg_age_seen), .req_seq(rg_req_seq),
    .clk(CLK), .rst_n(RST_N), .en_verb(EN_set_verbosity),
    .en_rst_req(EN_server_reset_request_put), .rdy_rst_req(RDY_server_reset_request_put),
    .en_rst_rsp(EN_server_reset_response_get), .rdy_rst_rsp(RDY_server_reset_response_get),
    .req_op(req_op), .req_f3(req_f3), .req_addr(req_addr), .en_req(EN_req), .valid(valid), .exc(exc),
    .en_kill(EN_ma_kill_echo),
    .en_fl_req(EN_server_flush_request_put), .rdy_fl_req(RDY_server_flush_request_put),
    .en_fl_rsp(EN_server_flush_response_get), .rdy_fl_rsp(RDY_server_flush_response_get),
    .en_tlb_flush(EN_tlb_flush), .rdy_tlb_flush(RDY_tlb_flush),
    .awvalid(mem_master_awvalid), .awready(mem_master_awready), .awid(mem_master_awid),
    .awaddr(mem_master_awaddr), .awlen(mem_master_awlen),
    .wvalid(mem_master_wvalid), .wready(mem_master_wready), .wdata(mem_master_wdata),
    .wstrb(mem_master_wstrb), .wlast(mem_master_wlast),
    .bvalid(mem_master_bvalid), .bready(mem_master_bready), .bid(mem_master_bid),
    .arvalid(mem_master_arvalid), .arready(mem_master_arready), .arid(mem_master_arid),
    .araddr(mem_master_araddr), .arlen(mem_master_arlen),
    .rvalid(mem_master_rvalid), .rready(mem_master_rready), .rid(mem_master_rid),
    .rdata(mem_master_rdata), .rresp(mem_master_rresp), .rlast(mem_master_rlast),
    .bresp(mem_master_bresp),
    .en_ddr4(EN_ma_ddr4_ready), .pmp(ma_pmp_t), .busy(mv_busy));
`default_nettype wire
