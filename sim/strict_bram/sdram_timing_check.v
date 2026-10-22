// ================================================================
// sdram_timing_check.v -- pin-level JEDEC protocol / timing checker
// for the Winbond W9825G6KH-6 (datasheet rev A04, Mar 2017, section
// 7.1 power-up and 9.5 AC characteristics).  Passive: watches the
// command pins that sdram_model.v (w9825g6) sees and reports every
// violation as
//     [sdram_chk] ERROR <rule>: <detail> @cycle N
// plus a summary on $finish.  It does not change model behaviour,
// so it complements sdram_model.v's data-integrity check: that one
// proves the controller reads back what it wrote, this one proves it
// does so within the part's timing envelope.
//
// -6 grade values used (ns are rounded UP to whole clocks of TCK_PS):
//   tRC 60 ns  tRAS 42 ns (max 100 us)  tRCD 15 ns  tRP 15 ns
//   tRRD 2 tCK  tWR 2 tCK  tCCD 1 tCK  tRSC 2 tCK
//   tRFC: REF-to-REF/ACT is tRC (the datasheet's "Ref/Active to
//   Ref/Active Command Period")
//   tDAL = tWR + tRP after the last write beat (auto-precharge)
//   tREF 64 ms / 8K refresh cycles -> tREFI 7.8125 us; up to 8
//   postponed refreshes are tolerated (JEDEC), so the hard limit on
//   the gap between REF commands is 9 x tREFI.
//   Power-up: >= 200 us of NOP with CKE and DQM high, then
//   PRECHARGE ALL, MRS, and 8 AUTO REFRESH (before or after the MRS)
//   before the first ACTIVE.
// Auto-precharge bursts are treated as non-interruptible (no
// concurrent auto-precharge is claimed by the datasheet).
//
// Not checked: setup/hold (tAS/tAH/tDS/tDH) and tAC/tOH -- those are
// static timing of the IOB registers, covered by P&R, not by a
// cycle-level simulation.
// ================================================================

