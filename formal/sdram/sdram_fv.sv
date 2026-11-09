// Formal harness for mkSdram_Controller (src/Sdram_Controller.bsv) at 50 MHz, built by
// `make formal-sdram-verilog`.  Checks the pins against the W9825G6KH-6 rules of
// sim/linux_bram/sdram_timing_check.v, plus what the sim checker cannot see:
//   init:    first command PRECHARGE ALL, 8 REF, MRS, no ACTIVE before; DQM high in the pause;
//   timing:  ACT only to an idle bank after tRC/tRP/tDAL, tRRD; READ/WRITE only to an open bank,
//            never truncating a BL8; REF/MRS only with all banks idle, tRC after REF;
//   refresh: at most REF_GAP_MAX clocks between REFs after init, whatever the requests do;
//   address: ACT row and bank, READ/WRITE column and burst order from the latched request,
//            auto-precharge exactly on the last burst, empty-mask writes issue nothing;
//   credit:  chunks in flight <= 8, the response FIFO is never full when SDRAM data arrives,
//            a read delivers exactly its chunks, gapless, at the CAS offset;
//   data:    OE exactly for the 8 beats after a WRITE; write beats and DQM from the request;
//            a chunk is the 4 DQ samples in order.
// Trusted, not checked: the request FIFO (library mkSizedFIFOF) between put and the latched
// request; the power-up length (FORMAL_SHORT_PWR, a countdown from clk_hz/5000); the CAS offset
// itself against the part (sim-validated with the IOB registers in src/Top.v).
// Proofs (sdram.sby): prove_k is the data path alone (-D DATA_ONLY: the control asserts are off).
// prove_<group> (abc pdr, -D ONLY_<GROUP>) check one group of control asserts each, so each proof
// has a small cone; the deep bmc and cover tasks have them all.
`ifdef ONLY_ANY
 `define OFF_DEFAULT
`endif
`ifdef DATA_ONLY
 `define OFF_DEFAULT
`endif
`ifdef ONLY_INIT
 `define C_INIT(x) assert x
`elsif OFF_DEFAULT
 `define C_INIT(x)
`else
 `define C_INIT(x) assert x
`endif
`ifdef ONLY_TIMING
 `define C_TIMING(x) assert x
`elsif OFF_DEFAULT
 `define C_TIMING(x)
`else
 `define C_TIMING(x) assert x
`endif
`ifdef ONLY_REFRESH
 `define C_REFRESH(x) assert x
`elsif OFF_DEFAULT
 `define C_REFRESH(x)
`else
 `define C_REFRESH(x) assert x
`endif
`ifdef ONLY_DECODE
 `define C_DECODE(x) assert x
`elsif OFF_DEFAULT
 `define C_DECODE(x)
`else
 `define C_DECODE(x) assert x
`endif
`ifdef ONLY_CREDIT
 `define C_CREDIT(x) assert x
`elsif OFF_DEFAULT
 `define C_CREDIT(x)
`else
 `define C_CREDIT(x) assert x
