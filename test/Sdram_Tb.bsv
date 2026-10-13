// ================================================================
// Sdram_Tb: Bluesim testbench for Sdram_Controller against a
// behavioral W9825G6KH model.  Checks initialization, read/write
// data alignment, auto-precharge, refresh interaction, and byte
// masking, using a 64-granule scoreboard of expected values.
// ================================================================

package Sdram_Tb;

import Vector      :: *;
import FIFOF       :: *;
import GetPut      :: *;
import ClientServer :: *;
import Memory      :: *;
import RegFile     :: *;

import Mem_Controller :: *;
import Sdram_Controller :: *;

// ================================================================

// Number of cycles to run
Integer max_cycles = 300_000;

// Scoreboard granules
typedef 64 NGranules;

// Model: one 16-bit halfword per {bank, row, col}
typedef Bit #(24) ModelAddr;    // {bank[1:0], row[12:0], col[8:0]}

// Commands (same encoding as the DUT)
Bit #(4) m_cmd_act   = 4'b0011;
Bit #(4) m_cmd_read  = 4'b0101;
Bit #(4) m_cmd_write = 4'b0100;

// Bijection: sel (6 bits) -> granule address spread across
// banks (sel[1:0]... actually bank=addr[6:5]), rows and columns
function Bit #(64) fn_sel_to_addr (Bit #(6) sel);
   return (zeroExtend (sel [5:4]) << 7)    // row 0..3
        | (zeroExtend (sel [3:2]) << 5)    // bank 0..3
        | (zeroExtend (sel [1:0]) << 3);   // col-group 0,8,16,24
endfunction

