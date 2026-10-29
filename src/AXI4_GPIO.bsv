// ================================================================
// AXI4_GPIO: simple memory-mapped GPIO replacing the Accel0 slot in
// the Flute SoC.  Address map (offset from base):
//   0x00  LED output (8 bits, read/write)
//   0x04  Button input (bit 0 = BTN1, read-only)
// ================================================================

package AXI4_GPIO;

export AXI4_GPIO_IFC (..), mkAXI4_GPIO;

import RegFile      :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;
import Cur_Cycle    :: *;
import GetPut_Aux   :: *;
import Semi_FIFOF   :: *;

import AXI4_Types   :: *;
import AXI4_Xactors :: *;
import Fabric_Defs  :: *;
import AXI4_Accel_IFC :: *;

// ================================================================

interface AXI4_GPIO_IFC;
   method Action init (Bit #(Wd_Id) axi4_id, Bit #(Wd_Addr) addr_base, Bit #(Wd_Addr) addr_lim);
   // SoC soft reset (ndmreset): drop transactions in flight with the fabric that is reset with
   // this slave (the fabric routes responses in order; a stale one would go to the wrong request)
   method Action reset;

   interface AXI4_Slave_IFC  #(Wd_Id, Wd_Addr, Wd_Data, Wd_User)  slave;

   method Bool interrupt_req;

   interface AXI4_Master_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User)  master;

   (* always_ready *) method Bit #(8) leds;
   (* always_enabled *) method Action btn1 (Bit #(1) v);
endinterface

// ================================================================

(* synthesize *)
module mkAXI4_GPIO (AXI4_GPIO_IFC);

   Reg #(Bit #(Wd_Addr)) rg_addr_base <- mkRegU;
   Reg #(Bit #(Wd_Addr)) rg_addr_lim  <- mkRegU;

   AXI4_Slave_Xactor_IFC  #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) slave_xactor  <- mkAXI4_Slave_Xactor;
   AXI4_Master_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) master_xactor <- mkAXI4_Master_Xactor;

   Reg #(Bit #(8)) rg_leds <- mkReg (0);
   Reg #(Bit #(1)) rg_btn1 <- mkReg (0);

   // ----------------------------------------------------------------
   // Write handler

   rule rl_wr;
      let wra <- pop_o (slave_xactor.o_wr_addr);
      let wrd <- pop_o (slave_xactor.o_wr_data);

      Bit #(Wd_Data) wdata = wrd.wdata;
      Bit #(8)       wstrb = zeroExtend (wrd.wstrb);

      let byte_addr = wra.awaddr - rg_addr_base;
      AXI4_Resp bresp = axi4_resp_okay;

      if ((wra.awaddr < rg_addr_base) || (wra.awaddr >= rg_addr_lim))
	 bresp = axi4_resp_decerr;
      else if (byte_addr [31:3] != 0)
	 bresp = axi4_resp_decerr;
      else if (byte_addr [2:0] == 3'b000) begin
	 // LED register: apply only bytes that have strobe set
	 if (wstrb [0] == 1'b1) rg_leds <= wdata [7:0];
      end
      // offset 0x04 is read-only

      let wrr = AXI4_Wr_Resp {bid: wra.awid, bresp: bresp, buser: wra.awuser};
      slave_xactor.i_wr_resp.enq (wrr);
   endrule

   // ----------------------------------------------------------------
   // Read handler

   rule rl_rd;
      let rda <- pop_o (slave_xactor.o_rd_addr);

      let byte_addr = rda.araddr - rg_addr_base;
      Fabric_Data rdata = 0;
      AXI4_Resp   rresp = axi4_resp_okay;

      if ((rda.araddr < rg_addr_base) || (rda.araddr >= rg_addr_lim))
	 rresp = axi4_resp_decerr;
      else if (byte_addr [31:3] != 0)
	 rresp = axi4_resp_decerr;
      else if (byte_addr [2:0] == 3'b000)
	 rdata = zeroExtend (rg_leds);
      else if (byte_addr [2:0] == 3'b100)
	 // a 64-bit fabric carries the word at +4 in lanes [63:32] (as SoC_Info does); the low
	 // lane always read 0 -- found by the virtual board's BTN1 smoke
	 rdata = zeroExtend (rg_btn1) << ((valueOf (Wd_Data) == 64) ? 32 : 0);

      let rdr = AXI4_Rd_Data {rid:   rda.arid,
			      rdata: rdata,
			      rresp: rresp,
			      rlast: True,
			      ruser: rda.aruser};
      slave_xactor.i_rd_data.enq (rdr);
   endrule

   // ----------------------------------------------------------------
   // INTERFACE

   method Action init (Bit #(Wd_Id) axi4_id, Bit #(Wd_Addr) addr_base, Bit #(Wd_Addr) addr_lim);
      rg_addr_base <= addr_base;
      rg_addr_lim  <= addr_lim;
   endmethod

   method Action reset;
      slave_xactor.reset;
      master_xactor.reset;
   endmethod

   interface slave  = slave_xactor.axi_side;
   interface master = master_xactor.axi_side;

   method Bool interrupt_req = False;

   method Bit #(8) leds = rg_leds;
   method Action btn1 (Bit #(1) v);
      rg_btn1 <= v;
   endmethod
endmodule

endpackage
