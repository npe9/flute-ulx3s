// ================================================================
// ULX3S_Boot_Tb: Bluesim smoke test for mkULX3S_Top.
//
// Drives RX idle, samples TX every 20 MHz cycle, and prints the raw
// TX bit.  A post-processing script can decode the 115200 baud UART
// stream to verify the boot-loader banner.
// ================================================================

package ULX3S_Boot_Tb;

import ULX3S_Top :: *;

(* synthesize *)
module mkULX3S_Boot_Tb (Empty);
   ULX3S_Top_IFC dut <- mkULX3S_Top;

   Reg #(Bit #(32)) rg_cycle <- mkReg (0);

   rule rl_tick;
      dut.serial_rxd (1'b1);    // RX idle
      dut.sdram_dq_in (0);
      $display ("%0d %b", rg_cycle, dut.serial_txd);
      rg_cycle <= rg_cycle + 1;
      if (rg_cycle > 200_000)
         $finish (0);
   endrule
endmodule

endpackage
