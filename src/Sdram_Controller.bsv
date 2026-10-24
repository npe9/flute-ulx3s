// ================================================================
// Sdram_Controller: the ULX3S's 32 MB Winbond W9825G6KH-6 16-bit SDR
// SDRAM, running from the 25 MHz board clock.
//
// Core: a streaming request port.  A request names one 64-byte line and a
// contiguous range of its four BL8 bursts (16 bytes each).  The line sits in
// one bank and row:  line l (= byte >> 6):  bank = l[1:0],  row = l[18:6],
// col = {l[5:2], burst, beat}.  One ACTIVE, gapless bursts, auto-precharge
// on the last, so all banks are closed between requests and refresh can be
// inserted at request boundaries.  Reads return two 64-bit chunks per burst
// in address order; a read is only started when the response FIFO has room
// for all of its chunks (SDRAM data cannot be stalled).  Writes carry one
// 32-byte half of the line and skip bursts with no enabled byte.
//
// The request and chunk types are Mem_Controller's raw memory port.
//
// Timing constants are in system clock cycles (25 MHz = 40 ns; the PLL
// build runs at 32.14 MHz = 31.1 ns): tRCD 1 (>=18 ns), CL 2, tRFC and the
// init gaps derived from clk_hz (>=66 ns, at least 2), refresh every 98
// cycles (<= 7.8 us at any clock >= 12.5 MHz), power-up wait 200 us.
// ================================================================

package Sdram_Controller;

export Sdram_Controller_IFC (..), mkSdram_Controller;

import Vector      :: *;
import FIFOF       :: *;
import GetPut      :: *;
import ClientServer :: *;

import Mem_Controller :: *;    // Raw_Mem_Req, Raw_Mem_Chunk

// ================================================================

// JEDEC command encoding {cs_n, ras_n, cas_n, we_n}
Bit #(4) cmd_nop     = 4'b0111;
Bit #(4) cmd_act     = 4'b0011;
Bit #(4) cmd_read    = 4'b0101;
Bit #(4) cmd_write   = 4'b0100;
Bit #(4) cmd_pre     = 4'b0010;
Bit #(4) cmd_ref     = 4'b0001;
Bit #(4) cmd_mrs     = 4'b0000;

// Mode register: CL2, BL8, sequential burst, write bursts enabled
Bit #(13) mode_reg_value = 13'h0023;

Integer t_rcd         = 1;     // ACT -> READ/WRITE
Integer t_cas_first   = 3;     // IOB reg + BSV input reg pipeline (sim-validated)
Integer refresh_div   = 98;     // 7.8 us at 12.5 MHz (80 ns/cycle)

// ================================================================

typedef enum {ST_PWR_WAIT,
              ST_PRE_ALL, ST_PRE_ALL_WAIT,
              ST_INIT_REF1, ST_INIT_REF1_WAIT,
              ST_INIT_REF2, ST_INIT_REF2_WAIT,
              ST_MRS, ST_MRS_WAIT,
              ST_IDLE,
              ST_ACT, ST_RCD_WAIT,
              ST_RD, ST_RD_CAP,
              ST_WR, ST_WR_DATA, ST_WR_END,
              ST_REF, ST_REF_WAIT } State
deriving (Bits, Eq, FShow);

// ================================================================