`endif
module sdram_fv (
    input wire         clk,
    input wire         want_put, input wire [311:0] req_in,
    input wire         want_get,
    input wire [15:0]  dq_in
);
    localparam T_RC = 3, T_RAS = 3, T_RP = 1, T_RRD = 2, T_WR = 2, BL = 8;
    localparam REF_GAP_MAX = 8'd150;     // tREFI at 50 MHz is 390 clocks

    reg [1:0] rcnt = 0;
    always @(posedge clk) if (rcnt != 2'd3) rcnt <= rcnt + 1;
    wire rst_n = (rcnt >= 2'd2);
    reg pv = 0;
    always @(posedge clk) pv <= rst_n;

    wire rdy_put, rdy_get, init_done, cs_n, ras_n, cas_n, we_n, oe, cke, notfull, cap_chunk;
    wire [1:0] ba, dqm; wire [12:0] a; wire [15:0] dq_out; wire [63:0] rsp;
    wire [311:0] f_req; wire [3:0] in_flight; wire [64:0] rsp_enq; wire [4:0] state; wire [15:0] ref_cnt;
    wire [2:0] dut_beat; wire [1:0] dut_burst; wire [15:0] dut_wait; wire [47:0] dut_hw; wire [1:0] dut_burst_last; wire [3:0] dut_bmask;

    mkSdramFormal dut (
        .CLK (clk), .RST_N (rst_n),
        .EN_mem_server_request_put (want_put && rdy_put), .mem_server_request_put (req_in),
        .RDY_mem_server_request_put (rdy_put),
        .EN_mem_server_response_get (want_get && rdy_get), .mem_server_response_get (rsp),
        .RDY_mem_server_response_get (rdy_get),
        .init_done (init_done), .sdram_cke (cke), .sdram_cs_n (cs_n), .sdram_ras_n (ras_n),
        .sdram_cas_n (cas_n), .sdram_we_n (we_n), .sdram_ba (ba), .sdram_a (a), .sdram_dqm (dqm),
        .sdram_dq_out (dq_out), .sdram_dq_oe (oe), .sdram_dq_in_v (dq_in),
        .f_req (f_req), .f_chunks_in_flight (in_flight), .f_rsps_notFull (notfull),
        .f_rsp_enq (rsp_enq), .f_cap_chunk (cap_chunk), .f_state (state), .f_ref_cnt (ref_cnt),
        .f_beat (dut_beat), .f_burst (dut_burst), .f_wait (dut_wait), .f_hw (dut_hw), .f_burst_last (dut_burst_last), .f_bmask (dut_bmask));

    // Raw_Mem_Req: {write, line[18:0], b_first, b_last, wdata[255:0], wbe[31:0]}
    wire         in_write = req_in[311];
    wire [1:0]   in_first = req_in[291:290], in_last = req_in[289:288];
    wire         r_write  = f_req[311];
    wire [18:0]  r_line   = f_req[310:292];
    wire [1:0]   r_first  = f_req[291:290], r_last = f_req[289:288];
    wire [255:0] r_wdata  = f_req[287:32];
    wire [31:0]  r_wbe    = f_req[31:0];
    wire [3:0]   r_mask   = r_first[1] ? {|r_wbe[31:16], |r_wbe[15:0], 2'b00} : {2'b00, |r_wbe[31:16], |r_wbe[15:0]};

    // ---------------- environment: Mem_Controller's request shapes ----------------
    always @(*) begin
        if (in_write) assume (in_first[0] == 1'b0 && in_last == in_first + 2'd1);
        else          assume (in_first <= in_last);
    end

    // the same shapes on the latched request (the request FIFO is trusted to pass them on)
    wire busy_rd = state == 5'd12 || state == 5'd13;
    wire busy_wr = state == 5'd14 || state == 5'd15 || state == 5'd16;
    always @(*) begin
        if (busy_rd) assume (r_first <= r_last);
        if (busy_wr) assume (r_first[0] == 1'b0);
    end

    wire [1:0] first_set = r_mask[0] ? 2'd0 : r_mask[1] ? 2'd1 : r_mask[2] ? 2'd2 : 2'd3;
    wire [1:0] last_set  = r_mask[3] ? 2'd3 : r_mask[2] ? 2'd2 : r_mask[1] ? 2'd1 : 2'd0;
    // ---------------- pins ----------------
    wire [3:0] cmd = (cs_n || !rst_n) ? 4'b0111 : {1'b0, ras_n, cas_n, we_n};   // registers are arbitrary before the first reset edge
    wire c_act = cmd == 4'b0011, c_rd = cmd == 4'b0101, c_wr = cmd == 4'b0100,
         c_pre = cmd == 4'b0010, c_ref = cmd == 4'b0001, c_mrs = cmd == 4'b0000;
    wire c_rw = c_rd || c_wr;

    // per-bank model (down counters, 0 = satisfied)
    reg [3:0] open = 0, ap = 0;
    reg [5:0] pre_ok0 = 0, pre_ok1 = 0, pre_ok2 = 0, pre_ok3 = 0;
    reg [5:0] ready0 = 0, ready1 = 0, ready2 = 0, ready3 = 0;
    wire [5:0] pre_ok_b = ba == 0 ? pre_ok0 : ba == 1 ? pre_ok1 : ba == 2 ? pre_ok2 : pre_ok3;
    wire [5:0] ready_b  = ba == 0 ? ready0  : ba == 1 ? ready1  : ba == 2 ? ready2  : ready3;
    wire bank_closing0 = ap[0] && pre_ok0 == 0, bank_closing1 = ap[1] && pre_ok1 == 0,
         bank_closing2 = ap[2] && pre_ok2 == 0, bank_closing3 = ap[3] && pre_ok3 == 0;
    wire [3:0] open_now = open & ~{bank_closing3, bank_closing2, bank_closing1, bank_closing0};
    wire [3:0] ap_now   = ap   & ~{bank_closing3, bank_closing2, bank_closing1, bank_closing0};
    wire all_idle = open_now == 0 && ready0 == 0 && ready1 == 0 && ready2 == 0 && ready3 == 0;
    reg [3:0] act_age = 15, ref_age = 15, burst_end = 0;
    function automatic [5:0] dn (input [5:0] x); dn = x == 0 ? 0 : x - 1; endfunction
    function automatic [5:0] mx (input [5:0] x, input [5:0] y); mx = x > y ? x : y; endfunction
    wire [5:0] pre_after = c_wr ? mx (dn (pre_ok_b), BL - 1 + T_WR) : mx (dn (pre_ok_b), BL);
    wire [5:0] ready_after = a[10] ? mx (dn (ready_b), pre_after + T_RP) : dn (ready_b);

    `define BANK(i, PO, RY) \
        if (c_act && ba == i) begin PO <= T_RAS - 1; RY <= T_RC - 1; end \
        else if (c_rw && ba == i) begin PO <= pre_after - 1; RY <= ready_after == 0 ? 0 : ready_after - 1; end \
        else begin PO <= dn (PO); RY <= (c_ref ? mx (dn (RY), T_RC - 1) : c_pre ? mx (dn (RY), T_RP - 1) : dn (RY)); end

    always @(posedge clk) begin
        `BANK(0, pre_ok0, ready0)
        `BANK(1, pre_ok1, ready1)
        `BANK(2, pre_ok2, ready2)
        `BANK(3, pre_ok3, ready3)
        open <= open_now; ap <= ap_now;
        if (c_act) begin open[ba] <= 1'b1; act_age <= 0; end
        else if (act_age != 15) act_age <= act_age + 1;
        if (c_rw && a[10]) ap[ba] <= 1'b1;
        if (c_pre) begin
            if (a[10]) begin open <= 0; end else open[ba] <= 1'b0;
        end
        ref_age <= c_ref ? 0 : (ref_age != 15 ? ref_age + 1 : ref_age);
        burst_end <= (c_rw && a[10]) ? BL - 1 : (burst_end != 0 ? burst_end - 1 : 0);
    end

    // ---------------- init ----------------
    reg seen_cmd = 0, seen_pall = 0, seen_mrs = 0; reg [3:0] n_ref = 0;
    always @(posedge clk) if (rst_n) begin
        if (cmd != 4'b0111) seen_cmd <= 1;
        if (c_pre && a[10]) seen_pall <= 1;
        if (c_mrs) seen_mrs <= 1;
        if (c_ref && !seen_mrs && n_ref != 15) n_ref <= n_ref + 1;
    end
    always @(*) if (pv) begin
        `C_INIT((cke));
        if (!seen_cmd) `C_INIT((cmd == 4'b0111 || (c_pre && a[10])));
        if (!seen_cmd) `C_INIT((dqm == 2'b11));
        if (c_mrs) begin `C_INIT((seen_pall && n_ref == 4'd8)); `C_INIT((a == 13'h0023 && ba == 0)); end
        if (c_act || c_rw) `C_INIT((seen_mrs));
        if (init_done) `C_INIT((seen_mrs));
        `C_INIT((n_ref <= 4'd8 || seen_mrs));
    end

    reg [7:0] ref_gap = 0;
    // Hand-off from the init group to the refresh group (assume-guarantee, not circular: the
    // init proof has no refresh assumption).  Proved for the FORMAL_SHORT_PWR countdown.  With the
    // real 200 us pause ref_cnt has run down to 1 by the MRS and the gap is the few cycles since the
    // last init REF, which meets the same condition; the refresh proof allows both.
    wire mrs_st  = !seen_mrs && state == 5'd8 && dut_wait <= 16'd4;
    wire mrs_gap = ref_cnt > 16'd1 ? {8'b0, ref_gap} + ref_cnt <= 16'd98 : ref_gap <= 8'd90;
`ifdef ONLY_REFRESH
    always @(*) if (pv && c_mrs) assume (mrs_st && mrs_gap);
`elsif ONLY_DECODE
    always @(*) if (pv && c_mrs) assume (mrs_st);
    always @(*) if (pv && (c_act || c_rw)) assume (seen_mrs);    // C_INIT
`else
    always @(*) if (pv && c_mrs) `C_INIT((mrs_st));
`endif
`ifdef ONLY_ANY
 `ifdef ONLY_HANDOFF
    // prove_handoff is a BMC past the first MRS: nothing in the init sequence depends on an input,
    // so one run is every run, and mrs_st says it never comes again.  The cover task shows it got there.
    always @(*) if (pv && c_mrs) assert (mrs_gap);
 `endif
`elsif DATA_ONLY
`else
    always @(*) if (pv && c_mrs) assert (mrs_gap);
`endif
    always @(*) cover (pv && c_mrs);

    // ---------------- timing ----------------
    always @(*) if (pv) begin
        if (c_act) begin
            `C_TIMING((!open_now[ba] && !ap_now[ba]));
            `C_TIMING((ready_b == 0));
            `C_TIMING((act_age >= T_RRD - 1));
        end
        if (c_rw) begin
            `C_TIMING((open_now[ba] && !ap_now[ba]));
            `C_TIMING((burst_end == 0));
        end
        if (c_ref) begin `C_TIMING((all_idle)); `C_TIMING((ref_age >= T_RC - 1)); end
        if (c_mrs) `C_TIMING((all_idle));
        if (c_pre) `C_TIMING((a[10] && !seen_cmd));   // the controller precharges only at init
    end

    // ---------------- refresh ----------------
    always @(posedge clk) ref_gap <= (!rst_n || c_ref) ? 0 : (ref_gap != 8'hFF ? ref_gap + 1 : ref_gap);
    always @(*) if (pv && seen_mrs) `C_REFRESH((ref_gap <= REF_GAP_MAX));
    // invariants for k-induction: the gap tracks the countdown; a due refresh is served within
    // one request (a window as long as the longest request sees it through)
    reg [5:0] due_age = 0;
    always @(posedge clk)
        if (!rst_n || c_ref || c_mrs || ref_cnt > 16'd1) due_age <= 0;
        else if (due_age != 6'd63) due_age <= due_age + 1;
    always @(*) if (pv) begin
        `C_REFRESH((state <= 5'd18 && state != 5'd10 && state != 5'd11));      // ST_ACT, ST_RCD_WAIT: unused
        `C_REFRESH((ref_cnt <= 16'd98));
        if (seen_mrs) begin
            `C_REFRESH((due_age <= 6'd50));
            if (ref_cnt > 16'd1) begin if (!c_ref) `C_REFRESH(({8'b0, ref_gap} + ref_cnt <= 16'd98)); end   // reloaded at the REF pin, the gap clears a cycle later
            else                 `C_REFRESH(({2'b0, ref_gap} <= 10'd97 + due_age));
        end
    end

    // ranking function: an upper bound on the cycles left in the current request.  It falls every
    // cycle (the FIFO never stalls the capture: credit group), so a due refresh waits at most
    // RANK_MAX cycles for IDLE, whatever the requests do.
    localparam [6:0] RANK_MAX = 7'd50;
    wire [6:0] bursts_after = {5'b0, dut_burst_last - dut_burst};
    reg [6:0] rank;
    always @(*) case (state)
        // counted back from REF (1), through IDLE (2)
        5'd8:    rank = {3'b0, dut_wait[3:0]} + 7'd3;                                                     // ST_MRS_WAIT
        5'd9:    rank = 7'd2;                                                                             // ST_IDLE
        5'd12:   rank = 7'd15 + (bursts_after << 3);                                                      // ST_RD
        5'd13:   rank = {3'b0, dut_wait[3:0]} + (bursts_after << 3) + (7'd8 - {4'b0, dut_beat}) + 7'd2;   // ST_RD_CAP (gapless)
        5'd14:   rank = 7'd11 + (bursts_after << 3);                                                      // ST_WR
        5'd15:   rank = (bursts_after << 3) + (7'd8 - {4'b0, dut_beat}) + 7'd3;                           // ST_WR_DATA (holes only skip)
        5'd16:   rank = 7'd3;                                                                             // ST_WR_END
        5'd17:   rank = 7'd1;                                                                             // ST_REF
        default: rank = 7'd8;                                                                             // ST_REF_WAIT
    endcase
    always @(*) if (pv && seen_mrs) begin
        `C_REFRESH((state >= 5'd8 && state != 5'd10 && state != 5'd11));
        if (state == 5'd8 || state == 5'd13 || state == 5'd18) `C_REFRESH((dut_wait <= 16'd4));
        if (busy_rd) `C_REFRESH((!r_write && dut_burst_last == r_last && r_first <= dut_burst && dut_burst <= dut_burst_last));
        if (busy_wr) begin
            `C_REFRESH((r_write && dut_bmask == r_mask && dut_burst_last == last_set));
            `C_REFRESH((r_mask[dut_burst] && dut_burst <= dut_burst_last));
        end
        if (state == 5'd18) `C_REFRESH((ref_cnt >= 16'd90));
        if (ref_cnt <= 16'd1 && !c_ref && state != 5'd18) `C_REFRESH(({1'b0, due_age} + rank <= RANK_MAX));
    end

    // ---------------- request decode ----------------
    reg have_prev = 0; reg [1:0] prev_b = 0;
    reg [7:0] rw_age = 8'hFF;
    wire [1:0] cmd_b = a[4:3];
    wire [1:0] next_set = (r_mask[1] && prev_b < 1) ? 2'd1 : (r_mask[2] && prev_b < 2) ? 2'd2 : 2'd3;
    always @(posedge clk) begin
        if (c_act) have_prev <= 0;
        if (c_rw) begin have_prev <= 1; prev_b <= cmd_b; end
        rw_age <= c_rw ? 0 : (rw_age != 8'hFF ? rw_age + 1 : rw_age);
    end
    always @(*) if (pv) begin
        if (c_act) begin
            `C_DECODE((a == r_line[18:6] && ba == r_line[1:0]));
            if (r_write) `C_DECODE((r_mask != 0));
        end
        if (c_rw) begin
            `C_DECODE((ba == r_line[1:0]));
            `C_DECODE((a[12:11] == 0 && a[9] == 0 && a[8:5] == r_line[5:2] && a[2:0] == 0));
            `C_DECODE((c_wr == r_write));
            if (have_prev) `C_DECODE((rw_age == BL - 1));      // BL8, gapless, never truncated
        end
        if (c_rd) begin
            `C_DECODE((cmd_b == (have_prev ? prev_b + 2'd1 : r_first)));
            `C_DECODE((a[10] == (cmd_b == r_last)));
        end
        if (c_wr) begin
            `C_DECODE((cmd_b == (have_prev ? next_set : first_set)));
            `C_DECODE((a[10] == (cmd_b == last_set)));
        end
    end

    // invariants for k-induction: the pins follow the FSM (pin and state registers load together,
    // so a READ pin shows with wait 3 or beat 5, a WRITE pin with WR_DATA beat 1)
    wire [3:0] w4 = dut_wait[3:0];
    always @(*) if (pv && seen_mrs) begin
        `C_DECODE((state >= 5'd8 && state <= 5'd18 && state != 5'd10 && state != 5'd11));
        if (busy_rd) begin
            `C_DECODE((!r_write && dut_burst_last == r_last && r_first <= dut_burst && dut_burst <= dut_burst_last));
        end
        if (busy_wr) begin
            `C_DECODE((r_write && dut_bmask == r_mask && dut_burst_last == last_set));
            `C_DECODE((r_mask[dut_burst] && dut_burst <= dut_burst_last));
        end
        if (state == 5'd13) begin
            `C_DECODE((dut_wait <= 16'd3));
            if (w4 != 0) `C_DECODE((dut_beat == 0 && dut_burst == r_first));
            if (w4 == 3) `C_DECODE((c_rd && !have_prev && cmd_b == r_first));
            else begin
                `C_DECODE((have_prev));
                if (w4 != 0)             `C_DECODE((prev_b == dut_burst && rw_age == 8'd2 - {4'b0, w4}));
                else if (dut_beat <= 5)  `C_DECODE((prev_b == dut_burst && rw_age == 8'd2 + {5'b0, dut_beat}));
                else if (dut_burst != dut_burst_last) `C_DECODE((prev_b == dut_burst + 2'd1 && rw_age == {5'b0, dut_beat} - 8'd6));
                else                     `C_DECODE((prev_b == dut_burst));
            end
        end
        if (state == 5'd14) begin
            if (c_act) `C_DECODE((dut_burst == first_set));
            else `C_DECODE((have_prev && rw_age == 8'd6 && dut_burst == next_set));
        end
        if (state == 5'd15) begin
            `C_DECODE((dut_beat != 0));
            if (dut_beat == 1) begin
                `C_DECODE((c_wr && cmd_b == dut_burst));
                if (have_prev) `C_DECODE((rw_age == 8'd7 && dut_burst == next_set));
                else           `C_DECODE((dut_burst == first_set));
            end
            else `C_DECODE((have_prev && prev_b == dut_burst && rw_age == {5'b0, dut_beat} - 8'd2));
        end
    end

    // ---------------- read credit and delivery ----------------
    reg [3:0] chunks_left = 0; reg [7:0] rd_age = 8'hFF; reg rd_active = 0;
    wire [3:0] n_chunks = ({2'b0, r_last} - {2'b0, r_first} + 4'd1) << 1;
    always @(posedge clk) begin
        if (!rst_n) begin chunks_left <= 0; rd_active <= 0; end
        else if (c_act && !r_write) begin chunks_left <= n_chunks; rd_active <= 0; end
        else if (rsp_enq[64]) chunks_left <= chunks_left - 1;
        if (c_rd && !have_prev) begin rd_active <= 1; rd_age <= 0; end
        else if (rd_active && rd_age != 8'hFF) rd_age <= rd_age + 1;
    end
    always @(*) if (pv) begin
        `C_CREDIT((in_flight <= 4'd8));
        if (cap_chunk) `C_CREDIT((notfull));                    // SDRAM data cannot be stalled
        if (rsp_enq[64]) begin
            `C_CREDIT((chunks_left != 0 && rd_active));
            `C_CREDIT((rd_age >= 8'd5 && rd_age[1:0] == 2'd1));  // READ + 6 (rd_age lags by 1), then every 4 clocks
        end
        if (c_act) `C_CREDIT((chunks_left == 0));               // the previous read delivered everything
    end

    // invariants for k-induction: every chunk promised is in the FIFO or still to come, and the
    // FSM says how many are still to come.  The FIFO itself is the contract proved in fifo.sby.
    reg [3:0] fifo_cnt = 0;
    wire rsp_deq = want_get && rdy_get;
    always @(posedge clk)
        if (!rst_n) fifo_cnt <= 0;
        else fifo_cnt <= fifo_cnt + (rsp_enq[64] ? 4'd1 : 4'd0) - (rsp_deq ? 4'd1 : 4'd0);
`ifdef ONLY_CREDIT
    always @(*) begin
        if (fifo_cnt < 4'd8) assume (notfull);
        if (fifo_cnt == 0)   assume (!rdy_get);
    end
`endif
    wire [3:0] bursts_left_rd = {2'b0, dut_burst_last - dut_burst};
    wire [7:0] bursts_done_rd = {6'b0, dut_burst - r_first};
    always @(*) if (pv) begin
        `C_CREDIT((state <= 5'd18 && state != 5'd10 && state != 5'd11));
        `C_CREDIT((fifo_cnt <= 4'd8));
        `C_CREDIT(({1'b0, in_flight} == {1'b0, fifo_cnt} + {1'b0, chunks_left} + (state == 5'd12 ? {1'b0, n_chunks} : 5'd0)));
        if (c_act) `C_CREDIT((state == 5'd12 || state == 5'd14));
        if (c_rw)  `C_CREDIT((state == 5'd13 || state == 5'd15));
        if (state != 5'd13) `C_CREDIT((chunks_left == 0));
        if (state == 5'd12) `C_CREDIT((c_act && !r_write && dut_burst == r_first && dut_burst_last == r_last));
        if (state == 5'd13) begin
            `C_CREDIT((!r_write && dut_burst_last == r_last && r_first <= dut_burst && dut_burst <= dut_burst_last));
            `C_CREDIT((dut_wait <= 16'd3));
            if (dut_wait != 0) `C_CREDIT((dut_beat == 0 && dut_burst == r_first));
            `C_CREDIT((chunks_left == (bursts_left_rd << 1) + (dut_beat <= 3'd3 ? 4'd2 : 4'd1)));
            if (dut_wait == 16'd3) `C_CREDIT((c_rd && !have_prev));
            else begin
                `C_CREDIT((have_prev && rd_active));
                if (dut_wait != 0) `C_CREDIT((rd_age == 8'd2 - dut_wait[7:0]));
                else               `C_CREDIT((rd_age == 8'd2 + (bursts_done_rd << 3) + {5'b0, dut_beat}));
            end
        end
    end

`ifdef ONLY_REFRESH
 `define ASSUME_CREDIT
`endif
`ifdef ONLY_DECODE
 `define ASSUME_CREDIT
`endif
`ifdef DATA_ONLY
 `define ASSUME_CREDIT
`endif
`ifdef ASSUME_CREDIT
    // the credit property, checked by the control tasks (which assume nothing from this one)
    always @(*) assume (!cap_chunk || notfull);
`endif
`ifndef NO_DATA
    // ---------------- data ----------------
    reg [15:0] p1 = 0, p2 = 0, p3 = 0, p4 = 0;
    always @(posedge clk) begin p1 <= dq_in; p2 <= p1; p3 <= p2; p4 <= p3; end
    reg [3:0] wr_beats = 0; reg [1:0] wr_b = 0; reg [2:0] wr_beat = 0;
    wire [2:0] beat_now = c_wr ? 3'd0 : wr_beat;
    wire [1:0] b_now    = c_wr ? cmd_b : wr_b;
    wire [3:0] idx      = {b_now[0], beat_now};
    always @(posedge clk) begin
        if (c_wr) begin wr_beats <= 4'd7; wr_b <= cmd_b; wr_beat <= 3'd1; end
        else if (wr_beats != 0) begin wr_beats <= wr_beats - 1; wr_beat <= wr_beat + 1; end
    end
    always @(*) if (pv) begin
        assert (oe == (c_wr || wr_beats != 0));              // OE exactly for the 8 write beats
        if (oe) begin
            assert (dqm == ~{r_wbe[{idx, 1'b1}], r_wbe[{idx, 1'b0}]});
            assert (dq_out == r_wdata[16*idx +: 16]);
        end
        if (rsp_enq[64]) assert (rsp_enq[63:0] == {p1, p2, p3, p4});
        // invariants: the beat tracker follows the write states (rg_beat runs one ahead of the pins)
        if (state == 5'd15) begin      // ST_WR_DATA
            assert (oe && beat_now == dut_beat - 3'd1 && dut_beat != 0);
            if (c_wr) assert (dut_beat == 3'd1 && cmd_b == dut_burst);
            else      assert ({1'b0, wr_beats} == 5'd9 - {2'b0, dut_beat} && wr_b == dut_burst);
        end
        if (state == 5'd16) assert (oe && wr_beats == 4'd1 && wr_beat == 3'd7 && wr_b == dut_burst);   // ST_WR_END
        if (state == 5'd14) assert (oe == (wr_beats == 4'd1) && !c_wr && (wr_beats <= 4'd1));          // ST_WR
        if (state == 5'd14 && oe) assert (wr_beat == 3'd7);
        if (state != 5'd14 && state != 5'd15 && state != 5'd16) assert (!oe && wr_beats == 0 && !c_wr);
        // invariants: the read capture registers follow the DQ history
        if (state == 5'd13) assert (dut_wait <= 16'd3);       // ST_RD_CAP
        if (state == 5'd13 && dut_wait == 0) begin
            if (dut_beat[1:0] == 2'd1) assert (dut_hw[15:0] == p2);
            if (dut_beat[1:0] == 2'd2) assert (dut_hw[31:16] == p2 && dut_hw[15:0] == p3);
            if (dut_beat[1:0] == 2'd3) assert (dut_hw[47:32] == p2 && dut_hw[31:16] == p3 && dut_hw[15:0] == p4);
        end
        assert (state <= 5'd18);
    end
`endif

    // ---------------- reachability ----------------
    always @(*) if (pv && seen_mrs) begin
        cover (c_ref);
        cover (rsp_enq[64] && r_first == 0 && r_last == 3 && chunks_left == 1);   // full line read
        cover (c_wr && a[10] && have_prev);                                       // 2-burst write
        cover (c_act && !r_write && in_flight == 4'd6);                           // credits in use
    end
endmodule
