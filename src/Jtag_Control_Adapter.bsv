// ================================================================
// Jtag_Control_Adapter
//
// Bridges the raw DMI slave interface from mkJtagTap to the
// Server#(Control_Req, Control_Rsp) interface exposed by Flute's
// SoC_Top when INCLUDE_GDB_CONTROL is defined.
//
// DMI opcodes (from JtagTap.bsv):
//   0 = NOP    -> consume silently
//   1 = READ   -> Control_Req op=10, arg1=addr
//   2 = WRITE  -> Control_Req op=11, arg1=addr, arg2=data
//
// The DMI response always reports status 0 (success) with the
// 32-bit result data.
// ================================================================

package Jtag_Control_Adapter;

import FIFOF         :: *;
import GetPut        :: *;
import ClientServer  :: *;
import Jtag_IFC         :: *;
import External_Control :: *;

// ----------------------------------------------------------------

interface Jtag_Control_Adapter_IFC;
   // DMI slave: connect to mkJtagTap.dmi
   interface DMI_IFC dmi;

   // Client: connect to SoC_Top.server_external_control
   interface Client #(Control_Req, Control_Rsp) client;
endinterface

// ----------------------------------------------------------------

(* synthesize *)
module mkJtag_Control_Adapter (Jtag_Control_Adapter_IFC);

   // Buffer one incoming DMI transaction.
   FIFOF #(Tuple3 #(Bit #(7), Bit #(32), Bit #(2))) f_dmi_req <- mkFIFOF;

   // Requests to / responses from SoC_Top's debug server.
   FIFOF #(Control_Req) f_req <- mkFIFOF;
   FIFOF #(Control_Rsp) f_rsp <- mkFIFOF;

   // Latched DMI inputs.  The source drives all signals in the same
   // cycle, so we capture them when req_valid is asserted.
   Reg #(Bit #(7))  rg_addr <- mkReg (0);
   Reg #(Bit #(32)) rg_data <- mkRegU;    // E38b: latched with req_valid, not reset
   Reg #(Bit #(2))  rg_op   <- mkReg (0);

   Bit #(2) dmi_op_nop   = 0;
   Bit #(2) dmi_op_read  = 1;
   Bit #(2) dmi_op_write = 2;

   // ----------------------------------------------------------------
   // Convert DMI request to Control_Req

   rule rl_convert_dmi_req (f_dmi_req.notEmpty);
      match {.addr, .data, .op} = f_dmi_req.first;
      f_dmi_req.deq;

      if (op == dmi_op_read) begin
	 f_req.enq (Control_Req {op: external_control_req_op_read_control_fabric,
				 arg1: zeroExtend (addr),
				 arg2: 0});
      end
      else if (op == dmi_op_write) begin
	 f_req.enq (Control_Req {op: external_control_req_op_write_control_fabric,
				 arg1: zeroExtend (addr),
				 arg2: zeroExtend (data)});
      end
      // NOP (op == 0) is silently consumed.
   endrule

   // ----------------------------------------------------------------
   // Exported interfaces

   interface DMI_IFC dmi;
      method req_ready;
	 return f_dmi_req.notFull ? 1 : 0;
      endmethod

      method Action req_valid (Bit #(1) v);
	 if (v == 1 && f_dmi_req.notFull) begin
	    f_dmi_req.enq (tuple3 (rg_addr, rg_data, rg_op));
	 end
      endmethod

      method Action req_addr (Bit #(7) x);
	 rg_addr <= x;
      endmethod

      method Action req_data (Bit #(32) x);
	 rg_data <= x;
      endmethod

      method Action req_op (Bit #(2) x);
	 rg_op <= x;
      endmethod

      method Action rsp_ready (Bit #(1) v);
	 if (v == 1 && f_rsp.notEmpty) begin
	    f_rsp.deq;
	 end
      endmethod

      method rsp_valid;
	 return f_rsp.notEmpty ? 1 : 0;
      endmethod

      method rsp_data;
	 return f_rsp.notEmpty ? f_rsp.first.result [31:0] : 0;
      endmethod

      method rsp_response;
	 // 0 = success; matches DMI_OP opSUCCESS in JtagTap.bsv
	 return 0;
      endmethod
   endinterface

   interface Client client;
      interface Get request = toGet (f_req);
      interface Put response = toPut (f_rsp);
   endinterface
endmodule

endpackage
