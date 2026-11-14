// sdram_host_mon: an SDR SDRAM host's command and data pins against the JEDEC rules of a part
// with BL8 bursts and zero write latency (here the W9825G6KH-6), in the role-parameter style
// (HOST_IS_DUT=1: the host's rules are asserted; the part's answer, DQ in, is the user's).
// Timings are parameters in clocks of the host's clock.
// Host rules:
//   init:    CKE high throughout; until the first command, NOP with DQM high; the first command is
//            PRECHARGE ALL; MRS (value MODE, bank 0) only after it and N_INIT_REF REFs; no ACTIVE,
//            READ or WRITE before the MRS;
//   timing:  ACTIVE only to an idle bank T_RC after its last ACTIVE and T_RP after it closed (tDAL
//            after an auto-precharged write), T_RRD after any ACTIVE; READ / WRITE only to an open
//            bank not already auto-precharging, never truncating a burst; REF and MRS only with
//            every bank idle, REF T_RC after the last REF; PRECHARGE only as the init's PRECHARGE
//            ALL (the host closes rows by auto-precharge);
//   refresh: after the MRS, at most TREFI clocks between REFs;
//   data:    DQ driven (oe) exactly for the BL beats from each WRITE.
// Outputs: the decoded command, the bank model and the trackers, for the user's checker and its
// invariants (b_now / beat_now: the write burst column bits and beat on the DQ pins now).
`default_nettype none
module sdram_host_mon #(parameter integer HOST_IS_DUT = 1,
                        parameter integer T_RC = 3, T_RAS = 3, T_RP = 1, T_RRD = 2, T_WR = 2, BL = 8,
                        parameter integer N_INIT_REF = 8, parameter [12:0] MODE = 13'h0023,
                        parameter integer TREFI = 390) (
    input  wire        clk, rst,
    input  wire        cke, cs_n, ras_n, cas_n, we_n, input wire [1:0] ba, input wire [12:0] a,
    input  wire [1:0]  dqm, input wire oe,
    output wire        c_nop, c_act, c_rd, c_wr, c_pre, c_ref, c_mrs,
    output wire [3:0]  open_now, ap_now,
    output reg  [5:0]  pre_ok0, pre_ok1, pre_ok2, pre_ok3, ready0, ready1, ready2, ready3,
    output reg  [3:0]  act_age, ref_age, burst_end,
    output reg         seen_cmd, seen_pall, seen_mrs, output reg [3:0] n_ref,
    output reg  [8:0]  ref_gap,
    output reg  [3:0]  wr_beats, output reg [1:0] wr_b, output reg [2:0] wr_beat,
    output wire [1:0]  b_now, output wire [2:0] beat_now
);
    initial begin
        pre_ok0 = 0; pre_ok1 = 0; pre_ok2 = 0; pre_ok3 = 0; ready0 = 0; ready1 = 0; ready2 = 0; ready3 = 0;
        act_age = 4'd15; ref_age = 4'd15; burst_end = 0; seen_cmd = 0; seen_pall = 0; seen_mrs = 0;
        n_ref = 0; ref_gap = 0; wr_beats = 0; wr_b = 0; wr_beat = 0;
    end
    reg [3:0] open = 0, ap = 0;
    reg r_q = 1'b1;
    wire [3:0] cmd = (cs_n || rst) ? 4'b0111 : {1'b0, ras_n, cas_n, we_n};
    assign c_nop = cmd == 4'b0111;
    assign c_act = cmd == 4'b0011;  assign c_rd  = cmd == 4'b0101;  assign c_wr  = cmd == 4'b0100;
    assign c_pre = cmd == 4'b0010;  assign c_ref = cmd == 4'b0001;  assign c_mrs = cmd == 4'b0000;
    wire c_rw = c_rd || c_wr;

    // per bank: pre_ok (clocks until its precharge may start), ready (until an ACTIVE may come)
    wire [5:0] pre_ok_b = ba == 0 ? pre_ok0 : ba == 1 ? pre_ok1 : ba == 2 ? pre_ok2 : pre_ok3;
    wire [5:0] ready_b  = ba == 0 ? ready0  : ba == 1 ? ready1  : ba == 2 ? ready2  : ready3;
    wire [3:0] closing = ap & {pre_ok3 == 0, pre_ok2 == 0, pre_ok1 == 0, pre_ok0 == 0};
    assign open_now = open & ~closing;
    assign ap_now   = ap & ~closing;
    wire all_idle = open_now == 0 && ready0 == 0 && ready1 == 0 && ready2 == 0 && ready3 == 0;
    function automatic [5:0] dn (input [5:0] x); dn = x == 0 ? 6'd0 : x - 6'd1; endfunction
    function automatic [5:0] mx (input [5:0] x, input [5:0] y); mx = x > y ? x : y; endfunction
    wire [5:0] pre_after   = c_wr ? mx (dn (pre_ok_b), BL - 1 + T_WR) : mx (dn (pre_ok_b), BL);
    wire [5:0] ready_after = a[10] ? mx (dn (ready_b), pre_after + T_RP) : dn (ready_b);
    `define SDM_BANK(i, PO, RY) \
        if (c_act && ba == i) begin PO <= T_RAS - 1; RY <= T_RC - 1; end \
        else if (c_rw && ba == i) begin PO <= pre_after - 1; RY <= ready_after == 0 ? 6'd0 : ready_after - 6'd1; end \
        else begin PO <= dn (PO); RY <= (c_ref ? mx (dn (RY), T_RC - 1) : c_pre ? mx (dn (RY), T_RP - 1) : dn (RY)); end
    always @(posedge clk) begin
        r_q <= rst;
        `SDM_BANK(0, pre_ok0, ready0)
        `SDM_BANK(1, pre_ok1, ready1)
        `SDM_BANK(2, pre_ok2, ready2)
        `SDM_BANK(3, pre_ok3, ready3)
        open <= open_now;  ap <= ap_now;
        if (c_act) begin open[ba] <= 1'b1; act_age <= 0; end
        else if (act_age != 4'd15) act_age <= act_age + 4'd1;
        if (c_rw && a[10]) ap[ba] <= 1'b1;
        if (c_pre) begin if (a[10]) open <= 4'd0; else open[ba] <= 1'b0; end
        ref_age   <= c_ref ? 4'd0 : (ref_age != 4'd15 ? ref_age + 4'd1 : ref_age);
        burst_end <= c_rw ? BL - 1 : (burst_end != 0 ? burst_end - 4'd1 : 4'd0);
        if (!rst) begin
            if (!c_nop) seen_cmd <= 1'b1;
            if (c_pre && a[10]) seen_pall <= 1'b1;
            if (c_mrs) seen_mrs <= 1'b1;
            if (c_ref && !seen_mrs && n_ref != 4'd15) n_ref <= n_ref + 4'd1;
        end
        ref_gap <= (rst || c_ref) ? 9'd0 : (ref_gap != 9'h1FF ? ref_gap + 9'd1 : ref_gap);
        if (c_wr) begin wr_beats <= BL - 1; wr_b <= a[4:3]; wr_beat <= 3'd1; end
        else if (wr_beats != 0) begin wr_beats <= wr_beats - 4'd1; wr_beat <= wr_beat + 3'd1; end
        if (rst) begin seen_cmd <= 0; seen_pall <= 0; seen_mrs <= 0; n_ref <= 0; end
    end
    `undef SDM_BANK
    assign beat_now = c_wr ? 3'd0 : wr_beat;
    assign b_now    = c_wr ? a[4:3] : wr_b;

    generate if (HOST_IS_DUT) begin : host
        always @(*) if (!rst && !r_q) begin
            // init
            assert (cke);
            if (!seen_cmd) assert ((c_nop || (c_pre && a[10])) && dqm == 2'b11);
            if (c_mrs) assert (seen_pall && n_ref == N_INIT_REF && a == MODE && ba == 2'd0);
            if (c_act || c_rw) assert (seen_mrs);
            assert (n_ref <= N_INIT_REF || seen_mrs);
            // timing
            if (c_act) assert (!open_now[ba] && !ap_now[ba] && ready_b == 0 && act_age >= T_RRD - 1);
            if (c_rw)  assert (open_now[ba] && !ap_now[ba] && burst_end == 0);
            if (c_ref) assert (all_idle && ref_age >= T_RC - 1);
            if (c_mrs) assert (all_idle);
            if (c_pre) assert (a[10] && !seen_cmd);
            // refresh
            if (seen_mrs) assert (ref_gap <= TREFI);
            // data
            assert (oe == (c_wr || wr_beats != 0));
        end
    end endgenerate
endmodule
`default_nettype wire
