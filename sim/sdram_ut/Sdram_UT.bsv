// Synthesis boundary for the stand-alone Sdram_Controller unit test (sim/sdram_ut):
// the controller behind a 256-bit raw-word adapter (32-byte granule r = line r >> 1,
// half r[0]; a read returns the half's 4 chunks as one word), so tb.sv drives
// whole half-line reads and masked writes.
package Sdram_UT;
import Vector       :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;
import Memory       :: *;
import Mem_Controller   :: *;
import Sdram_Controller :: *;

interface Sdram_UT_IFC;
   interface MemoryServer #(64, 256)  mem_server;
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

(* synthesize *)
module mkSdram_UT (Sdram_UT_IFC);
   let c <- mkSdram_Controller (25_000_000);

   Vector #(3, Reg #(Bit #(64))) rg_w   <- replicateM (mkRegU);
   Reg #(Bit #(2))               rg_n   <- mkReg (0);
   FIFOF #(MemoryResponse #(256)) f_rsp <- mkFIFOF;

   rule rl_assemble;
      let ch <- c.mem_server.response.get;
      if (rg_n == 3) f_rsp.enq (MemoryResponse {data: { ch, rg_w [2], rg_w [1], rg_w [0] }});
      else rg_w [rg_n] <= ch;
      rg_n <= rg_n + 1;
   endrule

   interface MemoryServer mem_server;
      interface Put request;
         method Action put (MemoryRequest #(64, 256) r);
            Bit #(2) b0 = { r.address [0], 1'b0 };
            c.mem_server.request.put (Raw_Mem_Req {write: r.write, line: truncate (r.address >> 1),
                                                   b_first: b0, b_last: b0 + 1, wdata: r.data, wbe: r.byteen});
         endmethod
      endinterface
      interface Get response = toGet (f_rsp);
   endinterface
   method init_done    = c.init_done;
   method sdram_cke    = c.sdram_cke;
   method sdram_cs_n   = c.sdram_cs_n;
   method sdram_ras_n  = c.sdram_ras_n;
   method sdram_cas_n  = c.sdram_cas_n;
   method sdram_we_n   = c.sdram_we_n;
   method sdram_ba     = c.sdram_ba;
   method sdram_a      = c.sdram_a;
   method sdram_dqm    = c.sdram_dqm;
   method sdram_dq_out = c.sdram_dq_out;
   method sdram_dq_oe  = c.sdram_dq_oe;
   method sdram_dq_in  = c.sdram_dq_in;
endmodule
endpackage
