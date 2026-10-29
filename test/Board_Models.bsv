// ================================================================
// Board_Models: the pieces of the ULX3S that the Bluesim testbenches and the virtual board
// (ULX3S_Sim) share -- clock/UART constants, the BDPI imports of test/sim_preload.c, and the
// behavioral W9825G6KH SDRAM model wired to mkULX3S_Top's SDRAM pins.
// ================================================================

package Board_Models;

import Vector    :: *;
import ConfigReg :: *;

import ULX3S_Top :: *;

// ================================================================
// Same system clock as ULX3S_Top (src/ULX3S_Top.bsv): the UART bit time must match the DUT's.
`ifdef SYS_CLK_HZ
Integer clk_hz = `SYS_CLK_HZ;
`else
Integer clk_hz = 25_000_000;
`endif
Integer baud   = 625_000;
Integer cycles_per_bit = clk_hz / baud;    // 40 at 25 MHz

// SDRAM model address mapping for c_mem_load (test/sim_preload.c): 0 = bank in byte offset
// [10:9] (this controller), 1 = the memlat controller's line-in-one-bank mapping.
Bit #(8) sdram_map = 0;

Bit #(4) m_cmd_act   = 4'b0011;
Bit #(4) m_cmd_read  = 4'b0101;
Bit #(4) m_cmd_write = 4'b0100;

typedef Bit #(24) ModelAddr;

// ---------------- BDPI blob access (test/sim_preload.c)

