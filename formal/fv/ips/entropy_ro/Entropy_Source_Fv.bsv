// Entropy_Source_Fv: Flute's Entropy_Source.bsv mkEntropy_Source_RO_P for formal/fv.  _Fv: a small
// instance (2 raw bits per sample, RCT cutoff 5, APT cutoff 13 in a window of 16) so bmc and cover
// reach ES16 and DEAD; _Real: the SoC's mkEntropy_Source_RO itself (8, 41, 793, 1024).
package Entropy_Source_Fv;

import Entropy_Source :: *;

module mkEntropy_Source_RO_Small (Entropy_Source_IFC); let m <- mkEntropy_Source_RO_P (2, 5, 13, 16); return m; endmodule

// (both one level deep, so the checker names the same internals, m_m_rg_*, in either)
(* synthesize *) module mkEntropy_Source_RO_Fv   (Entropy_Source_IFC); let m <- mkEntropy_Source_RO_Small; return m; endmodule
(* synthesize *) module mkEntropy_Source_RO_Real (Entropy_Source_IFC); let m <- mkEntropy_Source_RO;                 return m; endmodule

endpackage
