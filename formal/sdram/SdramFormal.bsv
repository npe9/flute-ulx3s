// Synthesized wrapper: mkSdram_Controller has an Integer parameter (the clock), so it has no
// module boundary of its own.  50 MHz, the shipping clock.
package SdramFormal;

import Sdram_Controller :: *;

(* synthesize *)
module mkSdramFormal (Sdram_Controller_IFC);
   let m <- mkSdram_Controller (50_000_000);
   return m;
endmodule

endpackage
