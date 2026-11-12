// ================================================================
// JtaggDtm: the RISC-V debug transport (debug spec 0.13 DTM, version 1) on the ECP5's own JTAG
// port, through the JTAGG primitive (src/Top.v).  The FPGA's configuration TAP stays in charge
// (IR length 8, IDCODE 0x41113043 on the 85F); its user instructions select two data registers
// here:
//   ER1 (IR 0x32)  dmi    41 bits: [40:34] address, [33:2] data, [1:0] op
//   ER2 (IR 0x38)  dtmcs  32 bits: version 1, abits 7, dmistat, idle 1; [16] dmireset,
//                         [17] dmihardreset
// OpenOCD: `riscv set_ir dmi 0x32`, `riscv set_ir dtmcs 0x38` (openocd/ulx3s_jtagg.ocd).
//
// The JTAGG outputs (JTCK, JTDI, JSHIFT, JUPDATE, JRSTN, JCE1, JCE2) are not clocks here: the
// module samples them with the system clock through synchronizing flops and acts once per rising
// edge of JTCK.  JSHIFT, JUPDATE, JRSTN and JCE are taken from the sample just before the edge
// (the TAP state the edge leaves); JTDI from a sample one system clock after JTCK is first seen
// high: on the LFE5U-85F JTDI is TDI registered on TCK's rising edge, so before the edge it still
// holds the previous bit.  Found on the board (lx45, lx45b, lx45c): every 41-bit dmi scan arrived
// one bit up (address 0x10 as 0x20), while 42-bit scans with the value in the low 41 bits worked,
// dtmcs and dmi reads were right, and changing TDI before TCK's falling edge changed nothing
// (build/jtagmodel/model.py replays the sessions against the candidate behaviours).  This needs
// TCK well below the system clock (the FT231X bit-bangs at ~0.5 MHz; 50 MHz here), and it
// removes the TCK clock domain and its synchronizing FIFOs.  JTDO1/JTDO2 are the shift register's
// bit 0; the configuration TAP drives TDO from them on the falling edge, half a TCK period after
// the update.
//
// Per edge, in the state the edge leaves:
//   JCE1 | JCE2, JSHIFT 0   Capture-DR: load dmi (or dtmcs) and remember which one
//   JSHIFT 1, one selected  Shift-DR: shift right, JTDI in at the register's top bit
//   JUPDATE                 Update-DR: act on the remembered register, then forget it (an
//                           Update-DR of the TAP's own instructions finds nothing remembered)
//   JRSTN 0                 Test-Logic-Reset: forget it
// A dmi update starts a read or write unless one is in flight (then dmistat sticks at 3, busy,
// until dmireset) or an earlier op failed (sticks at 2).  The debug module answers every request
// once and in order (Flute SoC_Top), so one request in flight is enough.
// ================================================================

package JtaggDtm;

import FIFOF            :: *;
import GetPut           :: *;
import ClientServer     :: *;
import External_Control :: *;