interface Sdram_Controller_IFC;
   interface Server #(Raw_Mem_Req, Raw_Mem_Chunk)  mem_server;

   (* always_ready *) method Bool     init_done;

   (* always_ready *) method Bit #(1)  sdram_cke;
   (* always_ready *) method Bit #(1)  sdram_cs_n;
   (* always_ready *) method Bit #(1)  sdram_ras_n;
   (* always_ready *) method Bit #(1)  sdram_cas_n;
   (* always_ready *) method Bit #(1)  sdram_we_n;
   (* always_ready *) method Bit #(2)  sdram_ba;
   (* always_ready *) method Bit #(13) sdram_a;
   (* always_ready *) method Bit #(2)  sdram_dqm;
   (* always_ready *) method Bit #(16) sdram_dq_out;
   (* always_ready *) method Bit #(1)  sdram_dq_oe;
   (* always_enabled *) method Action sdram_dq_in (Bit #(16) v);
endinterface

// ================================================================

typedef Raw_Mem_Line Sdram_Line;
typedef Bit #(2)     BurstIdx;       // burst within a line

function Bit #(2)  fn_bank (Sdram_Line l); return l [1:0];   endfunction
function Bit #(13) fn_row  (Sdram_Line l); return l [18:6];  endfunction
function Bit #(9)  fn_col  (Sdram_Line l, BurstIdx b); return { l [5:2], b, 3'b0 }; endfunction

// Write: bursts of the line with at least one enabled byte (16 bytes each)
function Bit #(4) fn_burst_mask (BurstIdx b_first, Bit #(32) be);
   Bit #(2) m = { pack (be [31:16] != 0), pack (be [15:0] != 0) };
   return (b_first [1] == 1) ? { m, 2'b0 } : { 2'b0, m };
endfunction
function BurstIdx fn_first_set (Bit #(4) m);
   BurstIdx r = 0;
   for (Integer b = 3; b >= 0; b = b - 1)
      if (m [b] == 1) r = fromInteger (b);
   return r;
endfunction
function BurstIdx fn_last_set (Bit #(4) m);
   BurstIdx r = 0;
   for (Integer b = 0; b < 4; b = b + 1)
      if (m [b] == 1) r = fromInteger (b);
   return r;
endfunction
// Next set burst strictly above b (b itself if none: caller checks last).
function BurstIdx fn_next_set (Bit #(4) m, BurstIdx b);
   BurstIdx r = b;
   for (Integer k = 3; k >= 0; k = k - 1)
      if (m [k] == 1 && fromInteger (k) > b) r = fromInteger (k);
   return r;
endfunction


// ================================================================

module mkSdram_Controller #(Integer clk_hz) (Sdram_Controller_IFC);

   Integer t_powerup = clk_hz / 5000;    // 200 us
   // tRFC >= 66 ns (and the init gaps tRP/tRFC/tMRD, which it covers), in
   // clocks, at least 2: 2 at 25 MHz (80 ns), 3 at the 32.14 MHz PLL clock
   // (2 would be 62 ns).  Refresh interval refresh_div (98 clocks) stays
   // well under tREFI 7.8 us at any clock >= 12.5 MHz.
   Integer ns_x_hz   = 66 * clk_hz;
   Integer t_rfc_c   = (ns_x_hz + 999_999_999) / 1_000_000_000;
   Integer t_rfc     = max (2, t_rfc_c);
   Integer t_init_gap = t_rfc;

   Reg #(State)     rg_state     <- mkReg (ST_PWR_WAIT);
   Reg #(Bit #(16)) rg_wait      <- mkReg (0);
   Reg #(Bit #(16)) rg_pwrcnt    <- mkReg (fromInteger (t_powerup));
   Reg #(Bit #(16)) rg_ref_cnt   <- mkReg (fromInteger (refresh_div));
   Reg #(Bit #(2))  rg_init_pairs <- mkReg (0);   // init REF1/REF2 pairs done

   // Latched current request
   Reg #(Raw_Mem_Req) rg_req        <- mkRegU;
   Reg #(BurstIdx)  rg_burst      <- mkReg (0);        // current burst
   Reg #(BurstIdx)  rg_burst_last <- mkReg (0);        // last burst of this request
   Reg #(Bit #(4))  rg_bmask      <- mkReg (0);        // write: bursts with enabled bytes
   Reg #(Bit #(3))  rg_beat       <- mkReg (0);

   // Read: halfwords 0..2 of the current 64-bit chunk (the 4th is rg_dq_in)
   Vector #(3, Reg #(Bit #(16))) rg_hw <- replicateM (mkReg (16'h0));

   // Pin registers
   Reg #(Bit #(4))  rg_cmd      <- mkReg (cmd_nop);    // command output (updated by state rules)
   Reg #(Bit #(13)) rg_a        <- mkReg (0);
   Reg #(Bit #(2))  rg_ba       <- mkReg (0);
   Reg #(Bit #(2))  rg_dqm      <- mkReg (2'b11);
   Reg #(Bit #(16)) rg_dq_out   <- mkReg (0);
   Reg #(Bit #(1))  rg_dq_oe    <- mkReg (0);
   Reg #(Bit #(16)) rg_dq_in    <- mkReg (0);

   Reg #(Bool) rg_inited     <- mkReg (False);
   Reg #(Bool) rg_cmd_valid  <- mkReg (False);
   Reg #(Bool) rg_clear_cmd  <- mkReg (False);

   FIFOF #(Raw_Mem_Req)  f_reqs <- mkSizedFIFOF (4);
   // Read chunks.  Credits: rg_chunks_issued - rg_chunks_taken chunks are
   // promised to f_rsps (each counter has one writer); a read starts only
   // if all of its chunks fit.
   FIFOF #(Bit #(64))  f_rsps <- mkSizedFIFOF (8);
   Reg #(Bit #(4))     rg_chunks_issued <- mkReg (0);
   Reg #(Bit #(4))     rg_chunks_taken  <- mkReg (0);


   // Issue rules assert rg_cmd_valid for exactly one cycle; this rule
   // clears it the following cycle.  Kept separate from data-burst rules
   // so the behavioral model can sample command pins without a cycle.
   rule rl_clear_cmd_valid (rg_clear_cmd);
      rg_cmd_valid  <= False;
      rg_clear_cmd  <= False;
   endrule

   // ----------------------------------------------------------------
   // Power-up initialization: 200 us stable clock with CKE and DQM high,
   // PRECHARGE ALL, 8x AUTO REFRESH, LOAD MODE REGISTER (CL2, BL8).

   rule rl_pwr_wait (rg_state == ST_PWR_WAIT);
      if (rg_pwrcnt == 1)
         rg_state <= ST_PRE_ALL;
      else
         rg_pwrcnt <= rg_pwrcnt - 1;
   endrule

   rule rl_pre_all (rg_state == ST_PRE_ALL);
      rg_cmd      <= cmd_pre;
      rg_cmd_valid <= True;
      rg_clear_cmd <= True;
      rg_a        <= 13'h0400;    // A10 = 1: precharge all banks
      rg_ba       <= 0;
      rg_wait     <= fromInteger (t_init_gap);
      rg_state    <= ST_PRE_ALL_WAIT;
   endrule

   rule rl_pre_all_wait (rg_state == ST_PRE_ALL_WAIT);
      if (rg_wait == 0)
         rg_state <= ST_INIT_REF1;
      else
         rg_wait <= rg_wait - 1;
   endrule

   rule rl_init_ref1 (rg_state == ST_INIT_REF1);
      rg_cmd      <= cmd_ref;
      rg_cmd_valid <= True;
      rg_clear_cmd <= True;
      rg_wait     <= fromInteger (t_init_gap);
      rg_state    <= ST_INIT_REF1_WAIT;
   endrule

   rule rl_init_ref1_wait (rg_state == ST_INIT_REF1_WAIT);
      if (rg_wait == 0)
         rg_state <= ST_INIT_REF2;
      else
         rg_wait <= rg_wait - 1;
   endrule

   rule rl_init_ref2 (rg_state == ST_INIT_REF2);
      rg_cmd      <= cmd_ref;
      rg_cmd_valid <= True;
      rg_clear_cmd <= True;
      rg_wait     <= fromInteger (t_init_gap);
      rg_state    <= ST_INIT_REF2_WAIT;
   endrule

   // The W9825G6KH datasheet (7.1) requires 8 AUTO REFRESH cycles at
   // init; the REF1/REF2 pair runs 4 times.
   rule rl_init_ref2_wait (rg_state == ST_INIT_REF2_WAIT);
      if (rg_wait == 0) begin
         if (rg_init_pairs == 3)
            rg_state <= ST_MRS;
         else begin
            rg_init_pairs <= rg_init_pairs + 1;
            rg_state      <= ST_INIT_REF1;
         end
      end
      else
         rg_wait <= rg_wait - 1;
   endrule

   rule rl_mrs (rg_state == ST_MRS);
      rg_cmd      <= cmd_mrs;
      rg_cmd_valid <= True;
      rg_clear_cmd <= True;
      rg_a        <= mode_reg_value;
      rg_ba       <= 0;
      rg_wait     <= fromInteger (t_init_gap);
      rg_state    <= ST_MRS_WAIT;
   endrule

   rule rl_mrs_wait (rg_state == ST_MRS_WAIT);
      if (rg_wait == 0) begin
         rg_state  <= ST_IDLE;
         rg_inited <= True;
      end
      else
         rg_wait <= rg_wait - 1;
   endrule

   // ----------------------------------------------------------------
   // Refresh countdown.  When it expires it HOLDS at 1 (a pending
   // refresh) until the IDLE rule has issued the refresh, which reloads
   // it.  It used to reload itself the cycle after expiring, so a refresh
   // that fell due while a request was in flight was dropped: up to 17 in
   // a row (1666 clocks, 66 us) in the hello boot -- found by
   // sim/linux_bram/sdram_timing_check.v.  Now REF-to-REF is refresh_div
   // plus at most one request (~45 clocks), well under tREFI (7.8 us).

   rule rl_refresh_tick (rg_ref_cnt > 1);
      rg_ref_cnt <= rg_ref_cnt - 1;
   endrule

   rule rl_ref (rg_state == ST_REF && rg_ref_cnt <= 1);
      rg_ref_cnt  <= fromInteger (refresh_div);
      rg_cmd      <= cmd_ref;
      rg_cmd_valid <= True;
      rg_clear_cmd <= True;
      rg_wait     <= fromInteger (t_rfc);
      rg_state    <= ST_REF_WAIT;
   endrule

   rule rl_ref_wait (rg_state == ST_REF_WAIT);
      if (rg_wait == 0)
         rg_state <= ST_IDLE;
      else
         rg_wait <= rg_wait - 1;
   endrule

   // ----------------------------------------------------------------
   // IDLE: serve refresh first, then latch the next request.

   Bit #(4) chunks_in_flight = rg_chunks_issued - rg_chunks_taken;

   rule rl_idle (rg_state == ST_IDLE);
      rg_dq_oe     <= 1'b0;
      rg_dqm       <= 2'b11;
      if (rg_ref_cnt <= 1)
         rg_state <= ST_REF;
      else if (f_reqs.notEmpty) begin
         let req = f_reqs.first;
         let bm = fn_burst_mask (req.b_first, req.wbe);
         Bit #(4) n_chunks = (zeroExtend (req.b_last - req.b_first) + 1) << 1;
         if (req.write) begin
            // Only bursts with enabled bytes (no ACTIVE at all for an empty mask)
            f_reqs.deq;
            rg_req        <= req;
            rg_bmask      <= bm;
            rg_burst      <= fn_first_set (bm);
            rg_burst_last <= fn_last_set (bm);
            if (bm != 0)
               rg_state <= ST_ACT;
         end
         else if (chunks_in_flight + n_chunks <= 8) begin
            f_reqs.deq;
            rg_req           <= req;
            rg_burst         <= req.b_first;
            rg_burst_last    <= req.b_last;
            rg_chunks_issued <= rg_chunks_issued + n_chunks;
            rg_state         <= ST_ACT;
         end
`ifdef SDCAP_PROBES
         if (req.line == 0)
            $display ("%0d SDREQ %s line=%0h bursts %0d..%0d wbe=%0h",
                      0, req.write ? "WR" : "RD", req.line, req.b_first, req.b_last, req.wbe);
`endif
      end
   endrule

   // ----------------------------------------------------------------
   // Shared row activation

   rule rl_act (rg_state == ST_ACT);
      rg_cmd      <= cmd_act;
      rg_cmd_valid <= True;
      rg_clear_cmd <= True;
      rg_a        <= fn_row (rg_req.line);
      rg_ba       <= fn_bank (rg_req.line);
      rg_wait     <= fromInteger (t_rcd);
      rg_state    <= ST_RCD_WAIT;
   endrule

   rule rl_rcd_wait (rg_state == ST_RCD_WAIT);
      if (rg_wait == 0)
         rg_state <= (rg_req.write ? ST_WR : ST_RD);
      else
         rg_wait <= rg_wait - 1;
   endrule

   // ----------------------------------------------------------------
   // Read: bursts rg_burst .. rg_burst_last, gapless, 64-bit chunks out

   function Action fa_read_cmd (BurstIdx b);
      action
         rg_cmd       <= cmd_read;
         rg_cmd_valid <= True;
         rg_clear_cmd <= True;
         // Auto-precharge only on the last burst, so the row stays open
         // across the bursts of one request.
         rg_a         <= { 4'b0, fn_col (rg_req.line, b) } | ((b == rg_burst_last) ? 13'h0400 : 13'h0);
         rg_ba        <= fn_bank (rg_req.line);
      endaction
   endfunction

   rule rl_rd (rg_state == ST_RD);
      fa_read_cmd (rg_burst);
      rg_dqm      <= 2'b00;    // unmask read data for the entire request
      rg_beat     <= 0;
      rg_wait     <= fromInteger (t_cas_first);
      rg_state    <= ST_RD_CAP;
   endrule

   rule rl_rd_cap (rg_state == ST_RD_CAP);
      if (rg_wait != 0)
         rg_wait <= rg_wait - 1;
      else begin
         // Beats 3 and 7 complete a chunk.  f_rsps has room: the request's
         // chunks were reserved before it started.
         if (rg_beat [1:0] == 3) begin
            Bit #(64) chunk = { rg_dq_in, rg_hw [2], rg_hw [1], rg_hw [0] };
            f_rsps.enq (chunk);
`ifdef SDCAP_PROBES
            if (rg_req.line == 0)
               $display ("%0d SDCAP burst=%0d beat=%0d chunk=%0h", 0, rg_burst, rg_beat, chunk);
`endif
         end
         else
            rg_hw [rg_beat [1:0]] <= rg_dq_in;

         // Gapless bursts: the next READ goes out with beat 4 (8 cycles after
         // this burst's READ), so its first beat follows this burst's beat 7.
         if ((rg_beat == 4) && (rg_burst != rg_burst_last))
            fa_read_cmd (rg_burst + 1);

         if (rg_beat == 7) begin
            if (rg_burst == rg_burst_last)
               rg_state <= ST_IDLE;
            else
               rg_burst <= rg_burst + 1;    // its beat 0 follows
         end
         rg_beat <= rg_beat + 1;
      end
   endrule

   // ----------------------------------------------------------------
   // Write: BL8 bursts of the latched half, zero write latency (first beat
   // driven with the WRITE command), per-byte DQM masking.

   function Action fa_drive_wbeat (BurstIdx b, Bit #(3) beat);
      action
         Vector #(16, Bit #(16)) v_wdata = unpack (rg_req.wdata);
         Bit #(4) idx    = { b [0], beat };
         Bit #(5) be_idx = { idx, 1'b0 };
         rg_dq_out <= v_wdata [idx];
         rg_dqm    <= { ~ rg_req.wbe [be_idx + 1], ~ rg_req.wbe [be_idx] };
      endaction
   endfunction

   rule rl_wr (rg_state == ST_WR);
      rg_cmd      <= cmd_write;
      rg_cmd_valid <= True;
      rg_clear_cmd <= True;
      // Auto-precharge only on the last written burst.
      rg_a        <= { 4'b0, fn_col (rg_req.line, rg_burst) } | ((rg_burst == rg_burst_last) ? 13'h0400 : 13'h0);
      rg_ba       <= fn_bank (rg_req.line);
      rg_dq_oe    <= 1'b1;
      fa_drive_wbeat (rg_burst, 0);
      rg_beat     <= 1;
      rg_state    <= ST_WR_DATA;
   endrule

   rule rl_wr_data (rg_state == ST_WR_DATA);
      fa_drive_wbeat (rg_burst, rg_beat);
      // The next burst's WRITE (with its beat 0) follows beat 7 directly (tCCD 1)
      if (rg_beat == 7) begin
         if (rg_burst != rg_burst_last) begin
            rg_burst <= fn_next_set (rg_bmask, rg_burst);
            rg_state <= ST_WR;
         end
         else
            rg_state <= ST_WR_END;
      end
      else
         rg_beat <= rg_beat + 1;
   endrule

   rule rl_wr_end (rg_state == ST_WR_END);
      rg_dq_oe    <= 1'b0;
      rg_dqm      <= 2'b11;
      rg_state <= ST_IDLE;
   endrule

   // ----------------------------------------------------------------
   // INTERFACE

   // The command is driven only during the single-cycle issue states.
   // During waits, data bursts, gaps and idle the bus is held at NOP.
   function Bit #(4) fn_cmd_out ();
      return rg_cmd_valid ? rg_cmd : cmd_nop;
   endfunction

   interface Server mem_server;
      interface Put request = toPut (f_reqs);
      interface Get response;
         method ActionValue #(Raw_Mem_Chunk) get;
            f_rsps.deq;
            rg_chunks_taken <= rg_chunks_taken + 1;
            return f_rsps.first;
         endmethod
      endinterface
   endinterface

   method Bool init_done = rg_inited;

   // CKE is held high from reset, through the 200 us pause, onward: the
   // W9825G6KH datasheet (7.1) asks for CKE and DQM high during the pause,
   // and the controller never uses power-down or self refresh.
   method Bit #(1) sdram_cke   = 1'b1;
   method Bit #(1) sdram_cs_n  = fn_cmd_out () [3];
   method Bit #(1) sdram_ras_n = fn_cmd_out () [2];
   method Bit #(1) sdram_cas_n = fn_cmd_out () [1];
   method Bit #(1) sdram_we_n  = fn_cmd_out () [0];
   method Bit #(2) sdram_ba    = rg_ba;
   method Bit #(13) sdram_a    = rg_a;
   method Bit #(2) sdram_dqm   = rg_dqm;
   method Bit #(16) sdram_dq_out = rg_dq_out;
   method Bit #(1) sdram_dq_oe = rg_dq_oe;
   method Action sdram_dq_in (Bit #(16) v);
      rg_dq_in <= v;
   endmethod
endmodule

endpackage
