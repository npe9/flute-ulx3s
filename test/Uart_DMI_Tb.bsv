// ================================================================
// Uart_DMI_Tb: unit test for Uart_DMI_Bridge pass-through losslessness
// and magic arming.  Regression for the two bugs that broke binary
// kernel loads over the FTDI UART:
//   (1) a bare 0xDB followed by a non-magic byte was DROPPED on a
//       partial-magic mismatch (replay off-by-one), shifting the whole
//       byte stream by one position and corrupting every chunk that
//       contained 0xDB (~1 in 40 chunks of TempleOS image data);
//   (2) a trailing 0xDB (e.g. a chunk checksum) parked the bridge in
//       ST_MAGIC forever (the idle timeout only covered ST_FRAME),
//       swallowing the byte and wedging the loader deterministically
//       whenever a checksum happened to equal 0xDB.
//
// Phases (20-cycle inter-byte gap, modelling ~200-cycle UART spacing;
// the replay path drains at 1 byte/cycle, so gaps keep the test in the
// regime the DUT is designed for):
//   0: data containing bare and consecutive 0xDBs   -> console, lossless
//   1: partial magic (DB 53 44) then mismatch       -> console, lossless
//   2: trailing 0xDB then >10 ms idle               -> 0xDB released to
//      the console by the ST_MAGIC idle timeout
//   3: full magic + 'q' disarm request              -> consumed; 6-byte
//      response on dbg_tx; nothing on console
//   4: ordinary byte after disarm                   -> console
//   5: settle
// Expected: console = 6+4+2+1 = 13 bytes, dbg = 6 bytes.
// ================================================================

package Uart_DMI_Tb;

import Vector       :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;

import Uart_DMI_Bridge :: *;

// ----------------------------------------------------------------

function Bit #(8) fn_phase_byte (Bit #(32) ph, Bit #(32) i);
   if (ph == 0) begin
      // bare 0xDBs in ordinary data, including two in a row
      case (i)
         0: return 8'h11;
         1: return 8'hDB;
         2: return 8'h22;
         3: return 8'hDB;
         4: return 8'hDB;
         default: return 8'h33;    // i == 5
      endcase
   end
   else if (ph == 1) begin
      // partial magic then mismatch
      case (i)
         0: return 8'hDB;
         1: return 8'h53;          // 'S'
         2: return 8'h44;          // 'D'
         default: return 8'h58;    // 'X'
      endcase
   end
   else if (ph == 2)
      return (i == 0) ? 8'hAA : 8'hDB;
   else if (ph == 3) begin
      // real magic + 'q' disarm request
      case (i)
         0: return 8'hDB;
         1: return 8'h53;
         2: return 8'h44;
         3: return 8'h4D;
         4: return 8'h01;
         5: return 8'h02;
         6: return 8'h03;
         7: return 8'h04;
         8: return 8'h71;          // 'q'
         default: return 8'h00;
      endcase
   end
   else if (ph == 4)
      return 8'h55;
   else
      return 8'h00;
endfunction

function Bit #(32) fn_phase_nbytes (Bit #(32) ph);
   if (ph == 0) return 6;
   else if (ph == 1) return 4;
   else if (ph == 2) return 2;
   else if (ph == 3) return 14;
   else if (ph == 4) return 1;
   else return 0;
endfunction

function Bit #(32) fn_phase_idle (Bit #(32) ph);
   // idle cycles AFTER the phase's last byte
   if (ph == 2) return 200_000;    // > 10 ms ST_MAGIC timeout (cycles)
   else if (ph == 5) return 20_000;
   else return 10;
endfunction

// The console must see every stimulus byte EXCEPT the 14 consumed by
// phase 3 (magic + request).
function Bit #(8) fn_expect_console (Bit #(32) i);
   if (i < 6) return fn_phase_byte (0, i);
   else if (i < 10) return fn_phase_byte (1, i - 6);
   else if (i < 12) return fn_phase_byte (2, i - 10);
   else return 8'h55;              // i == 12: phase 4