import "BDPI" function Bit #(32) c_blob_open ();    // open + return halfword count
import "BDPI" function Bit #(16) c_blob_half (Bit #(32) idx);
// The SDRAM model's array lives in C (calloc: reads of never-written memory are zero, as on a
// freshly-zeroed board, and the blob is placed there at time 0 instead of over 16M cycles).
import "BDPI" function ActionValue #(Bit #(32)) c_mem_load (Bit #(8) map);   // blob -> array; halfwords
import "BDPI" function Bit #(16) c_mem_rd (Bit #(32) addr);
import "BDPI" function Action    c_mem_wr (Bit #(32) addr, Bit #(16) data);
// Console mode (test/sim_preload.c): with SIM_PASS_STR set, the image is judged on its console
// (e.g. OpenSBI + Linux to "tick 2"): no prompt/command phases, the sim ends when the string
// appears.  SIM_MAX_CYCLES overrides the global cap.
import "BDPI" function ActionValue #(Bit #(8))  c_sim_mode ();
import "BDPI" function ActionValue #(Bit #(64)) c_sim_max_cycles (Bit #(64) dflt);
import "BDPI" function ActionValue #(Bit #(8))  c_console (Bit #(8) c);
// Interactive board mode (SIM_PTY=1, `make sim-board`): UART <-> host pty (test/sim_preload.c).
import "BDPI" function ActionValue #(Bit #(16)) c_pty_getc ();
import "BDPI" function Action c_pty_putc (Bit #(8) c);
// Board controls pty (sim-board): LED changes out, BTN1 level in.
import "BDPI" function ActionValue #(Bit #(8)) c_ctl_btn (Bit #(8) cur);
import "BDPI" function Action c_ctl_leds (Bit #(8) leds, Bit #(64) cycle);

// ================================================================
// Behavioral W9825G6KH: CAS latency 2 as the controller expects, 8-beat bursts, DQM byte
// masks.  The array is in C (c_mem_rd / c_mem_wr; one writer, rl_model); c_mem_load places a
// blob in it with sdram_map.  Per-access prints behind MDL_PROBES.

module mkW9825_Model #(ULX3S_Top_IFC dut) (Empty);

   // model_mem: the C array behind c_mem_rd / c_mem_wr (one writer: rl_model)
   function Bit #(16) mem_rd (ModelAddr a) = c_mem_rd (zeroExtend (a));

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
   Reg #(Bit #(16)) m_dq       <- mkConfigReg (0);   // ConfigReg: rl_model_dq reads it after rl_model writes it

   function ModelAddr m_addr ();
      return { m_bank, m_open_row [m_bank], m_col } + extend (m_beat);
   endfunction

   rule rl_model;
      let cur_cmd = { dut.sdram_cs_n, dut.sdram_ras_n, dut.sdram_cas_n, dut.sdram_we_n };
      let cur_a   = dut.sdram_a;
      let cur_ba  = dut.sdram_ba;
      let cur_dq  = dut.sdram_dq_out;
      let cur_dqm = dut.sdram_dqm;

      Bit #(2)  n_cas_cnt = m_cas_cnt;
      Bool      n_reading = m_reading;
      Bool      n_writing = m_writing;
      Bit #(4)  n_beat    = m_beat;
      Bit #(16) n_dq      = m_dq;
      Bool      n_drive   = False;

      if (m_cas_cnt != 0)
         n_cas_cnt = m_cas_cnt - 1;
      else if (m_reading) begin
         n_dq      = mem_rd (m_addr ());
         n_drive   = True;
`ifdef MDL_PROBES
         // granule 0 only (addr < 16): model addrs 0-15 exist only for
         // row 0/bank 0, i.e. blob byte offsets 0-31 -- cheap, exact
         if (m_addr () < 16)
            $display ("%0t MDLRD beat=%0d addr=%0h dq=%0h | col=%0h row=%0h bank=%0h cas=%0d",
                      $time, m_beat, m_addr (), n_dq,
                      m_col, m_open_row [m_bank], m_bank, m_cas_cnt);
`endif
         if (m_beat == 7)
            n_reading = False;
         else
            n_beat = m_beat + 1;
      end

      Bool wr_new = (cur_cmd == m_cmd_write);

      if (wr_new || m_writing) begin
         Bit #(2)  w_bank = wr_new ? cur_ba : m_wr_bank;
         Bit #(9)  w_col  = wr_new ? cur_a [8:0] : m_wr_col;
         Bit #(4)  w_beat = wr_new ? 0 : m_beat;
         ModelAddr w_addr = { w_bank, m_open_row [w_bank], w_col } + extend (w_beat);
         if (cur_dqm != 2'b11) begin
            Bit #(16) d_old = mem_rd (w_addr);
            Bit #(16) d_new = cur_dq;
            Bit #(16) merged = zeroExtend ((cur_dqm [1] == 1'b1) ? d_old [15:8] : d_new [15:8]) << 8
                             | zeroExtend ((cur_dqm [0] == 1'b1) ? d_old [7:0]  : d_new [7:0]);
            c_mem_wr (zeroExtend (w_addr), merged);
`ifdef MDL_PROBES
            if (w_addr < 16)
               $display ("%0t MDLWR beat=%0d addr=%0h dq=%0h dqm=%0b",
                         $time, w_beat, w_addr, cur_dq, cur_dqm);
`endif
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

      // ACTIVATE takes effect at once: a WRITE may follow it in the next cycle (tRCD = 1 cycle)
      // and addresses its first beat in that same cycle, from cur_ba/cur_a and the open row.
      if (cur_cmd == m_cmd_act) begin
         m_open_row [cur_ba] <= cur_a [12:0];
`ifdef MDL_PROBES
         $display ("%0t MDLCMd ACT bank=%0h row=%0h", $time, cur_ba, cur_a [12:0]);
`endif
      end

      if (m_cmd_d1 == m_cmd_read) begin
         m_bank  <= m_ba_d1;
         m_col   <= m_a_d1 [8:0];
         // Real W9825G6KH: first beat driven 2 cycles after the READ cmd
         // is clocked in, i.e. during this decode cycle; the controller
         // (registered cmd, t_cas_first=3) samples it at end of cycle.
         n_dq      = mem_rd ({ m_ba_d1, m_open_row [m_ba_d1], m_a_d1 [8:0] });
         n_drive   = True;
         n_reading = True;
         n_beat    = 1;
      end

      if (n_drive)
         m_dq <= n_dq;

      m_cas_cnt <= n_cas_cnt;
      m_reading <= n_reading;
      m_writing <= n_writing;
      m_beat    <= n_beat;

      m_cmd_d1 <= cur_cmd;
      m_a_d1   <= cur_a;
      m_ba_d1  <= cur_ba;

   endrule

   // DQ into the DUT from the model's register, in its own rule: the SDRAM controller may need its
   // dq_in method scheduled apart from the command/address outputs rl_model reads (the linux-isa
   // memlat controller does: G0004 when both were in rl_model).  Same timing: m_dq is a register.
   rule rl_model_dq;
      dut.sdram_dq_in (m_dq);
   endrule

endmodule

endpackage
