// ================================================================
// ULX3S_Top: FPGA top level for the Flute SoC on the ULX3S-85F.
//
// Wires mkSoC_Top (Flute RV32 + AXI4 fabric + boot ROM + CLINT +
// PLIC + 16550 UART) to:
//   - the SDRAM controller bridge (raw memory port)
//   - the physical UART pins (FTDI)
// and exposes board pins (LEDs, SDRAM, UART) to the Verilog wrapper.
//
// When INCLUDE_GDB_CONTROL is defined, a UART-DMI debug bridge is
// instantiated and connected to Flute's debug module through
// SoC_Top's server_external_control interface.  The bridge snoops the
// existing FTDI UART RX stream for a magic sequence ("\xDBSDM\x01\x02
// \x03\x04") and then speaks a fixed-frame DMI protocol (see
// Uart_DMI_Bridge.bsv), letting an openocd-free Python client halt the
// hart, read/write DM registers (GPRs via abstract commands, memory
// via system bus) and resume -- with no extra pins or adapter.  The
// J1-header JTAG TAP this replaced is preserved in git history.
//
// Clock: 25 MHz board clock divided by 2 => 12.5 MHz system clock.
// ================================================================

package ULX3S_Top;

export ULX3S_Top_IFC (..), mkULX3S_Top;

import GetPut      :: *;
import Connectable :: *;
import FIFOF       :: *;

import SoC_Top          :: *;
import Sdram_Controller :: *;
import Uart_Pins        :: *;

`ifdef INCLUDE_GDB_CONTROL
import Uart_DMI_Bridge     :: *;
`endif

`ifdef JTAG_TAP
import Jtag_IFC            :: *;
import JtagTap             :: *;
import Jtag_Control_Adapter :: *;
`endif

// ================================================================