endfunction

// ----------------------------------------------------------------

(* synthesize *)
module mkUart_DMI_Tb (Empty);

   Uart_DMI_Bridge_IFC dut <- mkUart_DMI_Bridge;

   Reg #(Bit #(32)) rg_phase <- mkReg (0);
   Reg #(Bit #(32)) rg_idx   <- mkReg (0);
   Reg #(Bit #(32)) rg_idle  <- mkReg (0);
   Reg #(Bit #(32)) rg_bgap  <- mkReg (0);   // inter-byte gap
   Reg #(Bool)      rg_done  <- mkReg (False);

   Reg #(Bit #(32)) rg_chk    <- mkReg (0);    // console bytes checked
   Reg #(Bit #(32)) rg_dchk   <- mkReg (0);    // dbg bytes checked
   Reg #(Bit #(32)) rg_errs   <- mkReg (0);
   Reg #(Bool)      rg_checked <- mkReg (False);
   Reg #(Bit #(32)) rg_settle <- mkReg (0);

   let nbytes = fn_phase_nbytes (rg_phase);
   let idle   = fn_phase_idle  (rg_phase);

   // Feed stimulus with 20-cycle inter-byte gaps: the bridge's replay
   // path drains at 1 byte/cycle, and the DUT's design assumption is
   // UART spacing (~200 cycles at 625000 baud).  Feeding back-to-back
   // would test an impossible-for-hardware scenario.
   Integer byte_gap = 20;

   rule rl_feed (! rg_done);
      if (rg_bgap != 0)
         rg_bgap <= rg_bgap - 1;
      else if (rg_idx < nbytes) begin
         dut.rx_from_uart.put (fn_phase_byte (rg_phase, rg_idx));
         rg_idx  <= rg_idx + 1;
         rg_bgap <= fromInteger (byte_gap - 1);
      end
      else if (rg_idle < idle)
         rg_idle <= rg_idle + 1;
      else if (rg_phase < 5) begin
         rg_phase <= rg_phase + 1;
         rg_idx   <= 0;
         rg_idle  <= 0;
      end
      else
         rg_done <= True;
   endrule

   rule rl_console;
      let b <- dut.rx_to_console.get ();
      if (rg_chk >= 13) begin
         rg_errs <= rg_errs + 1;
         $display ("FAIL: console byte %0d unexpected: %02x",
                   rg_chk, b);
      end
      else if (b != fn_expect_console (rg_chk)) begin
         rg_errs <= rg_errs + 1;
         $display ("FAIL: console[%0d] = %02x expected %02x",
                   rg_chk, b, fn_expect_console (rg_chk));
      end
      rg_chk <= rg_chk + 1;
   endrule

   rule rl_dbg;
      let b <- dut.dbg_tx.get ();
      Bit #(8) exp = (rg_dchk == 0) ? 8'hDB : 8'h00;
      if (rg_dchk >= 6) begin
         rg_errs <= rg_errs + 1;
         $display ("FAIL: dbg byte %0d unexpected: %02x", rg_dchk, b);
      end
      else if (b != exp) begin
         rg_errs <= rg_errs + 1;
         $display ("FAIL: dbg[%0d] = %02x expected %02x", rg_dchk, b, exp);
      end
      rg_dchk <= rg_dchk + 1;
   endrule

   rule rl_finish (rg_done && ! rg_checked);
      if (rg_settle < 5000)
         rg_settle <= rg_settle + 1;
      else begin
         rg_checked <= True;
         if ((rg_errs == 0) && (rg_chk == 13) && (rg_dchk == 6))
            $display ("UART_DMI_TB PASS (console 13 bytes, dbg 6 bytes)");
         else
            $display ("UART_DMI_TB FAIL: errs=%0d console=%0d/13 dbg=%0d/6",
                      rg_errs, rg_chk, rg_dchk);
         $finish (0);
      end
   endrule

endmodule

endpackage
