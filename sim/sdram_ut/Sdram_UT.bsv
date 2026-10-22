// Synthesis boundary for the stand-alone Sdram_Controller unit test (sim/sdram_ut).
package Sdram_UT;
import Sdram_Controller :: *;
(* synthesize *)
module mkSdram_UT (Sdram_Controller_IFC);
   let ifc <- mkSdram_Controller (25_000_000);
   return ifc;
endmodule
endpackage
