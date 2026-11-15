// ================================================================
// UART_Pins: bridge between Flute's UART byte streams
// (Get/Put of Bit#(8)) and physical TXD/RXD pins, 8N1, one stop
// bit, mid-bit sampling on RX.  Timing constants come from the
// proven bluespec-ulx3s design (217 clocks/bit at 25 MHz/115200).
//
// Trace port (always present, unconnected in the SoC; formal/fv/ips/uart_pins specifies it):
// tr_tx_load (a byte leaves the TX FIFO: its start bit goes out), tr_tx_done (its stop bit ends);
// tr_rx_start (a low line taken in idle), tr_rx_glitch (the start sample is high: back to idle),
// tr_rx_bit (a data sample), tr_rx_byte (a stop sample high: the byte, queued or dropped),
// tr_rx_ferr (a stop sample low), tr_rx_ovf (a byte dropped on a full RX FIFO).
// ================================================================

package Uart_Pins;

export UART_Pins_IFC (..), mkUART_Pins;

import Vector :: *;
import FIFOF  :: *;
import GetPut :: *;

// ================================================================

interface UART_Pins_IFC;
   interface Put #(Bit #(8)) put;    // bytes to transmit
   interface Get #(Bit #(8)) get;    // bytes received

   (* always_ready *)   method Bit #(1) txd;
   (* always_enabled *) method Action rxd (Bit #(1) v);

   (* always_ready *) method Bool rx_overflow;
   (* always_ready *) method Bool rx_frame_err;
   (* always_ready *) method Bool tx_busy;

   // trace port
   (* always_ready *) method Maybe #(Bit #(8)) tr_tx_load;
   (* always_ready *) method Bool              tr_tx_done;
   (* always_ready *) method Bool              tr_rx_start;
   (* always_ready *) method Bool              tr_rx_glitch;
   (* always_ready *) method Maybe #(Bit #(1)) tr_rx_bit;
   (* always_ready *) method Maybe #(Bit #(8)) tr_rx_byte;
   (* always_ready *) method Bool              tr_rx_ferr;
   (* always_ready *) method Bool              tr_rx_ovf;
endinterface

// ================================================================

typedef enum {RX_IDLE, RX_START, RX_DATA, RX_STOP} RX_State deriving (Bits, Eq);

module mkUART_Pins #(Integer clk_hz, Integer baud) (UART_Pins_IFC);

   Integer clk_per_bit = clk_hz / baud;    // 217

   // TX
   FIFOF #(Bit #(8)) f_tx <- mkSizedFIFOF (16);
   Reg #(Bool)      rg_tx_busy <- mkReg (False);
   Reg #(Bit #(16)) rg_tx_cnt   <- mkReg (0);
   Reg #(Bit #(4))  rg_tx_bit   <- mkReg (0);    // next bit of the 10-bit frame
   Reg #(Bit #(10)) rg_tx_sh    <- mkReg (10'h3FF);
   Reg #(Bit #(1))  rg_txd      <- mkReg (1);

   // RX
   FIFOF #(Bit #(8)) f_rx <- mkSizedFIFOF (16);
   Reg #(Bit #(1))  rg_rx_in     <- mkReg (1);
   Reg #(Bit #(1))  rg_rx_meta   <- mkReg (1);
   Reg #(Bit #(1))  rg_rx_sync   <- mkReg (1);
   Reg #(RX_State)  rg_rx_state  <- mkReg (RX_IDLE);
   Reg #(Bit #(16)) rg_rx_cnt    <- mkReg (0);
   Reg #(Bit #(3))  rg_rx_bit    <- mkReg (0);
   Reg #(Bit #(8))  rg_rx_sh     <- mkReg (0);
   Reg #(Bool)      rg_overflow  <- mkReg (False);
   Reg #(Bool)      rg_frame_err <- mkReg (False);

   // trace port
   RWire #(Bit #(8)) rw_tx_load   <- mkRWire;
   PulseWire         pw_tx_done   <- mkPulseWire;
   PulseWire         pw_rx_start  <- mkPulseWire;
   PulseWire         pw_rx_glitch <- mkPulseWire;
   RWire #(Bit #(1)) rw_rx_bit    <- mkRWire;
   RWire #(Bit #(8)) rw_rx_byte   <- mkRWire;
   PulseWire         pw_rx_ferr   <- mkPulseWire;
   PulseWire         pw_rx_ovf    <- mkPulseWire;

   // ----------------------------------------------------------------
   // TX: rg_tx_sh = {stop, data[7:0], start}; rg_tx_bit is the index
   // of the bit currently on the wire (0 = start, driven on load).

   rule rl_tx_load (! rg_tx_busy && f_tx.notEmpty);
      f_tx.deq;
      rg_tx_sh   <= {1'b1, f_tx.first, 1'b0};
      rg_tx_busy <= True;
      rg_tx_bit  <= 0;
      rg_tx_cnt  <= 0;
      rg_txd     <= 0;                       // start bit
      rw_tx_load.wset (f_tx.first);
`ifdef UART_PROBES
      $display ("[uart] txload %02x", f_tx.first);
`endif
   endrule

   rule rl_tx_shift (rg_tx_busy);
      if (rg_tx_cnt == fromInteger (clk_per_bit - 1)) begin
         rg_tx_cnt <= 0;
         Vector #(10, Bit #(1)) v_sh = unpack (rg_tx_sh);
         if (rg_tx_bit == 9) begin           // stop bit finished
            rg_tx_busy <= False;
            rg_txd     <= 1;
            pw_tx_done.send;
`ifdef UART_PROBES
            $display ("[uart] txdone");
`endif
         end
         else begin
            rg_txd    <= v_sh [rg_tx_bit + 1];
            rg_tx_bit <= rg_tx_bit + 1;
         end
      end
      else
         rg_tx_cnt <= rg_tx_cnt + 1;
   endrule

   // ----------------------------------------------------------------
   // RX

   rule rl_rx;
      // Synchronize the asynchronous input
      rg_rx_meta <= rg_rx_in;
      rg_rx_sync <= rg_rx_meta;

      case (rg_rx_state)

         RX_IDLE: begin
            if (rg_rx_sync == 0) begin
               rg_rx_state <= RX_START;
               rg_rx_cnt   <= 0;
               pw_rx_start.send;
            end
         end

         RX_START: begin
            if (rg_rx_cnt == fromInteger (clk_per_bit / 2)) begin
               rg_rx_cnt <= 0;
               if (rg_rx_sync == 0) begin
                  rg_rx_state <= RX_DATA;
                  rg_rx_bit   <= 0;
               end
               else begin
                  rg_rx_state <= RX_IDLE;    // glitch
                  pw_rx_glitch.send;
               end
            end
            else
               rg_rx_cnt <= rg_rx_cnt + 1;
         end

         RX_DATA: begin
            if (rg_rx_cnt == fromInteger (clk_per_bit - 1)) begin
               rg_rx_cnt <= 0;
               rg_rx_sh  <= {rg_rx_sync, rg_rx_sh [7:1]};
               rw_rx_bit.wset (rg_rx_sync);
               if (rg_rx_bit == 7)
                  rg_rx_state <= RX_STOP;
               else
                  rg_rx_bit <= rg_rx_bit + 1;
            end
            else
               rg_rx_cnt <= rg_rx_cnt + 1;
         end

         RX_STOP: begin
            if (rg_rx_cnt == fromInteger (clk_per_bit - 1)) begin
               rg_rx_cnt   <= 0;
               rg_rx_state <= RX_IDLE;
               if (rg_rx_sync == 1) begin
                  rw_rx_byte.wset (rg_rx_sh);
                  if (f_rx.notFull)
                     f_rx.enq (rg_rx_sh);
                  else begin
                     rg_overflow <= True;
                     pw_rx_ovf.send;
                  end
               end
               else begin
                  rg_frame_err <= True;
                  pw_rx_ferr.send;
               end
            end
            else
               rg_rx_cnt <= rg_rx_cnt + 1;
         end

      endcase
   endrule

   // ----------------------------------------------------------------
   // INTERFACE

   interface Put put = toPut (f_tx);
   interface Get get = toGet (f_rx);

   method Bit #(1) txd = rg_txd;

   method Action rxd (Bit #(1) v);
      rg_rx_in <= v;
   endmethod

   method Bool rx_overflow  = rg_overflow;
   method Bool rx_frame_err = rg_frame_err;
   method Bool tx_busy      = rg_tx_busy;

   method tr_tx_load   = rw_tx_load.wget;
   method tr_tx_done   = pw_tx_done;
   method tr_rx_start  = pw_rx_start;
   method tr_rx_glitch = pw_rx_glitch;
   method tr_rx_bit    = rw_rx_bit.wget;
   method tr_rx_byte   = rw_rx_byte.wget;
   method tr_rx_ferr   = pw_rx_ferr;
   method tr_rx_ovf    = pw_rx_ovf;
endmodule

endpackage