interface JtaggDtm_IFC;
   // {JCE2, JCE1, JRSTN, JUPDATE, JSHIFT, JTDI, JTCK}
   (* always_ready, always_enabled *) method Action pins (Bit #(7) v);
   (* always_ready *)                 method Bit #(1) tdo;
   interface Client #(Control_Req, Control_Rsp) client;
endinterface

(* synthesize *)
module mkJtaggDtm (JtaggDtm_IFC);
   Wire #(Bit #(7)) w_pins <- mkBypassWire;
   Reg #(Bit #(7))  rg_m   <- mkReg (7'b0010000);   // JRSTN high: not in reset
   Reg #(Bit #(7))  rg_s   <- mkReg (7'b0010000);
   Reg #(Bit #(7))  rg_p   <- mkReg (7'b0010000);   // rg_s one clock earlier
   Reg #(Bit #(7))  rg_q   <- mkReg (7'b0010000);   // rg_p one clock earlier

   Reg #(Bit #(41)) rg_dr     <- mkReg (0);
   Reg #(Bit #(2))  rg_sel    <- mkReg (0);          // 0 none, 1 dmi, 2 dtmcs
   Reg #(Bit #(7))  rg_addr   <- mkReg (0);
   Reg #(Bit #(32)) rg_data   <- mkReg (0);
   Reg #(Bit #(2))  rg_stat   <- mkReg (0);          // dmistat: 0 ok, 2 failed, 3 busy
   Reg #(Bool)      rg_flight <- mkReg (False);

   FIFOF #(Control_Req) f_req <- mkFIFOF;
   FIFOF #(Control_Rsp) f_rsp <- mkFIFOF;

   Bit #(41) dtmcs_v = zeroExtend ({14'b0, 1'b0, 1'b0, 1'b0, 3'd1, rg_stat, 6'd7, 4'd1});

   (* fire_when_enabled, no_implicit_conditions *)
   rule rl_sample;
      rg_m <= w_pins;
      rg_s <= rg_m;
      rg_p <= rg_s;
      rg_q <= rg_p;
   endrule

   // a rising edge of JTCK: rg_p is the first sample with it high, rg_q the one before
   Bool edge_now = rg_p [0] == 1 && rg_q [0] == 0;

   // the debug module's answer (rl_edge never writes rg_flight/rg_data in the same clock it
   // starts a request, and no request starts while one is in flight)
   rule rl_rsp (! edge_now);
      let r = f_rsp.first;  f_rsp.deq;
      rg_data   <= truncate (r.result);
      if (r.status != external_control_rsp_status_ok && rg_stat == 0) rg_stat <= 2;
      rg_flight <= False;
   endrule

   (* fire_when_enabled *)
   rule rl_edge (edge_now);
      Bit #(1) tdi    = rg_s [1];      // one clock after the edge: JTDI has taken the new bit
      Bit #(1) shift  = rg_q [2];
      Bit #(1) update = rg_q [3];
      Bit #(1) rstn   = rg_q [4];
      Bit #(1) ce1    = rg_q [5];
      Bit #(1) ce2    = rg_q [6];
      if (rstn == 0)
         rg_sel <= 0;
      else if ((ce1 | ce2) == 1 && shift == 0) begin
         rg_sel <= (ce1 == 1) ? 1 : 2;
         if (ce1 == 1)
            rg_dr <= {rg_addr, rg_data, (rg_flight ? 2'd3 : rg_stat)};
         else
            rg_dr <= dtmcs_v;
      end
      else if (shift == 1 && rg_sel != 0) begin
         if (rg_sel == 1) rg_dr <= {tdi, rg_dr [40:1]};
         else             rg_dr <= {9'b0, tdi, rg_dr [31:1]};
      end
      else if (update == 1 && rg_sel != 0) begin
         Bit #(41) dr = rg_dr;
         rg_sel <= 0;
         if (rg_sel == 2) begin
            if (dr [16] == 1 || dr [17] == 1) rg_stat <= 0;   // dmireset, dmihardreset
         end
         else if (rg_flight) begin
            if (rg_stat == 0) rg_stat <= 3;
         end
         else if (rg_stat == 0 && (dr [1:0] == 1 || dr [1:0] == 2)) begin
            Bit #(7)  a = dr [40:34];
            Bit #(32) d = dr [33:2];
            rg_addr   <= a;
            rg_flight <= True;
            f_req.enq (Control_Req {
               op:   (dr [1:0] == 1) ? external_control_req_op_read_control_fabric
                                        : external_control_req_op_write_control_fabric,
               arg1: zeroExtend (a),
               arg2: zeroExtend (d)});
         end
      end
   endrule

   method Action pins (Bit #(7) v);
      w_pins <= v;
   endmethod
   method Bit #(1) tdo = rg_dr [0];
   interface Client client;
      interface Get request  = toGet (f_req);
      interface Put response = toPut (f_rsp);
   endinterface
endmodule

endpackage
