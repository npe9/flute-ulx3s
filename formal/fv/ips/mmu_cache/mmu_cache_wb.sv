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
    fv_queue #(.W(4), .D(15)) qaw (.clk(clk), .rst(rst), .push(aw_hs), .din(awid),
        .pop(b_hs), .head(aw_h), .n(aw_n), .full(), .ents());
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
        if (arv_q) assert (arvalid && {arid, araddr, arlen} == ar_p);
        if (awv_q) assert (awvalid && {awid, awaddr, awlen} == aw_p);
        if (wv_q)  assert (wvalid && {wdata, wstrb, wlast} == w_p);
        assert (ar_n < 2);                 // one read burst at a time (each FSM path waits for its R)
        // the fabric holds no more writes than the cache counts (each AW counted when enqueued,
        // uncounted only when its B is popped; one boot reset, so never cleared with writes in
        // flight): with D = 15 the write queue cannot overflow, with no timing argument
        assert (aw_n <= wr_ctr);
        // a read burst outstanding only in a state waiting for its R beats (PTW_LEVEL_1 / _0,
        // CACHE_START_REFILL / SNAPSHOT / REFILL, IO_AWAITING_READ_RSP / _AMO_READ_RSP): a lemma
        // toward ar_n < 2 and K_R
        if (ar_n != 0) assert (st == 5'd9 || st == 5'd10 || st == 5'd13 || st == 5'd14 ||
                               st == 5'd15 || st == 5'd23 || st == 5'd26);
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
        assert (c_idle < K_IDLE);
        assert (c_wait < K_WAIT);
        assert (c_rst < K_RST);
        assert (c_rr < K_R);
        assert (c_br < K_B);
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
    .wr_ctr(ctr_wr_rsps_pending_crg), .st(rg_state),
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