// Expand a 32-bit byte-enable into a 256-bit bit-mask.
function Bit #(256) fn_byteen_to_mask (Bit #(32) be);
   Vector #(32, Bit #(8)) v = newVector;
   for (Integer i = 0; i < 32; i = i + 1)
      v [i] = (be [i] == 1'b1) ? 8'hFF : 8'h00;
   return pack (v);
endfunction

// ================================================================

(* synthesize *)
module mkSdram_Tb (Empty);

   Sdram_Controller_IFC dut <- mkSdram_Controller (25_000_000);

   // --------------------------------------------------
   // Behavioral SDRAM model
   RegFile #(ModelAddr, Bit #(16)) model_mem <- mkRegFile (0, 16777215);

   Reg #(Bit #(4))  m_cmd_d1  <- mkReg (4'b0111);
   Reg #(Bit #(13)) m_a_d1    <- mkReg (0);
   Reg #(Bit #(2))  m_ba_d1   <- mkReg (0);

   Vector #(4, Reg #(Bit #(13))) m_open_row <- replicateM (mkReg (0));

   Reg #(Bool)      m_reading  <- mkReg (False);
   Reg #(Bool)      m_writing  <- mkReg (False);
   Reg #(Bit #(2))  m_cas_cnt  <- mkReg (0);
   Reg #(Bit #(4))  m_beat     <- mkReg (0);
   Reg #(Bit #(2))  m_bank     <- mkReg (0);
   Reg #(Bit #(9))  m_col      <- mkReg (0);
   Reg #(Bit #(2))  m_wr_bank  <- mkReg (0);
   Reg #(Bit #(9))  m_wr_col   <- mkReg (0);
   Reg #(Bit #(16)) m_dq       <- mkReg (0);
   Reg #(Bit #(64)) mc         <- mkReg (0);

   function ModelAddr m_addr ();
      return { m_bank, m_open_row [m_bank], m_col } + extend (m_beat);
   endfunction

   // One model cycle.
   //
   // Read commands are decoded from the previous cycle's pins (d1),
   // matching a real chip sampling them at the intervening edge; the
   // first data beat then appears CL=2 cycles later, exactly as on the
   // real bus.  Write commands and their first data beat share the
   // same cycle on the pins, so write capture looks at the *current*
   // pins for beat 0 and at latched state for beats 1..7.
   rule rl_model;
      mc <= mc + 1;
      let cur_cmd = { dut.sdram_cs_n, dut.sdram_ras_n, dut.sdram_cas_n, dut.sdram_we_n };
      let cur_a   = dut.sdram_a;
      let cur_ba  = dut.sdram_ba;
      let cur_dq  = dut.sdram_dq_out;
      let cur_dqm = dut.sdram_dqm;

      // Next-state values (single assignment point per register)
      Bit #(2) n_cas_cnt = m_cas_cnt;
      Bool     n_reading = m_reading;
      Bool     n_writing = m_writing;
      Bit #(4) n_beat    = m_beat;

      // Read datapath: drive m_dq during read bursts.
      if (m_cas_cnt != 0) begin
         n_cas_cnt = m_cas_cnt - 1;
         if (m_cas_cnt == 1) begin
            m_dq      <= model_mem.sub (m_addr ());
            n_reading = True;
            n_beat    = 1;
         end
      end
      else if (m_reading) begin
         m_dq <= model_mem.sub (m_addr ());
         if (m_beat == 7)
            n_reading = False;
         else
            n_beat = m_beat + 1;
      end

      // Unified write capture (single RegFile write port)
      Bool wr_new = (cur_cmd == m_cmd_write);
      if (wr_new || m_writing) begin
         Bit #(2)  w_bank = wr_new ? cur_ba : m_wr_bank;
         Bit #(9)  w_col  = wr_new ? cur_a [8:0] : m_wr_col;
         Bit #(4)  w_beat = wr_new ? 0 : m_beat;
         ModelAddr w_addr = { w_bank, m_open_row [w_bank], w_col } + extend (w_beat);
         if (cur_dqm != 2'b11) begin
            Bit #(16) d_old = model_mem.sub (w_addr);
            Bit #(16) d_new = cur_dq;
            Bit #(16) merged = zeroExtend ((cur_dqm [1] == 1'b1) ? d_old [15:8] : d_new [15:8]) << 8
                             | zeroExtend ((cur_dqm [0] == 1'b1) ? d_old [7:0]  : d_new [7:0]);
            model_mem.upd (w_addr, merged);
         end
         if (wr_new) begin
            m_wr_bank <= cur_ba;
            m_wr_col  <= cur_a [8:0];
            n_beat    = 1;
            n_writing = True;
         end
         else if (m_beat == 7)
            n_writing = False;
         else
            n_beat = m_beat + 1;
      end

      // Decode the command seen on the pins in the previous cycle
      if (m_cmd_d1 == m_cmd_act)
         m_open_row [m_ba_d1] <= m_a_d1 [12:0];

      else if (m_cmd_d1 == m_cmd_read) begin
         m_bank    <= m_ba_d1;
         m_col     <= m_a_d1 [8:0];
         // CL=2: data appears one cycle after the READ command is decoded
         // here (m_cmd_d1 is already one cycle after the SDRAM sampled it).
         n_cas_cnt = 1;
         n_beat    = 0;
      end

      m_cas_cnt <= n_cas_cnt;
      m_reading <= n_reading;
      m_writing <= n_writing;
      m_beat    <= n_beat;

      // Sample pins for next cycle's command decode
      m_cmd_d1 <= cur_cmd;
      m_a_d1   <= cur_a;
      m_ba_d1  <= cur_ba;

      // Feed read data back into the controller
      dut.sdram_dq_in (m_dq);
   endrule

   // --------------------------------------------------
   // Stimulus and scoreboard

   Vector #(NGranules, Reg #(Bit #(256))) expected <- replicateM (mkReg (pack (replicate (16'hAAAA))));
   Vector #(NGranules, Reg #(Bool))       valid    <- replicateM (mkReg (False));

   Reg #(Bit #(64))  rg_cycle     <- mkReg (0);
   Reg #(Bool)       rg_init_seen <- mkReg (False);
   Reg #(Bit #(32))  rg_n_reqs    <- mkReg (0);
   Reg #(Bit #(32))  rg_n_done    <- mkReg (0);
   Reg #(Bit #(32))  rg_errors    <- mkReg (0);
   Reg #(Bit #(32))  rg_seed      <- mkReg (32'h1234_5678);

   Reg #(Bit #(6))   rg_cur_sel   <- mkReg (0);

   FIFOF #(Bit #(1)) f_issue <- mkFIFOF;    // one outstanding request

   function Bit #(32) next_rand (Bit #(32) s);
      s = s ^ (s << 13);
      s = s ^ (s >> 17);
      s = s ^ (s << 5);
      return s;
   endfunction

   rule rl_start (! rg_init_seen && dut.init_done);
      rg_init_seen <= True;
      f_issue.enq (?);
      $display ("%0d: init done", rg_cycle);
   endrule

   rule rl_issue (rg_init_seen && f_issue.notEmpty);
      f_issue.deq;
      let r = next_rand (rg_seed);
      rg_seed <= r;

      Bit #(64)  addr;
      Bit #(256) data = { r, r + 1, r + 2, r + 3, r + 4, r + 5, r + 6, r };
      Bit #(32)  byteen = 32'hFFFF_FFFF;
      Bool       do_write;
      Bit #(6)   sel;

      if (rg_n_reqs < 6) begin
         // Deterministic: write/read extremes of the sel map
         case (rg_n_reqs [2:0])
            0: begin sel = 0;  do_write = True;  end
            1: begin sel = 0;  do_write = False; end
            2: begin sel = 63; do_write = True;  end
            3: begin sel = 63; do_write = False; end
            4: begin sel = 18; do_write = True;  end
            default: begin sel = 18; do_write = False; end
         endcase
         addr = fn_sel_to_addr (sel);
      end
      else begin
         sel = truncate (r);
         addr = fn_sel_to_addr (sel);
         do_write = (r [8] == 0) || (! valid [sel]);
         if (rg_n_reqs [1:0] == 0) byteen = 32'h0F0F_0F0F;    // partial mask test
      end

      rg_cur_sel <= sel;
      rg_n_reqs  <= rg_n_reqs + 1;

      dut.mem_server.request.put (MemoryRequest {write:   do_write,
                                                 address: addr,
                                                 data:    data,
                                                 byteen:  byteen});

      if (do_write) begin
         // Writes have no response; immediately free the issue slot.
         f_issue.enq (?);
         Bit #(256) old = expected [sel];
         Bit #(256) mask = fn_byteen_to_mask (byteen);
         expected [sel] <= (old & ~ mask) | (data & mask);
         valid [sel]    <= True;
      end
   endrule

   rule rl_check (rg_init_seen);
      let rsp <- dut.mem_server.response.get;

      if (rsp.data != expected [rg_cur_sel]) begin
         rg_errors <= rg_errors + 1;
         if (rg_errors == 0)
            $display ("%0d: FAIL: read sel %0d: got %h expected %h",
                      rg_cycle, rg_cur_sel, rsp.data, expected [rg_cur_sel]);
      end
      rg_n_done <= rg_n_done + 1;
      f_issue.enq (?);
   endrule

   // --------------------------------------------------
   // Stop conditions

   rule rl_count;
      rg_cycle <= rg_cycle + 1;
   endrule

   rule rl_finish (rg_init_seen && (rg_n_done >= 400 || rg_cycle > fromInteger (max_cycles)));
      if (rg_errors == 0 && rg_n_done >= 400)
         $display ("PASS: %0d reads all matched", rg_n_done);
      else
         $display ("FAIL: %0d errors in %0d checks", rg_errors, rg_n_done);
      $finish (0);
   endrule

endmodule

endpackage
