// icache_wb: deadlock freedom of Flute's I-side mkICache_Pipe, as bounded liveness (safety
// counters), bound into the DUT (no RTL changes).  The I side has no busy: the CPU writes the
// wanted pc (req, a register write) and valid rises when the instruction at that pc is presented
// from the fetch queue.  So the liveness obligation is: while the CPU keeps wanting the same
// (pc, priv, satp) and nothing changes the context, valid comes within K_F cycles; and every
// reset and FENCE.I flush completes.  The one I-side hang this cache had (Flute 054d309: a reset
// waited for a refill the fabric's own reset had dropped; the hart stayed unavailable after
// ndmreset) is why resets here may come at any time after boot, with the fabric dropping what it
// had accepted.
//
// Assumed (the environment's obligations, stated at the ports):
//   CPU / Near_Mem:
//     - one cache reset request after power-on reset; later ones (ndmreset) at any time with no
//       reset or flush outstanding; FENCE.I flush requests likewise; responses taken when ready;
//     - req (any cycle once booted, none while a reset or flush is outstanding): f3, priv, SUM,
//       MXR, satp free, the pc 2-byte aligned with pc [11:6] = 0 (cache set 0: the stream runs
//       at most 4 cwords ahead of the wanted one, and a 32-bit instruction straddles at most into
//       set 1, so the two kept sets of vip/bsclib/bram2_lowsets.v are every set it touches);
//     - tlb_flush (SFENCE.VMA) free; the PMP table free but fixed after cycle 0; ma_ddr4_ready
//       held high.
//   Fabric (AXI4 slave, read only on this port): AR accepted within L cycles; read bursts
//     answered in order, each beat within L cycles, RID = ARID, RLAST on beat ARLEN, beats held
//     until taken; RRESP free.  A reset request after boot resets the fabric too (SoC_Top resets
//     both in the same cycle): every burst it had accepted is dropped, and a beat it was offering
//     is withdrawn.  No write responses (the port never writes).
// Asserted:
//   the port never writes (AWVALID, WVALID low); AR held, with stable payload, until accepted;
//   K_F:    once booted, with no reset or flush outstanding, a wanted (pc, priv, satp) is presented
//           (valid) within K_F cycles of the last change of the request or the context (a new
//           pc, priv or satp, tlb_flush, a reset or flush request);
//   K_RST:  a reset or flush request gets its response within K_RST cycles;
//   K_IDLE: a fetch waiting (as for K_F) never waits K_IDLE cycles in a row with nothing owed by
//           the fabric (no AR offered, no burst outstanding); K_IDLE_RST: likewise a reset or
//           flush (its loop walks every tag set without the fabric: sets + margin);
//   K_R:    a read beat offered is taken within K_R cycles.
`default_nettype none
module icache_wb (
    input wire        clk, rst_n,
    input wire [31:0] req_addr, input wire [1:0] req_priv, input wire [31:0] req_satp,
    input wire        en_req, valid,
    input wire        en_rst_req, rdy_rst_req, en_rst_rsp, rdy_rst_rsp,
    input wire        en_fl_req, rdy_fl_req, en_fl_rsp, rdy_fl_rsp,
    input wire        en_tlb_flush,
    input wire        awvalid, wvalid, bvalid,
    input wire        arvalid, arready, input wire [3:0] arid, input wire [63:0] araddr,
    input wire [7:0]  arlen,
    input wire        rvalid, rready, input wire [3:0] rid, input wire [63:0] rdata,
    input wire [1:0]  rresp, input wire rlast,
    input wire        en_ddr4, input wire [408:0] pmp
);
`ifndef FV_L
`define FV_L 2
`endif
`ifndef FV_K_F
`define FV_K_F 96
`endif
`ifndef FV_K_RST
`define FV_K_RST 96
`endif
`ifndef FV_K_IDLE
`define FV_K_IDLE 16
`endif
`ifndef FV_K_IDLE_RST
`define FV_K_IDLE_RST 24
`endif
    localparam integer L = `FV_L, K_F = `FV_K_F, K_RST = `FV_K_RST, K_IDLE = `FV_K_IDLE,
                       K_IDLE_RST = `FV_K_IDLE_RST;
    localparam integer K_R = 8;
    wire rst = !rst_n;

    // ---------------- the CPU ----------------
    reg booted = 1'b0;     // the boot reset request has been made
    reg rst_out = 1'b0;    // a reset or flush is outstanding
    always @(*) begin
        assume (en_ddr4);
        if (!booted) assume (en_rst_req == (rst_n && rdy_rst_req));
        else if (en_rst_req) assume (rdy_rst_req && !rst_out && !en_fl_req);
        if (en_fl_req) assume (rdy_fl_req && booted && !rst_out);
        assume (en_rst_rsp == rdy_rst_rsp);
        assume (en_fl_rsp == rdy_fl_rsp);
        if (en_req) begin
            assume (booted && !rst_out && !en_rst_req && !en_fl_req);
            assume (req_addr[0] == 1'b0 && req_addr[11:6] == 6'd0);
        end
    end
    always @(posedge clk) begin
        if (en_rst_req) booted <= 1'b1;
        if (en_rst_req || en_fl_req) rst_out <= 1'b1;
        if (en_rst_rsp || en_fl_rsp) rst_out <= 1'b0;
        if (rst) begin booted <= 1'b0; rst_out <= 1'b0; end
    end
    reg [408:0] pmp0;
    always @(posedge clk) pmp0 <= pmp;
    reg past = 1'b0;
    always @(posedge clk) past <= 1'b1;
    always @(*) if (past) assume (pmp == pmp0);

    // the wanted request, and its last change
    reg want = 1'b0; reg [31:0] pc_q = 0; reg [1:0] priv_q = 0; reg [31:0] satp_q = 0;
    wire changed = en_req && (!want || req_addr != pc_q || req_priv != priv_q || req_satp != satp_q);
    wire disturb = changed || en_tlb_flush || en_rst_req || en_fl_req;
    always @(posedge clk) begin
        if (en_req) begin want <= 1'b1; pc_q <= req_addr; priv_q <= req_priv; satp_q <= req_satp; end
        if (rst) want <= 1'b0;
    end

    // ---------------- the fabric ----------------
    wire fab_rst = rst || (booted && en_rst_req);   // SoC_Top resets the fabric with the core
    reg [3:0] c_ar = 0;
    always @(posedge clk) begin
        c_ar <= (arvalid && !arready) ? c_ar + 1 : 0;
        if (rst) c_ar <= 0;
    end
    always @(*) if (arvalid && c_ar >= L) assume (arready);
    wire ar_hs = arvalid && arready, r_hs = rvalid && rready;
    wire [11:0] ar_h; wire [3:0] ar_n;
    fv_queue #(.W(12), .D(4)) qar (.clk(clk), .rst(fab_rst), .push(ar_hs && !fab_rst),
        .din({arid, arlen}), .pop(r_hs && rlast), .head(ar_h), .n(ar_n), .full(), .ents());
    reg [7:0] beat = 0;
    always @(posedge clk) begin
        if (r_hs) beat <= rlast ? 8'd0 : beat + 8'd1;
        if (fab_rst) beat <= 0;
    end
    reg [3:0] c_rv = 0;
    always @(posedge clk) begin
        c_rv <= (ar_n != 0 && !rvalid) ? c_rv + 1 : 0;
        if (fab_rst) c_rv <= 0;
    end
    reg rv_q = 0; reg [70:0] r_q;
    always @(posedge clk) begin
        rv_q <= rvalid && !rready && !fab_rst; r_q <= {rid, rdata, rresp, rlast};
        if (rst) rv_q <= 0;
    end
    always @(*) begin
        assume (!bvalid);
        if (rvalid) assume (ar_n != 0 && rid == ar_h[11:8] && rlast == (beat == ar_h[7:0]));
        if (ar_n != 0 && c_rv >= L) assume (rvalid);
        if (rv_q) assume (rvalid && {rid, rdata, rresp, rlast} == r_q);
    end

    // ---------------- the cache ----------------
    reg arv_q = 0; reg [75:0] ar_p;
    always @(posedge clk) begin
        arv_q <= arvalid && !arready; ar_p <= {arid, araddr, arlen};
        if (rst) arv_q <= 0;
    end
    always @(*) if (rst_n) begin
        assert (!awvalid && !wvalid);
        if (arv_q) assert (arvalid && {arid, araddr, arlen} == ar_p);
        assert (ar_n < 4);
    end
    // bounded liveness
    wire waiting = booted && !rst_out && want && !valid;
    wire owed = arvalid || ar_n != 0;
    reg [7:0] c_f = 0, c_rst = 0, c_idle = 0, c_idle_r = 0; reg [4:0] c_rr = 0;
    always @(posedge clk) begin
        c_f    <= (waiting && !disturb) ? c_f + 1 : 0;
        c_rst  <= (rst_out && !en_rst_rsp && !en_fl_rsp) ? c_rst + 1 : 0;
        c_idle <= (waiting && !disturb && !owed) ? c_idle + 1 : 0;
        c_idle_r <= (rst_out && !en_rst_rsp && !en_fl_rsp && !owed) ? c_idle_r + 1 : 0;
        c_rr   <= (rvalid && !rready) ? c_rr + 1 : 0;
        if (rst) begin c_f <= 0; c_rst <= 0; c_idle <= 0; c_idle_r <= 0; c_rr <= 0; end
    end
    always @(*) if (rst_n) begin
        assert (c_f < K_F);
        assert (c_rst < K_RST);
        assert (c_idle < K_IDLE);
        assert (c_idle_r < K_IDLE_RST);
        assert (c_rr < K_R);
    end
    // a reset that cut a refill (the 054d309 scenario), for the witnesses
    reg rst_mid = 1'b0;
    always @(posedge clk) begin
        if (booted && en_rst_req && ar_n != 0) rst_mid <= 1'b1;
        if (rst) rst_mid <= 1'b0;
    end
`ifdef FV_REACH_REFILL
    // reachability by a failing assertion (abc bmc3; expected FAIL, the trace is the witness)
    always @(*) if (rst_n) assert (!(r_hs && rlast && ar_h[7:0] != 0));