module sdram_timing_check #(
    parameter integer TCK_PS = 40000,   // controller/SDRAM clock period
    parameter integer BL     = 8        // burst length the model reports
) (
    input wire        clk,
    input wire        cke,
    input wire        cs_n,
    input wire        ras_n,
    input wire        cas_n,
    input wire        we_n,
    input wire [1:0]  ba,
    input wire [12:0] a,
    input wire [1:0]  dqm
);
   localparam CMD_NOP   = 4'b0111;
   localparam CMD_ACT   = 4'b0011;
   localparam CMD_READ  = 4'b0101;
   localparam CMD_WRITE = 4'b0100;
   localparam CMD_PRE   = 4'b0010;
   localparam CMD_REF   = 4'b0001;
   localparam CMD_MRS   = 4'b0000;

   localparam integer T_RC    = (60000 + TCK_PS - 1) / TCK_PS;
   localparam integer T_RAS   = (42000 + TCK_PS - 1) / TCK_PS;
   localparam integer T_RASMX = 100000000 / TCK_PS;            // 100 us
   localparam integer T_RCD   = (15000 + TCK_PS - 1) / TCK_PS;
   localparam integer T_RP    = (15000 + TCK_PS - 1) / TCK_PS;
   localparam integer T_RRD   = 2;
   localparam integer T_WR    = 2;
   localparam integer T_RSC   = 2;
   localparam integer T_PWRUP = (200000000 + TCK_PS - 1) / TCK_PS; // 200 us
   localparam integer T_REFI  = 7812500 / TCK_PS;                  // 7.8125 us
   localparam integer T_REFMX = 9 * T_REFI;

   wire [3:0] cmd = cs_n ? CMD_NOP : {1'b0, ras_n, cas_n, we_n};

   reg [63:0] cyc = 0;
   integer    errors = 0;
   reg        cke_q = 1'b0;

   // per-bank state
   reg        open      [0:3];
   reg [63:0] t_act     [0:3];   // last ACT
   reg [63:0] t_ready   [0:3];   // earliest next ACT (tRP / tDAL / tRC)
   reg [63:0] t_pre_ok  [0:3];   // earliest PRE (tRAS, tWR)
   reg [63:0] t_ap_done [0:3];   // auto-precharge start time (burst end)
   reg        ap_pend   [0:3];

   reg [63:0] t_any_act  = 0;     // last ACT, any bank (tRRD)
   reg        any_act_seen = 1'b0;
   reg [63:0] t_ref_ok   = 0;     // earliest command after REF (tRC)
   reg [63:0] t_mrs_ok   = 0;     // earliest command after MRS (tRSC)
   reg [63:0] t_rw_last  = 0;     // last READ/WRITE (tCCD)
   reg        rw_seen    = 1'b0;
   reg [63:0] t_burst_end = 0;    // non-interruptible AP burst end
   reg [63:0] t_last_ref = 0;
   reg [63:0] max_ref_gap = 0;
   reg [63:0] max_ref_gap_at = 0;
   reg        pwrup_cke_low = 1'b0, pwrup_dqm_low = 1'b0;
   reg [63:0] pwrup_last_bad = 0;   // last pause cycle with CKE or DQM low

   // init sequence tracking
   reg        first_cmd_seen = 1'b0;
   reg        init_pall   = 1'b0;
   reg        init_mrs    = 1'b0;
   integer    init_refs   = 0;
   reg        init_done   = 1'b0;
   reg [63:0] pwrup_start = 0;
   reg        pwrup_ok    = 1'b1;  // CKE/DQM high throughout the pause

   integer    c_POWERUP_200US = 0;
   integer    c_POWERUP_CKE_DQM = 0;
   integer    c_INIT_ORDER = 0;
   integer    c_tRSC = 0;
   integer    c_tRFC = 0;
   integer    c_INIT_SEQUENCE = 0;
   integer    c_ACT_OPEN_BANK = 0;
   integer    c_tRP_tRC = 0;
   integer    c_tRRD = 0;
   integer    c_RW_CLOSED_BANK = 0;
   integer    c_tRCD = 0;
   integer    c_tCCD = 0;
   integer    c_AP_BURST_INTERRUPT = 0;
   integer    c_PRE_DURING_AP = 0;
   integer    c_tRAS_tWR = 0;
   integer    c_REF_NOT_IDLE = 0;
   integer    c_tREFI = 0;
   integer    c_MRS_NOT_IDLE = 0;
   integer    c_tRAS_MAX = 0;
   integer    n_act = 0, n_rd = 0, n_wr = 0, n_pre = 0, n_ref = 0;
   integer    i;

   initial begin
      for (i = 0; i < 4; i = i + 1) begin
         open[i] = 1'b0; t_act[i] = 0; t_ready[i] = 0; t_pre_ok[i] = 0;
         t_ap_done[i] = 0; ap_pend[i] = 1'b0;
      end
   end

   task err (input [8*24-1:0] rule, input [8*96-1:0] msg);
      begin
         errors = errors + 1;
         if (rule == "POWERUP_200US") c_POWERUP_200US = c_POWERUP_200US + 1;
         if (rule == "POWERUP_CKE_DQM") c_POWERUP_CKE_DQM = c_POWERUP_CKE_DQM + 1;
         if (rule == "INIT_ORDER") c_INIT_ORDER = c_INIT_ORDER + 1;
         if (rule == "tRSC") c_tRSC = c_tRSC + 1;
         if (rule == "tRFC") c_tRFC = c_tRFC + 1;
         if (rule == "INIT_SEQUENCE") c_INIT_SEQUENCE = c_INIT_SEQUENCE + 1;
         if (rule == "ACT_OPEN_BANK") c_ACT_OPEN_BANK = c_ACT_OPEN_BANK + 1;
         if (rule == "tRP_tRC") c_tRP_tRC = c_tRP_tRC + 1;
         if (rule == "tRRD") c_tRRD = c_tRRD + 1;
         if (rule == "RW_CLOSED_BANK") c_RW_CLOSED_BANK = c_RW_CLOSED_BANK + 1;
         if (rule == "tRCD") c_tRCD = c_tRCD + 1;
         if (rule == "tCCD") c_tCCD = c_tCCD + 1;
         if (rule == "AP_BURST_INTERRUPT") c_AP_BURST_INTERRUPT = c_AP_BURST_INTERRUPT + 1;
         if (rule == "PRE_DURING_AP") c_PRE_DURING_AP = c_PRE_DURING_AP + 1;
         if (rule == "tRAS_tWR") c_tRAS_tWR = c_tRAS_tWR + 1;
         if (rule == "REF_NOT_IDLE") c_REF_NOT_IDLE = c_REF_NOT_IDLE + 1;
         if (rule == "tREFI") c_tREFI = c_tREFI + 1;
         if (rule == "MRS_NOT_IDLE") c_MRS_NOT_IDLE = c_MRS_NOT_IDLE + 1;
         if (rule == "tRAS_MAX") c_tRAS_MAX = c_tRAS_MAX + 1;
         if (errors <= 50)
            $display ("[sdram_chk] ERROR %0s: %0s @cycle %0d", rule, msg, cyc);
         else if (errors == 51)
            $display ("[sdram_chk] (further errors counted, not printed)");
      end
   endtask

   // Retire a pending auto-precharge once its burst has ended.
   task settle (input integer b);
      begin
         if (ap_pend[b] && cyc >= t_ap_done[b]) begin
            ap_pend[b] = 1'b0;
            open[b]    = 1'b0;
         end
      end
   endtask

   function all_idle (input dummy);
      integer k;
      begin
         all_idle = 1'b1;
         for (k = 0; k < 4; k = k + 1)
            if (open[k] || ap_pend[k] || cyc < t_ready[k]) all_idle = 1'b0;
      end
   endfunction

   reg [8*96-1:0] m;

   always @(posedge clk) begin
      cyc <= cyc + 1;
      cke_q <= cke;
      for (i = 0; i < 4; i = i + 1) settle (i);

      // ---- power-up pause: NOP, CKE and DQM high, >= 200 us ----
      // cyc 0 is the simulator's time-zero state, before any register has clocked
      if (cyc != 0 && !first_cmd_seen && cmd == CMD_NOP && (!cke || dqm != 2'b11)) begin
         pwrup_ok = 1'b0;
         if (!cke) pwrup_cke_low = 1'b1;
         if (dqm != 2'b11) pwrup_dqm_low = 1'b1;
         pwrup_last_bad = cyc;
      end

      if (cke_q && cmd != CMD_NOP) begin
         if (!first_cmd_seen) begin
            first_cmd_seen = 1'b1;
            if (cyc < T_PWRUP) begin
               $sformat (m, "first command after %0d clocks, need %0d (200 us)", cyc, T_PWRUP);
               err ("POWERUP_200US", m);
            end
            if (!pwrup_ok)
            begin
               $sformat (m, "not held high during the power-up pause:%0s%0s (last low at cycle %0d)",
                         pwrup_cke_low ? " CKE" : "", pwrup_dqm_low ? " DQM" : "", pwrup_last_bad);
               err ("POWERUP_CKE_DQM", m);
            end
            if (!(cmd == CMD_PRE && a[10]))
               err ("INIT_ORDER", "first command is not PRECHARGE ALL");
         end
         if (cyc < t_mrs_ok) err ("tRSC", "command within tRSC of MODE REGISTER SET");
         if (cyc < t_ref_ok) err ("tRFC", "command within tRC of AUTO REFRESH");

         case (cmd)
           CMD_ACT: begin
              n_act = n_act + 1;
              if (!init_done) begin
                 $sformat (m, "ACTIVE before init complete (PALL=%0d MRS=%0d REFs=%0d of 8)",
                           init_pall, init_mrs, init_refs);
                 err ("INIT_SEQUENCE", m);
                 init_done = 1'b1;   // report once
              end
              if (open[ba] || ap_pend[ba]) err ("ACT_OPEN_BANK", "ACTIVE to a bank that is not idle");
              if (cyc < t_ready[ba]) begin
                 $sformat (m, "bank %0d ACTIVE %0d clocks early (tRP/tRC/tDAL)", ba, t_ready[ba] - cyc);
                 err ("tRP_tRC", m);
              end
              if (any_act_seen && cyc < t_any_act + T_RRD) err ("tRRD", "ACTIVE to ACTIVE (other bank) < tRRD");
              open[ba]     = 1'b1;
              t_act[ba]    = cyc;
              t_pre_ok[ba] = cyc + T_RAS;
              t_ready[ba]  = cyc + T_RC;
              t_any_act    = cyc;
              any_act_seen = 1'b1;
           end
           CMD_READ, CMD_WRITE: begin
              if (cmd == CMD_READ) n_rd = n_rd + 1; else n_wr = n_wr + 1;
              if (!open[ba] || ap_pend[ba]) err ("RW_CLOSED_BANK", "READ/WRITE to a bank with no open row");
              else if (cyc < t_act[ba] + T_RCD) begin
                 $sformat (m, "bank %0d READ/WRITE %0d clocks after ACTIVE, need %0d", ba, cyc - t_act[ba], T_RCD);
                 err ("tRCD", m);
              end
              if (rw_seen && cyc < t_rw_last + 1) err ("tCCD", "READ/WRITE to READ/WRITE < tCCD");
              if (cyc < t_burst_end) err ("AP_BURST_INTERRUPT", "READ/WRITE interrupts an auto-precharge burst");
              t_rw_last = cyc;
              rw_seen   = 1'b1;
              if (cmd == CMD_WRITE) begin
                 // last data-in at cyc+BL-1; PRE no earlier than tWR after it
                 if (t_pre_ok[ba] < cyc + BL - 1 + T_WR) t_pre_ok[ba] = cyc + BL - 1 + T_WR;
              end else begin
                 if (t_pre_ok[ba] < cyc + BL) t_pre_ok[ba] = cyc + BL;
              end
              if (a[10]) begin
                 // auto-precharge starts once the burst (and tWR / tRAS) is done
                 ap_pend[ba]   = 1'b1;
                 t_ap_done[ba] = t_pre_ok[ba];
                 if (t_ready[ba] < t_pre_ok[ba] + T_RP) t_ready[ba] = t_pre_ok[ba] + T_RP;
                 t_burst_end   = cyc + BL;
              end
           end
           CMD_PRE: begin
              n_pre = n_pre + 1;
              for (i = 0; i < 4; i = i + 1)
                 if (a[10] || ba == i) begin
                    if (ap_pend[i]) err ("PRE_DURING_AP", "PRECHARGE to a bank with auto-precharge pending");
                    if (open[i] && cyc < t_pre_ok[i]) begin
                       $sformat (m, "bank %0d PRECHARGE %0d clocks early (tRAS/tWR)", i, t_pre_ok[i] - cyc);
                       err ("tRAS_tWR", m);
                    end
                    if (open[i] && t_ready[i] < cyc + T_RP) t_ready[i] = cyc + T_RP;
                    else if (!open[i] && t_ready[i] < cyc + T_RP) t_ready[i] = cyc + T_RP;
                    open[i] = 1'b0;
                 end
              if (a[10] && !init_pall) init_pall = 1'b1;
           end
           CMD_REF: begin
              n_ref = n_ref + 1;
              if (!all_idle (1'b0)) err ("REF_NOT_IDLE", "AUTO REFRESH with a bank open or within tRP");
              if (n_ref > 1) begin
                 if (cyc - t_last_ref > max_ref_gap) begin max_ref_gap = cyc - t_last_ref; max_ref_gap_at = cyc; end
                 if (cyc - t_last_ref > T_REFMX) begin
                    $sformat (m, "%0d clocks since previous REF, limit %0d (9 x tREFI)", cyc - t_last_ref, T_REFMX);
                    err ("tREFI", m);
                 end
              end
              t_last_ref = cyc;
              t_ref_ok   = cyc + T_RC;
              for (i = 0; i < 4; i = i + 1)
                 if (t_ready[i] < cyc + T_RC) t_ready[i] = cyc + T_RC;
              if (!init_done && init_pall) init_refs = init_refs + 1;
           end
           CMD_MRS: begin
              if (!all_idle (1'b0)) err ("MRS_NOT_IDLE", "MODE REGISTER SET with a bank not idle");
              if (!init_pall) err ("INIT_ORDER", "MODE REGISTER SET before PRECHARGE ALL");
              init_mrs = 1'b1;
              t_mrs_ok = cyc + T_RSC;
           end
           default: ;
         endcase
         if (!init_done && init_pall && init_mrs && init_refs >= 8) init_done = 1'b1;
      end

      // tRAS max and refresh starvation while idle
      for (i = 0; i < 4; i = i + 1)
         if (open[i] && !ap_pend[i] && cyc == t_act[i] + T_RASMX + 1)
            err ("tRAS_MAX", "row held open longer than 100 us");
      if (n_ref > 0 && cyc == t_last_ref + T_REFMX + 1)
         err ("tREFI", "no AUTO REFRESH for 9 x tREFI");
   end

   final begin
      $display ("[sdram_chk] summary: %0d error(s); ACT %0d RD %0d WR %0d PRE %0d REF %0d; max REF gap %0d clk ending @cycle %0d (limit %0d, tREFI %0d); tCK %0d ps",
                errors, n_act, n_rd, n_wr, n_pre, n_ref, max_ref_gap, max_ref_gap_at, T_REFMX, T_REFI, TCK_PS);
      if (c_POWERUP_200US != 0) $display ("[sdram_chk]   %0d x POWERUP_200US", c_POWERUP_200US);
      if (c_POWERUP_CKE_DQM != 0) $display ("[sdram_chk]   %0d x POWERUP_CKE_DQM", c_POWERUP_CKE_DQM);
      if (c_INIT_ORDER != 0) $display ("[sdram_chk]   %0d x INIT_ORDER", c_INIT_ORDER);
      if (c_tRSC != 0) $display ("[sdram_chk]   %0d x tRSC", c_tRSC);
      if (c_tRFC != 0) $display ("[sdram_chk]   %0d x tRFC", c_tRFC);
      if (c_INIT_SEQUENCE != 0) $display ("[sdram_chk]   %0d x INIT_SEQUENCE", c_INIT_SEQUENCE);
      if (c_ACT_OPEN_BANK != 0) $display ("[sdram_chk]   %0d x ACT_OPEN_BANK", c_ACT_OPEN_BANK);
      if (c_tRP_tRC != 0) $display ("[sdram_chk]   %0d x tRP_tRC", c_tRP_tRC);
      if (c_tRRD != 0) $display ("[sdram_chk]   %0d x tRRD", c_tRRD);
      if (c_RW_CLOSED_BANK != 0) $display ("[sdram_chk]   %0d x RW_CLOSED_BANK", c_RW_CLOSED_BANK);
      if (c_tRCD != 0) $display ("[sdram_chk]   %0d x tRCD", c_tRCD);
      if (c_tCCD != 0) $display ("[sdram_chk]   %0d x tCCD", c_tCCD);
      if (c_AP_BURST_INTERRUPT != 0) $display ("[sdram_chk]   %0d x AP_BURST_INTERRUPT", c_AP_BURST_INTERRUPT);
      if (c_PRE_DURING_AP != 0) $display ("[sdram_chk]   %0d x PRE_DURING_AP", c_PRE_DURING_AP);
      if (c_tRAS_tWR != 0) $display ("[sdram_chk]   %0d x tRAS_tWR", c_tRAS_tWR);
      if (c_REF_NOT_IDLE != 0) $display ("[sdram_chk]   %0d x REF_NOT_IDLE", c_REF_NOT_IDLE);
      if (c_tREFI != 0) $display ("[sdram_chk]   %0d x tREFI", c_tREFI);
      if (c_MRS_NOT_IDLE != 0) $display ("[sdram_chk]   %0d x MRS_NOT_IDLE", c_MRS_NOT_IDLE);
      if (c_tRAS_MAX != 0) $display ("[sdram_chk]   %0d x tRAS_MAX", c_tRAS_MAX);
   end
endmodule
