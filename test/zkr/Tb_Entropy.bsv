// Unit-test wrapper: synthesizes mkEntropy_Source_RO as a standalone module for test/zkr/run.sh.
package Tb_Entropy;
import Entropy_Source :: *;
(* synthesize *)
module mkTb_Entropy (Entropy_Source_IFC);
   let m <- mkEntropy_Source_RO;
   return m;
endmodule
endpackage
