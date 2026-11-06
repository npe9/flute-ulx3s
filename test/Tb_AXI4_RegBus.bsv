// Bluesim unit test for src/AXI4_RegBus.bsv: an AXI4 master drives the bridge; a device model
// (16 words of registers, programmable ack latency, a dead window that never acks) checks the
// register-bus protocol every cycle (request stable until the ack, one ack per request, valid
// low the cycle after the ack).  Covers both 32-bit lanes of the 64-bit fabric, byte strobes,
// strobe-less writes (no bus access), and the watchdog's SLVERR.  Prints PASS / FAIL.
package Tb_AXI4_RegBus;

import StmtFSM      :: *;
import Connectable  :: *;
import Vector       :: *;
import Semi_FIFOF   :: *;
import AXI4_Types   :: *;
import AXI4_Xactors :: *;
import Fabric_Defs  :: *;
import AXI4_RegBus  :: *;

Bit #(64) base = 'hC001_0000;
Bit #(64) dead = 'hC002_0000;    // the model never acks here

(* synthesize *)
module mkTb_AXI4_RegBus (Empty);
   AXI4_RegBus_IFC rb <- mkAXI4_RegBus;
   AXI4_Master_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) mx <- mkAXI4_Master_Xactor;
   mkConnection (mx.axi_side, rb.slave);

   // device model
   Vector #(16, Reg #(Bit #(32))) regs <- replicateM (mkReg (0));
   Reg #(Bool)      d_busy  <- mkReg (False);
   Reg #(Bool)      d_acked <- mkReg (False);
   Reg #(Bit #(4))  d_cnt   <- mkReg (0);
   Reg #(Bit #(4))  rg_lat  <- mkReg (0);
   Reg #(Bit #(1))  s_we    <- mkReg (0);
   Reg #(Bit #(32)) s_addr  <- mkReg (0);
   Reg #(Bit #(32)) s_wdata <- mkReg (0);
   Reg #(Bit #(4))  s_wstrb <- mkReg (0);
   Reg #(UInt #(32)) rg_acc <- mkReg (0);    // device accesses (written by rl_dev only)
   Reg #(UInt #(32)) rg_derr <- mkReg (0);   // protocol errors seen by the model (rl_dev only)
   Reg #(UInt #(32)) rg_acc0 <- mkReg (0);

   Reg #(Bit #(32))  rg_r    <- mkReg (0);
   Reg #(Bit #(2))   rg_resp <- mkReg (0);
   Reg #(UInt #(32)) rg_err  <- mkReg (0);
   Reg #(UInt #(32)) rg_t    <- mkReg (0);
   Reg #(Bit #(4))   rg_i    <- mkReg (0);

   function Action fail (String what) = action
      $display ("FAIL %s (cycle %0d)", what, rg_t);
      rg_derr <= rg_derr + 1;
   endaction;

   (* fire_when_enabled, no_implicit_conditions *)
   rule rl_dev;
      Bit #(1)  ack = 0;
      Bit #(32) rdata = 0;
      Bool      v = (rb.rb_valid == 1);
      if (d_acked) begin
         if (v) fail ("valid high the cycle after the ack");
         d_acked <= False;
      end
      else if (v && (rb.rb_addr [31:16] != dead [31:16])) begin
         if (! d_busy) begin
            d_busy <= True; d_cnt <= rg_lat;
            s_we <= rb.rb_we; s_addr <= rb.rb_addr; s_wdata <= rb.rb_wdata; s_wstrb <= rb.rb_wstrb;
         end
         else begin
            if (rb.rb_we != s_we || rb.rb_addr != s_addr || (s_we == 1 && (rb.rb_wdata != s_wdata || rb.rb_wstrb != s_wstrb)))
               fail ("request changed before the ack");
            if (d_cnt == 0) begin
               Bit #(4) i = s_addr [5:2];
               if (s_we == 1) begin
                  Bit #(32) m = 0;
                  for (Integer b = 0; b < 4; b = b + 1) if (s_wstrb [b] == 1) m [8*b+7:8*b] = 8'hFF;
                  regs [i] <= (regs [i] & ~m) | (s_wdata & m);
               end
               else rdata = regs [i];
               ack = 1;
               d_busy <= False; d_acked <= True;
               rg_acc <= rg_acc + 1;
            end
            else d_cnt <= d_cnt - 1;
         end
      end
      else if (! v && d_busy) fail ("valid dropped without an ack");
      rb.rb_ack (ack, rdata);
   endrule

   rule rl_tick; rg_t <= rg_t + 1; endrule

   function Stmt wr (Bit #(64) a, Bit #(32) v, Bit #(4) strb) = seq
      action
         Bit #(64) d = (a [2] == 1) ? { v, 32'b0 } : zeroExtend (v);
         Bit #(8)  s = (a [2] == 1) ? { strb, 4'b0 } : zeroExtend (strb);
         mx.i_wr_addr.enq (AXI4_Wr_Addr {awid: 0, awaddr: truncate (a), awlen: 0, awsize: axsize_4,
                                         awburst: 1, awlock: 0, awcache: 0, awprot: 0, awqos: 0,
                                         awregion: 0, awuser: 0});
         mx.i_wr_data.enq (AXI4_Wr_Data {wdata: truncate (d), wstrb: truncate (s), wlast: True, wuser: 0});
      endaction
      action let r <- pop_o (mx.o_wr_resp); rg_resp <= r.bresp; endaction
   endseq;
   function Stmt rd (Bit #(64) a) = seq
      action
         mx.i_rd_addr.enq (AXI4_Rd_Addr {arid: 0, araddr: truncate (a), arlen: 0, arsize: axsize_4,
                                         arburst: 1, arlock: 0, arcache: 0, arprot: 0, arqos: 0,
                                         arregion: 0, aruser: 0});
      endaction
      action
         let r <- pop_o (mx.o_rd_data);
         Bit #(64) d = zeroExtend (r.rdata);
         rg_r <= (a [2] == 1) ? d [63:32] : d [31:0];
         rg_resp <= r.rresp;
      endaction
   endseq;
   function Action chk (String what, Bit #(32) got, Bit #(32) exp) = action
      if (got != exp) begin $display ("FAIL %s: got %h exp %h", what, got, exp); rg_err <= rg_err + 1; end
   endaction;

   mkAutoFSM (seq
      // both lanes, every latency 0..3
      for (rg_lat <= 0; rg_lat < 4; rg_lat <= rg_lat + 1) seq
         for (rg_i <= 0; rg_i < 8; rg_i <= rg_i + 1) seq
            wr (base + zeroExtend ({ rg_i, 2'b0 }), 32'h1000_0000 * zeroExtend (rg_lat) + zeroExtend (rg_i) * 32'h0101_0101, 4'hF);
            chk ("wr resp", zeroExtend (rg_resp), 0);
         endseq
         for (rg_i <= 0; rg_i < 8; rg_i <= rg_i + 1) seq
            rd (base + zeroExtend ({ rg_i, 2'b0 }));
            chk ("rd lane", rg_r, 32'h1000_0000 * zeroExtend (rg_lat) + zeroExtend (rg_i) * 32'h0101_0101);
            chk ("rd resp", zeroExtend (rg_resp), 0);
         endseq
      endseq
      action chk ("accesses", pack (rg_acc), 64); endaction
      rg_lat <= 1;
      // byte strobes in the upper lane
      wr (base + 'h24, 32'hAABBCCDD, 4'hF);
      wr (base + 'h24, 32'h11000000, 4'h8);
      wr (base + 'h24, 32'h00002200, 4'h2);
      rd (base + 'h24); chk ("strobes hi", rg_r, 32'h11BB22DD);
      // a write with no strobes in its lane: OKAY, no bus access
      wr (base + 'h20, 32'h3000_0000, 4'hF);
      action rg_acc0 <= rg_acc; endaction
      wr (base + 'h20, 32'hFFFF_FFFF, 4'h0);
      chk ("no-strobe resp", zeroExtend (rg_resp), 0);
      action chk ("no-strobe access", pack (rg_acc - rg_acc0), 0); endaction
      rd (base + 'h20); chk ("no-strobe left the word", rg_r, 32'h3000_0000);
      // nobody home: SLVERR after the watchdog, reads return 0
      wr (dead + 4, 32'h1234_5678, 4'hF);
      chk ("dead wr resp", zeroExtend (rg_resp), 2);
      rd (dead);
      chk ("dead rd resp", zeroExtend (rg_resp), 2);
      chk ("dead rd data", rg_r, 0);
      // and the bridge still works afterwards
      wr (base + 'h3C, 32'h600D_F00D, 4'hF);
      rd (base + 'h3C); chk ("after timeout", rg_r, 32'h600D_F00D);
      action
         if (rg_err + rg_derr == 0) $display ("Tb_AXI4_RegBus: PASS (%0d cycles)", rg_t);
         else $display ("Tb_AXI4_RegBus: FAIL (%0d errors)", rg_err + rg_derr);
      endaction
   endseq);
endmodule

endpackage
