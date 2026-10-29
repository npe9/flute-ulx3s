// ================================================================
// ULX3S_Sim: the virtual ULX3S board.  mkULX3S_Top -- the netlist the FPGA gets -- with the
// board around it modelled, so the host tools work against it unchanged:
//
//   SDRAM   behavioral W9825G6KH (test/Board_Models.bsv), array in C; SIM_BLOB (default: the
//           TempleOS REPL) placed in it at time 0, or SIM_BLOB=none to load over the UART.
//   UART    the FTDI pins, 8N1 at the SoC's baud.  SIM_PTY=1: bridged to a host pty
//           (build/sim-tty) for loader.py --sim, dmi.py, picocom.  Otherwise the console goes
//           to stdout, and SIM_PASS_STR ends the run when it appears (CI).
//   LEDs    changes printed; with SIM_PTY=1 also "leds XX cycle N" lines on build/sim-ctl.
//   BTN1    '1' / '0' on build/sim-ctl press / release it.
//
// With a preloaded blob the board sends the boot ROM a zero-length loader header after a short
// warmup, which jumps to 0x80000000 without loading (scripts/loader.py --jump does the same).
// No test script lives here: the scripted REPL/DMI checks stay in Repl_Boot_Tb.
//
// Run (from flute-ulx3s):  make sim-board        (README: "No board? Use the simulator")
// ================================================================

package ULX3S_Sim;

import FIFOF :: *;

import ULX3S_Top    :: *;
import Board_Models :: *;

// ================================================================

Integer max_cycles_dflt = 600_000_000;   // SIM_MAX_CYCLES overrides; pty mode never times out

typedef enum {S_INIT, S_WARMUP, S_HDR, S_RUN} BState deriving (Bits, Eq);