`endif
`ifdef FV_REACH_RSTMID
    // a fetch answered after a reset that dropped a burst in flight
    always @(*) if (rst_n) assert (!(rst_mid && booted && !rst_out && want && valid));
`endif
`ifdef FV_COVER
    always @(*) if (rst_n) begin
        cover (booted && !rst_out);
        cover (booted && !rst_out && want && valid);
        cover (r_hs && rlast && ar_h[7:0] != 0);
        cover (rst_out && booted && en_fl_rsp);
        cover (rst_mid && booted && !rst_out && want && valid);
    end
`endif
endmodule

bind mkICache_Pipe icache_wb wb (
    .clk(CLK), .rst_n(RST_N),
    .req_addr(imem_req_addr), .req_priv(imem_req_priv), .req_satp(imem_req_satp),
    .en_req(EN_imem_req), .valid(imem_valid),
    .en_rst_req(EN_server_reset_request_put), .rdy_rst_req(RDY_server_reset_request_put),
    .en_rst_rsp(EN_server_reset_response_get), .rdy_rst_rsp(RDY_server_reset_response_get),
    .en_fl_req(EN_server_flush_request_put), .rdy_fl_req(RDY_server_flush_request_put),
    .en_fl_rsp(EN_server_flush_response_get), .rdy_fl_rsp(RDY_server_flush_response_get),
    .en_tlb_flush(EN_tlb_flush),
    .awvalid(mem_master_awvalid), .wvalid(mem_master_wvalid), .bvalid(mem_master_bvalid),
    .arvalid(mem_master_arvalid), .arready(mem_master_arready), .arid(mem_master_arid),
    .araddr(mem_master_araddr), .arlen(mem_master_arlen),
    .rvalid(mem_master_rvalid), .rready(mem_master_rready), .rid(mem_master_rid),
    .rdata(mem_master_rdata), .rresp(mem_master_rresp), .rlast(mem_master_rlast),
    .en_ddr4(EN_ma_ddr4_ready), .pmp(ma_pmp_t));
`default_nettype wire
