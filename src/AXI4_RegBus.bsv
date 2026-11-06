// ================================================================
// AXI4_RegBus: one AXI4 slave port terminating into a 32-bit register bus, so small devices
// (and the Verilog video block) do not each carry an AXI transactor.  One access at a time.
//
// Register bus (sys clock, all outputs registered):
//   rb_valid  request pending; held, with rb_we/addr/wdata/wstrb stable, until the cycle the
//             device raises rb_ack
//   rb_we     1 write, 0 read
//   rb_addr   full byte address (word aligned); the device decodes its own windows
//   rb_wdata, rb_wstrb   the 32-bit lane of the AXI beat (on the 64-bit fabric a word at
//             +4 is in lanes [63:32])
//   rb_ack, rb_rdata (device -> bridge, every cycle): rb_ack high for exactly one cycle per
//             request, rb_rdata valid in that cycle for reads.  rb_valid drops the cycle
//             after the ack, so a device must not take a second request in the ack cycle.
// A request with no ack within 256 cycles completes with SLVERR (no device at the address).
// Writes with no byte strobes in the addressed lane complete at once without a bus access.
// Single-beat transfers only, like every other slave on the peripheral bridge.
// ================================================================

package AXI4_RegBus;

export AXI4_RegBus_IFC (..), mkAXI4_RegBus;

import ConfigReg    :: *;
import FIFOF        :: *;
import GetPut       :: *;
import Semi_FIFOF   :: *;

import AXI4_Types   :: *;
import AXI4_Xactors :: *;
import Fabric_Defs  :: *;

