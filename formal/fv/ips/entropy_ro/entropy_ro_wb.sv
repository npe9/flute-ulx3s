// entropy_ro_wb: the checker for Flute's src_Core/RegFiles/Entropy_Source.bsv (mkEntropy_Source_RO_P,
// the Zkr seed CSR's source; instances in Entropy_Source_Fv.bsv), bound into the DUT (no RTL
// changes).  The raw noise bit (tr_raw, from RO_TRNG) is free: nothing below depends on it being
// random.  What the rings deliver (min-entropy H = 0.5 per sample, assumed by the cutoffs) is
// outside formal: it needs board samples and the SP 800-90B estimators.
// Spec (the ratified Zkr seed CSR + NIST SP 800-90B 4.4), properties on the ports and trace:
//   samples:  raw bits are folded in aligned groups of DEC (from reset); each group's XOR is one
//             sample, health-tested (tr_sample) on the clock of its last bit unless DEAD.
//   RCT:      (4.4.1) a run of RCT identical samples is a failure; the run restarts after one.
//   APT:      (4.4.2) windows of W samples; the first is the reference; APT samples of a window
//             equal to it (the reference included) is a failure; a failure restarts the window.
//             RCT / APT here are cutoffs computed from H = 0.5, alpha = 2^-20, W = 1024 by
//             ips/entropy_ro/cutoffs.py (41, 793), not taken from the RTL.
//   failure:  (tr_fail) the partial word, or an unread full one, is discarded; OPST BIST until a
//             full window passes with no failure; the 4th failure with no ES16 in between: DEAD,
//             sticky (no more tests, seed reads DEAD forever).
//   OPST:     BIST before that window, then WAIT while the next 16 samples are kept (shifted in,
//             first sample highest), ES16 with them in seed[15:0] once 16 are kept; samples are
//             tested but not kept while a full word waits.  seed[29:16] = 0; seed[15:0] = 0
//             unless ES16.  Every seed access consumes: ES16 -> WAIT with an empty word, so a word
//             is never returned twice.
//   FV_PER:   raw periodic with a period dividing DEC (stuck at 0 / 1, alternating, ...): every
//             sample is equal, so the source never leaves BIST (no WAIT, no ES16); bmc: DEAD by
//             clock 4 * DEC * RCT + DEC + 2 (FV_DEADBY).
//   FV_P16:   cover: samples periodic with period 16, half ones, pass both tests and reach ES16.
//             A known limit of the 90B health tests (they catch stuck and badly biased sources),
//             not of this design.
// The INVARIANTS section names internals for k-induction only.
`ifndef ES_TOP
`ifdef FV_REAL
`define ES_TOP mkEntropy_Source_RO_Real
`define ES_DEC 8
`define ES_RCT 41
`define ES_APT 793
`define ES_W 1024
`else
`define ES_TOP mkEntropy_Source_RO_Fv
`define ES_DEC 2
`define ES_RCT 5
`define ES_APT 13
`define ES_W 16
`endif
`endif
`default_nettype none
module entropy_ro_wb #(parameter integer DEC = 8, parameter integer RCT = 41,
                       parameter integer APT = 793, parameter integer W = 1024) (
    input wire        clk, rst_n,
    input wire [31:0] seed, input wire consume,
    input wire        tr_raw, input wire [1:0] tr_sample, input wire tr_fail,
    // internals (INVARIANTS only)
    input wire [2:0]  i_dec_n, input wire i_dec, input wire i_rct_v, input wire [5:0] i_rct_n,
    input wire        i_apt_v, input wire [9:0] i_apt_i, input wire [9:0] i_apt_n,
    input wire [1:0]  i_opst, input wire i_up, input wire [2:0] i_fails,
    input wire [15:0] i_word, input wire [4:0] i_word_n
);
    localparam [1:0] BIST = 2'd0, WAIT = 2'd1, ES16 = 2'd2, DEAD = 2'd3;
    reg rdone = 1'b0;                          // the reset clock has passed
    always @(posedge clk) if (!rst_n) rdone <= 1'b1;
    wire chk = rdone && rst_n;

    // ---------------- the model (flat guarded assignments: see README, sv-yosys pitfalls) ----
    reg [3:0]  m_dn;   reg m_acc;              // raw bits of the current group so far, their XOR
    reg        m_rv;   reg [6:0] m_rn;         // RCT: last sample, run length (0: none yet)
    reg        m_av;   reg [10:0] m_ai, m_an;  // APT: reference, window position, matches
    reg [1:0]  m_op;   reg m_up;   reg [2:0] m_fl;
    reg [15:0] m_w;    reg [4:0] m_wn;
    wire        raw   = tr_raw;
    wire        last  = (m_dn == DEC - 1);
    wire        s_v   = last && m_op != DEAD;  // a sample is tested this clock
    wire        samp  = m_acc ^ raw;
    wire [6:0]  rct_n = (m_rn != 7'd0 && samp == m_rv) ? m_rn + 7'd1 : 7'd1;
    wire        rct_f = rct_n >= RCT;
    wire        first = (m_ai == 11'd0);
    wire [10:0] apt_n = first ? 11'd1 : m_an + {10'd0, samp == m_av};
    wire        apt_f = apt_n >= APT;
    wire        wend  = (m_ai == W - 1);
    wire        fail  = s_v && (rct_f || apt_f);
    wire        ok    = s_v && !fail;
    wire        cons  = consume && m_op == ES16;
    wire [1:0]  op1   = cons ? WAIT : m_op;
    wire [15:0] w1    = cons ? 16'd0 : m_w;
    wire [4:0]  wn1   = cons ? 5'd0 : m_wn;
    wire        keep  = ok && m_up && wn1 < 5'd16;
    wire        full  = keep && wn1 == 5'd15;
    wire [2:0]  fl1   = m_fl + 3'd1;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_dn <= 4'd0; m_acc <= 1'b0; m_rv <= 1'b0; m_rn <= 7'd0; m_av <= 1'b0;
            m_ai <= 11'd0; m_an <= 11'd0; m_op <= BIST; m_up <= 1'b0; m_fl <= 3'd0;
            m_w <= 16'd0; m_wn <= 5'd0;
        end else begin
            m_dn  <= last ? 4'd0 : m_dn + 4'd1;
            m_acc <= last ? 1'b0 : samp;
            if (s_v) m_rv <= samp;
            if (s_v && first) m_av <= samp;
            if (fail) m_rn <= 7'd0;
            if (ok)   m_rn <= rct_n;
            if (fail) m_ai <= 11'd0;
            if (ok)   m_ai <= wend ? 11'd0 : m_ai + 11'd1;
            if (fail) m_an <= 11'd0;
            if (ok)   m_an <= apt_n;
            m_op <= fail ? (fl1 == 3'd4 ? DEAD : BIST) : (ok && !m_up && wend) ? WAIT : full ? ES16 : op1;
            m_up <= fail ? 1'b0 : (ok && wend) ? 1'b1 : m_up;
            m_fl <= fail ? fl1 : full ? 3'd0 : m_fl;
            m_w  <= fail ? 16'd0 : keep ? {w1[14:0], samp} : w1;
            m_wn <= fail ? 5'd0 : keep ? wn1 + 5'd1 : wn1;
        end
    end

    // ---------------- properties at the ports ----------------
    wire [31:0] m_seed = (m_op == ES16) ? {ES16, 14'd0, m_w} : {m_op, 30'd0};
    reg [1:0] p_op = BIST; reg p_cons = 1'b0;
    always @(posedge clk) begin p_op <= seed[31:30]; p_cons <= consume && seed[31:30] == ES16; end
    reg rdone2 = 1'b0;
    always @(posedge clk) rdone2 <= chk;
    always @(*) if (chk) begin
        assert (seed == m_seed);
        assert (tr_sample[1] == s_v);
        if (s_v) assert (tr_sample[0] == samp);
        assert (tr_fail == fail);
        // the same, stated on the ports alone
        assert (seed[29:16] == 14'd0);
        if (seed[31:30] != ES16) assert (seed[15:0] == 16'd0);
        if (tr_fail) assert (tr_sample[1]);
        if (rdone2 && p_op == DEAD) assert (seed[31:30] == DEAD);
        if (rdone2 && p_cons) assert (seed[31:30] != ES16);
        // the model's own reachable-state facts
        assert (m_dn < DEC);
        assert (m_rn < RCT);
        assert (m_ai < W);
        assert (m_an < APT);
        if (m_ai != 11'd0) assert (m_an <= m_ai && m_an != 11'd0);
        assert (m_rn <= m_ai || m_up);
        assert (m_wn <= 5'd16);
        assert (m_fl <= 3'd4);
        assert ((m_fl == 3'd4) == (m_op == DEAD));
        if (m_op == DEAD) assert (!m_up && m_wn == 5'd0);
        if (!m_up) assert ((m_op == BIST || m_op == DEAD) && m_wn == 5'd0 && m_w == 16'd0);
        if (m_up) assert ((m_op == ES16) == (m_wn == 5'd16));
        assert ((m_w >> m_wn) == 16'd0);
    end

    // ---------------- source-failure checks (FV_PER) and the period-16 cover (FV_P16) --------
    reg [7:0]  hist = 8'd0;                    // raw bits since reset, hist[0] the latest
    reg [11:0] hcnt = 12'd0;                   // clocks since reset (saturating)
    always @(posedge clk) begin
        hist <= rst_n ? {hist[6:0], raw} : 8'd0;
        hcnt <= !rst_n ? 12'd0 : (hcnt == 12'hFFF ? hcnt : hcnt + 12'd1);
    end
    reg gx; integer k;
    reg ax;                                    // gx: the last DEC raw bits; ax: the last m_dn
    always @(*) begin
        gx = 1'b0; ax = 1'b0;
        for (k = 0; k < DEC; k = k + 1) begin
            gx = gx ^ hist[k];
            if (k < m_dn) ax = ax ^ hist[k];
        end
    end
`ifdef FV_PER
    always @(*) if (chk && hcnt >= DEC) assume (raw == hist[DEC - 1]);
    always @(*) if (chk) begin
        assert (seed[31:30] == BIST || seed[31:30] == DEAD);
        assert (!m_up);
        assert (m_rn == m_ai[6:0] && m_ai < RCT);
        if (hcnt < DEC) assert (m_dn == hcnt[3:0] && m_rn == 7'd0);
        if (hcnt >= DEC && m_rn != 7'd0) assert (m_rv == gx);
        if (hcnt >= DEC && m_ai != 11'd0) assert (m_av == gx);
        if (hcnt >= m_dn) assert (m_acc == ax);
`ifdef FV_DEADBY
        if (hcnt >= 4 * DEC * RCT + DEC + 1) assert (seed[31:30] == DEAD);
`endif
    end
`endif
`ifdef FV_P16
    reg [15:0] sh = 16'd0; reg [11:0] sn = 12'd0;  // the samples so far, sh[0] the latest
    always @(posedge clk) if (chk && s_v) begin sh <= {sh[14:0], samp}; sn <= sn + 12'd1; end
    always @(*) if (chk && s_v && sn >= 16) assume (samp == sh[15]);
    always @(*) if (chk) cover (seed[31:30] == ES16);
`else
`ifndef FV_PER
    // ---------------- covers ----------------
    reg [1:0] n_es = 2'd0; reg was_es = 1'b0, f_es = 1'b0, f_up = 1'b0;
    always @(posedge clk) if (chk) begin
        was_es <= seed[31:30] == ES16;
        if (seed[31:30] == ES16 && !was_es && n_es != 2'd3) n_es <= n_es + 2'd1;
        if (tr_fail && seed[31:30] == ES16) f_es <= 1'b1;
        if (tr_fail && m_ai != 11'd0) f_up <= 1'b1;
    end
    always @(*) if (chk) begin
        cover (seed[31:30] == ES16);
        cover (n_es == 2'd2);                                   // a word consumed, then another
        cover (seed[31:30] == DEAD);
        cover (tr_fail && !rct_f);                               // an APT failure alone
        cover (f_es && seed[31:30] == WAIT);                    // an unread word discarded, then a new window
        cover (f_up && seed[31:30] == ES16);                     // a failure mid-window, later ES16
    end
`endif
`endif

    // ---------------- INVARIANTS (DUT internals; induction strengthening only) ----------------
`ifndef FV_NO_INV
    always @(*) if (chk) begin
        assert ({1'b0, i_dec_n} == m_dn);
        assert (i_dec == m_acc);
        assert ({1'b0, i_rct_n} == m_rn);
        if (m_rn != 7'd0) assert (i_rct_v == m_rv);
        assert ({1'b0, i_apt_i} == m_ai);
        if (m_ai != 11'd0) assert ({1'b0, i_apt_n} == m_an && i_apt_v == m_av);
        assert (i_opst == m_op);
        assert (i_up == m_up);
        assert (i_fails == m_fl);
        assert (i_word == m_w);
        assert (i_word_n == m_wn);
    end
`endif
endmodule

bind `ES_TOP entropy_ro_wb #(.DEC(`ES_DEC), .RCT(`ES_RCT), .APT(`ES_APT), .W(`ES_W)) wb (
    .clk(CLK), .rst_n(RST_N), .seed(seed), .consume(EN_consume),
    .tr_raw(tr_raw), .tr_sample(tr_sample), .tr_fail(tr_fail),
    .i_dec_n(m_m_rg_dec_n), .i_dec(m_m_rg_dec), .i_rct_v(m_m_rg_rct_v), .i_rct_n(m_m_rg_rct_n),
    .i_apt_v(m_m_rg_apt_v), .i_apt_i(m_m_rg_apt_i), .i_apt_n(m_m_rg_apt_n),
    .i_opst(m_m_rg_opst), .i_up(m_m_rg_startup_done), .i_fails(m_m_rg_fails),
    .i_word(m_m_rg_word), .i_word_n(m_m_rg_word_n));
`default_nettype wire