(* synthesize *)
module mkULX3S_Sim (Empty);

   ULX3S_Top_IFC dut   <- mkULX3S_Top;
   let           sdram <- mkW9825_Model (dut);

   Reg #(BState)    st        <- mkReg (S_INIT);
   Reg #(Bit #(40)) rg_cycle  <- mkReg (0);
   Reg #(Bit #(40)) rg_max    <- mkReg (fromInteger (max_cycles_dflt));
   Reg #(Bool)      pass_on   <- mkReg (False);
   Reg #(Bool)      pty_on    <- mkReg (False);
   Reg #(Bit #(32)) warmup    <- mkReg (500_000);
   Reg #(Bit #(3))  hdr_i     <- mkReg (0);

   // host -> DUT serial
   FIFOF #(Bit #(8)) f_rx_host <- mkSizedFIFOF (32);
   Reg #(Bit #(4))  rx_bit  <- mkReg (0);
   Reg #(Bit #(16)) rx_tmr  <- mkReg (0);
   Reg #(Bool)      rx_busy <- mkReg (False);
   Reg #(Bit #(1))  rg_rxd  <- mkReg (1);

   // DUT TX pin decoder
   Reg #(Bit #(1))  tx_prev   <- mkReg (1);
   Reg #(Bit #(4))  tx_cnt    <- mkReg (0);
   Reg #(Bit #(8))  tx_sh     <- mkReg (0);
   Reg #(Bool)      tx_active <- mkReg (False);
   Reg #(Bit #(16)) tx_timer  <- mkReg (0);

   Reg #(Bit #(8)) prev_leds <- mkReg (8'hFF);
   Reg #(Bit #(1)) rg_btn1   <- mkReg (0);

   // --------------------------------------------------
   // Time 0: place the blob, read the run mode.

   rule rl_init (st == S_INIT);
      let n  <- c_mem_load (sdram_map);
      let md <- c_sim_mode;
      let mx <- c_sim_max_cycles (fromInteger (max_cycles_dflt));
      pass_on <= (md [0] == 1);
      pty_on  <= (md [1] == 1);
      rg_max  <= truncate (mx);    // pty mode: no cap unless SIM_MAX_CYCLES sets one
      st      <= (md [2] == 1) ? S_RUN : S_WARMUP;
      if (md [2] == 1) $display ("[board] SIM_BLOB=none: the boot ROM waits for a loader");
      else             $display ("[board] preload: %0d halfwords", n);
      if (md [1] == 1) $display ("[board] UART on a host pty; board controls on a second pty");
      if (md [0] == 1) $display ("[board] pass on SIM_PASS_STR, cap %0d cycles", mx);
   endrule

   rule rl_warmup (st == S_WARMUP);
      if (warmup != 0) warmup <= warmup - 1;
      else begin
         st <= S_HDR;
         $display ("[board] sending zero-length header (jump to 0x80000000)");
      end
   endrule

   // {addr = 0x80000000, len = 0}, little-endian: the boot ROM jumps without loading
   rule rl_hdr (st == S_HDR && f_rx_host.notFull);
      f_rx_host.enq ((hdr_i == 3) ? 8'h80 : 8'h00);
      hdr_i <= hdr_i + 1;
      if (hdr_i == 7) st <= S_RUN;
   endrule

   // host pty -> UART RX (polled every 64 cycles; a byte takes 400)
   rule rl_pty_rx (st == S_RUN && pty_on && f_rx_host.notFull && (rg_cycle [5:0] == 0));
      let v <- c_pty_getc;
      if (v [8] == 1) f_rx_host.enq (v [7:0]);
   endrule

   // --------------------------------------------------
   // Host -> DUT serial bit-banger (drains f_rx_host at 8N1)

   rule rl_rx_xmit (f_rx_host.notEmpty);
      if (! rx_busy) begin
         if (rx_tmr == 0) begin
            rx_busy <= True;
            rx_bit  <= 0;
            rx_tmr  <= fromInteger (cycles_per_bit - 1);
            rg_rxd  <= 0;                    // start bit
         end
         else
            rx_tmr <= rx_tmr - 1;
      end
      else if (rx_tmr != 0)
         rx_tmr <= rx_tmr - 1;
      else begin
         rx_tmr <= fromInteger (cycles_per_bit - 1);
         if (rx_bit < 8) begin
            rg_rxd <= f_rx_host.first [rx_bit];
            rx_bit <= rx_bit + 1;
         end
         else begin
            rg_rxd  <= 1;                    // stop bit
            rx_busy <= False;
            rx_bit  <= 0;
            f_rx_host.deq;
         end
      end
   endrule

   // --------------------------------------------------
   // DUT TX pin: mid-bit sampling.  Single-assignment next-state form (as in Repl_Boot_Tb):
   // with -aggressive-conditions, several textual writes to one register across branches split
   // into conflicting rule fragments.

   rule rl_tx;
      let b = dut.serial_txd;
      Bool      n_active = tx_active;
      Bit #(16) n_timer  = tx_timer;
      Bit #(4)  n_cnt    = tx_cnt;
      Bit #(8)  n_sh     = tx_sh;
      if (! tx_active) begin
         if (tx_prev == 1 && b == 0) begin
            n_active = True;
            n_timer  = fromInteger (cycles_per_bit + cycles_per_bit / 2);
            n_cnt    = 0;
         end
      end
      else if (tx_timer != 0)
         n_timer = tx_timer - 1;
      else begin
         n_timer = fromInteger (cycles_per_bit - 1);
         if (tx_cnt == 8) begin
            n_active = False;
            let c = tx_sh;
            if (pty_on) c_pty_putc (c);
            else if (! pass_on) $write ("%c", c);    // with a pass string, c_console echoes it
            if (pass_on) begin
               let hit <- c_console (c);
               if (hit != 0) begin
                  $display ("\n[board] PASS: SIM_PASS_STR seen at cycle %0d", rg_cycle);
                  $finish (0);
               end
            end
         end
         else begin
            n_sh  = { b, tx_sh [7:1] };
            n_cnt = tx_cnt + 1;
         end
      end
      tx_active <= n_active;
      tx_timer  <= n_timer;
      tx_cnt    <= n_cnt;
      tx_sh     <= n_sh;
      tx_prev   <= b;
   endrule

   // --------------------------------------------------
   // Pins, board controls, cycle cap.  The BTN1 poll is here, not in a rule of its own: bsc
   // orders imported actions as conflicting, and a separate rule blocked this one (the cycle
   // counter stopped).

   rule rl_pins;
      dut.serial_rxd (rg_rxd);
      dut.btn1 (rg_btn1);
      if (pty_on && (rg_cycle [11:0] == 0)) begin
         let b <- c_ctl_btn (zeroExtend (rg_btn1));
         if (b [0] != rg_btn1) $display ("[board] BTN1 = %0d (cycle %0d)", b [0], rg_cycle);
         rg_btn1 <= b [0];
      end
      let l = dut.leds;
      if (l != prev_leds) begin
         prev_leds <= l;
         if (pty_on) c_ctl_leds (l, zeroExtend (rg_cycle));
         $display ("\n[board] LEDs = %02x (cycle %0d)", l, rg_cycle);
      end
      rg_cycle <= rg_cycle + 1;
      if (rg_cycle > rg_max) begin
         $display ("\n[board] TIMEOUT after %0d cycles", rg_cycle);
         $finish (0);
      end
   endrule

endmodule

endpackage