interface ULX3S_Top_IFC;
   (* always_ready *)   method Bit #(1) serial_txd;
   (* always_enabled *) method Action  serial_rxd (Bit #(1) v);

   (* always_ready *) method Bit #(8) leds;

`ifdef INCLUDE_ACCEL0
   (* always_enabled *) method Action  btn1 (Bit #(1) v);
`endif

`ifdef JTAG_TAP
   // The J1-header JTAG TAP is kept in the design (unconnected to the
   // debug server; the UART bridge owns server_external_control) purely
   // to preserve the clock tree and placement landscape of the
   // known-good 2026-10-04 build -- removing it changed sys_clk
   // insertion delay enough to break SDRAM read sampling.
   interface JTAG_IFC jtag;
`endif

   (* always_ready *) method Bool     sdram_init_done;
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

// ================================================================

(* synthesize *)
module mkULX3S_Top (ULX3S_Top_IFC);

   // Board-level constants, single-sourced: used by the UART/SDRAM
   // instantiation AND the elaboration-time BOARD manifest line (captured
   // with the MEMMAP lines into build/soc-memory-map.json).
   Integer sys_clk_hz = 25_000_000;    // raw 25 MHz board clock (src/Top.v)
   Integer uart_baud  = 625_000;

   rule rl_emit_board_manifest;
      messageM ("BOARD clk " + integerToString (sys_clk_hz)
                + " baud " + integerToString (uart_baud)
                + " chip W9825G6KH-6 fpga LFE5U-85F core RV32IMAC");
   endrule

   SoC_Top_IFC          soc_top <- mkSoC_Top (fromInteger (sys_clk_hz));
   Sdram_Controller_IFC mem     <- mkSdram_Controller (sys_clk_hz);
   UART_Pins_IFC        uart    <- mkUART_Pins (sys_clk_hz, uart_baud);

   // SoC raw memory port -> SDRAM controller
   mkConnection (soc_top.to_raw_mem, mem.mem_server);

   // SoC UART byte streams -> physical pins, with the debug bridge
   // tapped into the RX path and merged onto the TX path.
`ifdef INCLUDE_GDB_CONTROL
   Uart_DMI_Bridge_IFC dbg   <- mkUart_DMI_Bridge;
   FIFOF #(Bit #(8))   f_tx  <- mkSizedFIFOF (64);

   mkConnection (uart.get, dbg.rx_from_uart);
   mkConnection (dbg.rx_to_console, soc_top.put_from_console);

   // Console TX yields to debug responses (strict priority).
   rule rl_console_tx (f_tx.notFull && ! dbg.dbg_tx_pending);
      let b <- soc_top.get_to_console.get;
      f_tx.enq (b);
`ifdef UART_PROBES
      $display ("[uart] cons %02x", b);
`endif
   endrule
   rule rl_dbg_tx (f_tx.notFull);
      let b <- dbg.dbg_tx.get;
      f_tx.enq (b);
`ifdef UART_PROBES
      $display ("[uart] dbg  %02x", b);
`endif
   endrule
   mkConnection (toGet (f_tx), uart.put);

   mkConnection (dbg.client, soc_top.server_external_control);

`ifdef JTAG_TAP
   // JTAG TAP kept for placement-parity with the known-good build;
   // its DMI output is intentionally left dangling (bridge owns the
   // debug server).
   JtagTap_IFC              jtag_tap <- mkJtagTap;
   Jtag_Control_Adapter_IFC jtag_adp <- mkJtag_Control_Adapter;
   mkConnection (jtag_tap.dmi, jtag_adp.dmi);
`endif
`else
   mkConnection (soc_top.get_to_console, uart.put);
   mkConnection (uart.get, soc_top.put_from_console);
`endif

   // Keep the CPU's memory traffic enabled once the SDRAM is initialized.
   // Repeating ma_ddr4_ready is safe (it just sets a register), and it
   // protects against the case where an earlier pulse was lost because the
   // CPU/cache was still in reset.
   rule rl_ddr4_ready (mem.init_done);
      soc_top.ma_ddr4_ready;
   endrule

   // Heartbeat
   Reg #(Bit #(26)) rg_cnt <- mkReg (0);
   rule rl_cnt;
      rg_cnt <= rg_cnt + 1;
   endrule

`ifdef UART_PROBES
   // Debug-response-priority edge logger: a stuck-TRUE dbg_tx_pending
   // silently starves the console TX path (rl_console_tx yields).
   Reg #(Bool) rg_prev_pend <- mkReg (False);
   rule rl_pend_probe;
      let p = dbg.dbg_tx_pending;
      if (p != rg_prev_pend)
         $display ("[uart] dbg_tx_pending -> %0d (cnt %0d)", pack (p), rg_cnt);
      rg_prev_pend <= p;
   endrule
`endif

   // ----------------------------------------------------------------
   // INTERFACE

   method serial_txd = uart.txd;

   method Action serial_rxd (Bit #(1) v);
      uart.rxd (v);
   endmethod

`ifdef INCLUDE_ACCEL0
   method Bit #(8) leds = { soc_top.gpio_leds [7] | pack (mem.init_done),
                            soc_top.gpio_leds [6:0] };

   method Action btn1 (Bit #(1) v);
      soc_top.gpio_btn1 (v);
   endmethod
`else
   method Bit #(8) leds;
      return { rg_cnt [24:21],            // heartbeat
               2'b00,
               pack (uart.rx_overflow || uart.rx_frame_err),
               pack (mem.init_done) };
   endmethod
`endif

`ifdef JTAG_TAP
   interface JTAG_IFC jtag = jtag_tap.jtag;
`endif

   method Bool     sdram_init_done = mem.init_done;
   method Bit #(1)  sdram_cke      = mem.sdram_cke;
   method Bit #(1)  sdram_cs_n     = mem.sdram_cs_n;
   method Bit #(1)  sdram_ras_n    = mem.sdram_ras_n;
   method Bit #(1)  sdram_cas_n    = mem.sdram_cas_n;
   method Bit #(1)  sdram_we_n     = mem.sdram_we_n;
   method Bit #(2)  sdram_ba       = mem.sdram_ba;
   method Bit #(13) sdram_a        = mem.sdram_a;
   method Bit #(2)  sdram_dqm      = mem.sdram_dqm;
   method Bit #(16) sdram_dq_out   = mem.sdram_dq_out;
   method Bit #(1)  sdram_dq_oe    = mem.sdram_dq_oe;

   method Action sdram_dq_in (Bit #(16) v);
      mem.sdram_dq_in (v);
   endmethod
endmodule

endpackage