interface AXI4_RegBus_IFC;
   method Action reset;

   interface AXI4_Slave_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) slave;

   (* always_ready *)   method Bit #(1)  rb_valid;
   (* always_ready *)   method Bit #(1)  rb_we;
   (* always_ready *)   method Bit #(32) rb_addr;
   (* always_ready *)   method Bit #(32) rb_wdata;
   (* always_ready *)   method Bit #(4)  rb_wstrb;
   (* always_enabled *) method Action    rb_ack (Bit #(1) ack, Bit #(32) rdata);
`ifdef FORMAL
   // formal/regbus: the watchdog, so the harness can tell a timeout from a dropped request
   (* always_ready *)   method Bit #(8)  f_wdog;
`endif
endinterface

typedef enum { RB_IDLE, RB_WR, RB_RD } RB_State deriving (Bits, Eq, FShow);

(* synthesize *)
module mkAXI4_RegBus (AXI4_RegBus_IFC);

   AXI4_Slave_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) slave_xactor <- mkAXI4_Slave_Xactor;

   Reg #(RB_State)       rg_state <- mkReg (RB_IDLE);
   Reg #(Bit #(32))      rg_addr  <- mkRegU;
   Reg #(Bit #(32))      rg_wdata <- mkRegU;
   Reg #(Bit #(4))       rg_wstrb <- mkRegU;
   Reg #(Bool)           rg_hi    <- mkRegU;    // the word is in lanes [63:32]
   Reg #(Bit #(Wd_Id))   rg_id    <- mkRegU;
   Reg #(Bit #(Wd_User)) rg_user  <- mkRegU;
   Reg #(Bit #(8))       rg_wdog  <- mkRegU;

   // the device's ack and read data, sampled every cycle (always_enabled)
   Wire #(Bit #(1))  w_ack   <- mkBypassWire;
   Wire #(Bit #(32)) w_rdata <- mkBypassWire;

   function Bool fn_hi (Bit #(Wd_Addr) a) = ((valueOf (Wd_Data) == 64) && (a [2] == 1));
   function Bit #(32) fn_word_addr (Bit #(Wd_Addr) a);
      Bit #(32) a32 = truncate (a);
      return a32 & 32'hFFFF_FFFC;
   endfunction

   // ================================================================
   // Request intake (one at a time; writes win a tie).  A request starts only when its
   // response FIFO has room, so rl_finish can always take the device's one-cycle ack
   // (formal/regbus: with two responses unaccepted the ack was lost and the device saw the
   // request again).

   (* descending_urgency = "rl_wr_start, rl_rd_start" *)
   rule rl_wr_start ((rg_state == RB_IDLE) && slave_xactor.i_wr_resp.notFull);
      let wra <- pop_o (slave_xactor.o_wr_addr);
      let wrd <- pop_o (slave_xactor.o_wr_data);

      Bit #(64) wdata64 = zeroExtend (wrd.wdata);
      Bit #(8)  wstrb8  = zeroExtend (wrd.wstrb);
      Bool      hi      = fn_hi (wra.awaddr);
      Bit #(4)  stb     = hi ? wstrb8 [7:4] : wstrb8 [3:0];

      if (stb == 0)
         slave_xactor.i_wr_resp.enq (AXI4_Wr_Resp {bid: wra.awid, bresp: axi4_resp_okay, buser: wra.awuser});
      else begin
         rg_addr  <= fn_word_addr (wra.awaddr);
         rg_wdata <= hi ? wdata64 [63:32] : wdata64 [31:0];
         rg_wstrb <= stb;
         rg_id    <= wra.awid;
         rg_user  <= wra.awuser;
         rg_wdog  <= 0;
         rg_state <= RB_WR;
      end
   endrule

   rule rl_rd_start ((rg_state == RB_IDLE) && slave_xactor.i_rd_data.notFull);
      let rda <- pop_o (slave_xactor.o_rd_addr);
      rg_addr  <= fn_word_addr (rda.araddr);
      rg_hi    <= fn_hi (rda.araddr);
      rg_id    <= rda.arid;
      rg_user  <= rda.aruser;
      rg_wdog  <= 0;
      rg_state <= RB_RD;
   endrule

   // ================================================================
   // Completion: the device's ack, or the watchdog

   rule rl_finish (rg_state != RB_IDLE);
`ifdef FORMAL_SHORT_WDOG
      Bool timeout = (rg_wdog == 7);     // formal cover build only: reach SLVERR in a few steps
`else
      Bool timeout = (rg_wdog == '1);
`endif
      if ((w_ack == 1) || timeout) begin
         AXI4_Resp resp = (w_ack == 1) ? axi4_resp_okay : axi4_resp_slverr;
         if (rg_state == RB_WR)
            slave_xactor.i_wr_resp.enq (AXI4_Wr_Resp {bid: rg_id, bresp: resp, buser: rg_user});
         else begin
            Bit #(32) v   = (w_ack == 1) ? w_rdata : 0;
            Bit #(64) d64 = rg_hi ? { v, 32'b0 } : zeroExtend (v);
            slave_xactor.i_rd_data.enq (AXI4_Rd_Data {rid:   rg_id,
                                                     rdata: truncate (d64),
                                                     rresp: resp,
                                                     rlast: True,
                                                     ruser: rg_user});
         end
         rg_state <= RB_IDLE;
      end
      else
         rg_wdog <= rg_wdog + 1;
   endrule

   // ================================================================
   // INTERFACE

   method Action reset;
      slave_xactor.reset;
      rg_state <= RB_IDLE;
   endmethod

   interface slave = slave_xactor.axi_side;

   method Bit #(1)  rb_valid = (rg_state != RB_IDLE) ? 1 : 0;
   method Bit #(1)  rb_we    = (rg_state == RB_WR) ? 1 : 0;
   method Bit #(32) rb_addr  = rg_addr;
   method Bit #(32) rb_wdata = rg_wdata;
   method Bit #(4)  rb_wstrb = rg_wstrb;
   method Action rb_ack (Bit #(1) ack, Bit #(32) rdata);
      w_ack   <= ack;
      w_rdata <= rdata;
   endmethod
`ifdef FORMAL
   method Bit #(8) f_wdog = rg_wdog;
`endif
endmodule

endpackage
