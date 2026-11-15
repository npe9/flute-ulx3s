// ================================================================
// Uart_DMI_Bridge
//
// Debug transport for Flute's RISC-V Debug Module over the existing
// FTDI UART -- no extra pins, no external adapter.
//
// The bridge taps the RX byte stream on its way to the SoC console
// (16550).  Until the 8-byte magic sequence
//
//    DB 53 44 4D 01 02 03 04    ("\xDBSDM\x01\x02\x03\x04")
//
// appears, bytes pass straight through to the console, in order.
// Pass-through is LOSSLESS (unless 16 tokens already wait for a full
// console): on a partial magic match followed by a mismatch, the
// buffered candidate bytes (including the 0xDB itself) are given back
// in place (they are constants, see fn_magic).  This
// matters because the binary UART bootloader image contains ~11k
// 0xDB bytes; an earlier drop-on-mismatch design ate one byte per
// occurrence and corrupted every kernel load.
//
// A partial match also has a ~10 ms RX-idle timeout (ST_MAGIC): a
// 0xDB that is NOT followed by the rest of the magic -- e.g. a
// trailing checksum byte -- is released to the console rather than
// held hostage.  10 ms is ~600x the 16 us UART byte spacing (far
// above USB burst jitter, so a genuine magic still arms) yet well
// under the boot ROM's ~48 ms receive watchdogs.
//
// Once armed, bytes are consumed as fixed 6-byte requests:
//
//    [op, dmi_addr, data(4, big-endian)]
//
//    op = 'r' (0x72): DMI read at dmi_addr
//    op = 'w' (0x77): DMI write dmi_addr <- data
//    op = 'q' (0x71): disarm, resume console pass-through
//
// Each request produces a fixed 6-byte response framed with a 0xDB
// marker byte so the host can resynchronize past any console output
// that flushed ahead of it:
//
//    [0xDB, status, data(4, big-endian)]
//
//    status 0 = ok (data = DMI read value; zeros for writes/'q')
//    status 2 = unknown op (bridge stays armed; framing is preserved
//               because requests are fixed length)
//
// DMI transactions are issued by driving the slave side of the
// existing Jtag_Control_Adapter, so requests reach Flute's Debug
// Module (SoC_Top.server_external_control -> core.dm_dmi) exactly as
// they would over JTAG:
//
//    dmcontrol 0x10 / dmstatus 0x11   halt, resume, ndmreset
//    command 0x17 / data0 0x04        abstract register cmds (x0-x31,
//                                     CSRs incl. dpc 0x7b1)
//    sbcs 0x38 .. sbdata0 0x3c        system bus memory peek/poke
//
// A ~1 s RX-idle timeout while armed disarms the bridge so a
// disconnected or crashed host cannot wedge the console path.
//
// Scheduling note: f_replay (the pass-through token queue) is written
// by the rx_from_uart put-method and by rl_timeout (which the method
// pre-empts: a byte resets the idle timer anyway); a single feeder
// rule owns f_console.  formal/fv/ips/uart_dmi specifies the bridge.
// ================================================================

package Uart_DMI_Bridge;

export Uart_DMI_Bridge_IFC (..), mkUart_DMI_Bridge, mkUart_DMI_Bridge_P;

import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;

import Jtag_IFC             :: *;    // DMI_IFC
import Jtag_Control_Adapter :: *;    // reused for DMI <-> Control_Req
import External_Control     :: *;    // Control_Req / Control_Rsp

// ----------------------------------------------------------------

interface Uart_DMI_Bridge_IFC;
   // Tap: byte stream from the physical UART receiver.
   interface Put #(Bit #(8)) rx_from_uart;

   // Bytes forwarded on to the SoC console (only while not armed).
   interface Get #(Bit #(8)) rx_to_console;

   // Debug response bytes to transmit on the UART.
   interface Get #(Bit #(8)) dbg_tx;
   (* always_ready *) method Bool dbg_tx_pending;

   // Toward SoC_Top.server_external_control.
   interface Client #(Control_Req, Control_Rsp) client;

   // Trace port (always present, unconnected in the SoC; formal/fv/ips/uart_dmi specifies it):
   // tr_feed (a byte enters the console FIFO), tr_drop (a pass-through token dropped: f_replay
   // full), tr_rsp_lost (a 'q' / unknown-op response overwritten before issue), tr_timeout (an idle
   // timeout: partial match or armed), tr_dmi_done (a DMI response taken: armed again).
   (* always_ready *) method Maybe #(Bit #(8)) tr_feed;
   (* always_ready *) method Bool tr_drop;
   (* always_ready *) method Bool tr_rsp_lost;
   (* always_ready *) method Bool tr_timeout;
   (* always_ready *) method Bool tr_dmi_done;
endinterface

// ----------------------------------------------------------------

typedef enum {ST_HUNT, ST_MAGIC, ST_FRAME,
              ST_DMI_SETUP, ST_DMI_PULSE, ST_DMI_WAIT}
   State deriving (Bits, Eq);


function Bit #(8) fn_magic (Bit #(4) i);
   case (i)
      0: return 8'hDB;
      1: return 8'h53;    // 'S'
      2: return 8'h44;    // 'D'
      3: return 8'h4D;    // 'M'
      4: return 8'h01;
      5: return 8'h02;
      6: return 8'h03;
      default: return 8'h04;
   endcase
endfunction

Bit #(2) dmi_op_read  = 1;
Bit #(2) dmi_op_write = 2;

// ----------------------------------------------------------------

// The SoC's bridge: timeouts >=1 s armed at any sys_clk up to 50 MHz, ~10-40 ms on a partial
// magic match.  (formal/fv instantiates mkUart_DMI_Bridge_P with short timeouts as well.)
(* synthesize *)
module mkUart_DMI_Bridge (Uart_DMI_Bridge_IFC);
   let m <- mkUart_DMI_Bridge_P (50_000_000, 500_000);
   return m;
endmodule

module mkUart_DMI_Bridge_P #(Integer timeout_cycles, Integer magic_timeout_cycles)
                           (Uart_DMI_Bridge_IFC);

   // DMI <-> Control_Req conversion, reused from the JTAG path.
   Jtag_Control_Adapter_IFC adapter <- mkJtag_Control_Adapter;

   // Pass-through queue of tokens {k, has, b}: the magic prefix fn_magic(0..k-1), then b if has.
   // Writers: the rx_from_uart method (a byte; a mismatch's prefix and byte) and rl_timeout (a
   // timed-out prefix); reader: rl_feed.  One queue keeps the console stream in arrival order:
   // a prefix given back after a mismatch follows the bytes queued before it, even when the
   // console FIFO is full (a separate replay counter, fed first, once let it jump ahead).
   FIFOF #(Bit #(13)) f_replay <- mkSizedFIFOF (16);
   Reg #(Bit #(4))    rg_feed_pos <- mkReg (0);    // bytes of f_replay.first already fed

   // Console byte FIFO: sole writer is rl_feed.
   FIFOF #(Bit #(8)) f_console <- mkSizedFIFOF (32);

   // Response records {status, data} and the TX byte stream.
   FIFOF #(Bit #(40)) f_rsp    <- mkSizedFIFOF (4);
   FIFOF #(Bit #(8))  f_dbg_tx <- mkSizedFIFOF (8);

   Reg #(State)     rg_state     <- mkReg (ST_HUNT);
   Reg #(Bit #(4))  rg_sync_idx  <- mkReg (0);
   Reg #(Bit #(3))  rg_cnt       <- mkReg (0);    // frame byte 0..5
   Reg #(Bit #(8))  rg_op        <- mkReg (0);
   Reg #(Bit #(7))  rg_addr      <- mkReg (0);
   Reg #(Bit #(32)) rg_data      <- mkRegU;    // E38b: frame data, not reset
   Reg #(Bit #(2))  rg_dmi_op    <- mkReg (0);
   Reg #(Bit #(26)) rg_idle_cnt  <- mkReg (0);

   // Response sources, drained by a single rule into f_rsp.
   Reg #(Bool)        rg_dmi_rsp_v <- mkReg (False);
   Reg #(Bit #(40))   rg_dmi_rsp   <- mkRegU;
   Reg #(Maybe #(Bit #(40))) rg_rsp_req <- mkReg (Invalid);

   // trace port
   RWire #(Bit #(8)) rw_feed        <- mkRWire;
   PulseWire         pw_drop        <- mkPulseWire;
   PulseWire         pw_rsp_lost    <- mkPulseWire;
   PulseWire         pw_timeout     <- mkPulseWire;
   PulseWire         pw_dmi_done    <- mkPulseWire;

   // ----------------------------------------------------------------
   // Console feeder: one byte per clock from the head token, prefix first.  (It once fired on
   // every clock the console had room and, sharing registers with rl_timeout and more urgent,
   // kept both idle timeouts from ever firing; formal/fv/uart_dmi found it.  It now shares
   // nothing with rl_timeout but f_replay, whose enq and deq do not conflict.)
   rule rl_feed (f_console.notFull && f_replay.notEmpty);
      Bit #(4) k   = f_replay.first [12:9];
      Bool     has = f_replay.first [8] == 1;
      Bit #(8) v   = (rg_feed_pos < k) ? fn_magic (rg_feed_pos) : f_replay.first [7:0];
      f_console.enq (v);
      rw_feed.wset (v);
      if (rg_feed_pos + 1 == k + (has ? 1 : 0)) begin
         f_replay.deq;
         rg_feed_pos <= 0;
      end
      else
         rg_feed_pos <= rg_feed_pos + 1;
   endrule

   // ----------------------------------------------------------------
   // Armed idle timeouts.
   //  - ST_FRAME: ~1 s, so a crashed/disconnected host cannot wedge the
   //    console path (pre-existing behaviour).
   //  - ST_MAGIC: ~10 ms.  A 0xDB not followed by the rest of the magic
   //    (a binary kernel byte, a checksum) must be released to the
   //    console quickly; the boot ROM's receive watchdogs run at ~48 ms.
   //    10 ms is ~600x the 16 us UART byte spacing, so a genuine magic
   //    (one burst) still arms.  On timeout the matched prefix --
   //    including the 0xDB itself -- is replayed to the console.
   rule rl_timeout ((rg_state == ST_FRAME) || (rg_state == ST_MAGIC));
      let lim = (rg_state == ST_FRAME)
                ? fromInteger (timeout_cycles - 1)
                : fromInteger (magic_timeout_cycles - 1);
      if (rg_idle_cnt >= lim) begin
         // a partial match gives its prefix back (waiting, if the queue is full, for room)
         if (rg_state == ST_MAGIC) f_replay.enq ({rg_sync_idx, 1'b0, 8'h00});
         rg_sync_idx <= 0;
         rg_state    <= ST_HUNT;
         rg_idle_cnt <= 0;    // or the next partial match would time out at once
         pw_timeout.send;
      end
      else
         rg_idle_cnt <= rg_idle_cnt + 1;
   endrule

   // DMI request: present addr/data/op, then pulse valid one cycle
   // later (Jtag_Control_Adapter latches them into regs on the
   // req_addr/req_data/req_op methods and captures those regs, not the
   // method arguments, on req_valid).
   rule rl_dmi_setup (rg_state == ST_DMI_SETUP);
      if (adapter.dmi.req_ready == 1) begin
         adapter.dmi.req_addr (rg_addr);
         adapter.dmi.req_data (rg_data);
         adapter.dmi.req_op   (rg_dmi_op);
         rg_state <= ST_DMI_PULSE;
      end
   endrule

   rule rl_dmi_pulse (rg_state == ST_DMI_PULSE);
      if (adapter.dmi.req_ready == 1) begin
         adapter.dmi.req_valid (1);
         rg_state <= ST_DMI_WAIT;
      end
   endrule

   rule rl_dmi_wait (rg_state == ST_DMI_WAIT);
      if ((adapter.dmi.rsp_valid == 1) && ! rg_dmi_rsp_v) begin
         rg_dmi_rsp   <= {8'h00, adapter.dmi.rsp_data};
         rg_dmi_rsp_v <= True;
         adapter.dmi.rsp_ready (1);
         pw_dmi_done.send;
         rg_state    <= ST_FRAME;
         rg_cnt      <= 0;
         rg_idle_cnt <= 0;
      end
   endrule

   // Single writer into f_rsp: DMI responses have priority over
   // put-method responses (only one is ever actually pending).
   rule rl_rsp_issue_dmi (rg_dmi_rsp_v && f_rsp.notFull);
      f_rsp.enq (rg_dmi_rsp);
      rg_dmi_rsp_v <= False;
   endrule

   rule rl_rsp_issue_req (isValid (rg_rsp_req) && ! rg_dmi_rsp_v
                          && f_rsp.notFull);
      f_rsp.enq (fromMaybe (?, rg_rsp_req));
      rg_rsp_req <= Invalid;
   endrule

   // Response byte emitter: load a record into a shift register, then
   // push one byte per cycle onto the TX stream.  The 0xDB marker
   // prefix lets the host resynchronize past any console output that
   // was already queued ahead of the response.
   Reg #(Bit #(48)) rg_tx_shift <- mkRegU;
   Reg #(Bit #(3))  rg_tx_cnt   <- mkReg (0);

   rule rl_tx_load ((rg_tx_cnt == 0) && f_rsp.notEmpty);
      rg_tx_shift <= {8'hDB, f_rsp.first};
      f_rsp.deq;
      rg_tx_cnt   <= 6;
   endrule

   rule rl_tx_byte ((rg_tx_cnt != 0) && f_dbg_tx.notFull);
      f_dbg_tx.enq (rg_tx_shift [47:40]);
      rg_tx_shift <= {rg_tx_shift [39:0], 8'h00};
      rg_tx_cnt   <= rg_tx_cnt - 1;
   endrule

   // ----------------------------------------------------------------
   // INTERFACE

   interface Put rx_from_uart;
      method Action put (Bit #(8) b);
         case (rg_state)

           ST_HUNT: begin
              if (b == fn_magic (0)) begin
                 rg_sync_idx <= 1;
                 rg_state    <= ST_MAGIC;
                 rg_idle_cnt <= 0;    // the idle timer runs from this byte
              end
              else if (f_replay.notFull)
                 f_replay.enq ({4'd0, 1'b1, b});
              else
                 pw_drop.send;
              // pass-through queue full: drop the byte (would need the
              // CPU to have stopped reading the console for a long
              // while; the 16-deep queue drains in microseconds).
           end

           ST_MAGIC: begin
              rg_idle_cnt <= 0;    // byte arrived: reset the idle timer
              if (b == fn_magic (rg_sync_idx)) begin
                 if (rg_sync_idx == 7) begin
                    rg_state <= ST_FRAME;
                    rg_cnt   <= 0;
                 end
                 else
                    rg_sync_idx <= rg_sync_idx + 1;
              end
              else begin
                 // Mismatch: give back the buffered prefix bytes
                 // fn_magic(0..rg_sync_idx-1) -- they are constants, and
                 // the replay MUST include the 0xDB itself or every bare
                 // 0xDB in a binary load is silently dropped (one-byte
                 // stream shift) -- then the byte, unless it is a 0xDB
                 // (which starts a new match).  One token, in order.
                 Bool again = (b == fn_magic (0));
                 if (f_replay.notFull)
                    f_replay.enq ({rg_sync_idx, again ? 1'b0 : 1'b1, b});
                 else
                    pw_drop.send;
                 if (again) begin
                    rg_sync_idx <= 1;
                    rg_state    <= ST_MAGIC;
                 end
                 else begin
                    rg_sync_idx <= 0;
                    rg_state    <= ST_HUNT;
                 end
              end
           end

           ST_FRAME: begin
              rg_idle_cnt <= 0;
              case (rg_cnt)
                 0: rg_op <= b;
                 1: rg_addr <= truncate (b);
                 default: rg_data <= {rg_data [23:0], b};    // big-endian
              endcase
              if (rg_cnt == 5) begin
                 rg_cnt <= 0;
                 case (rg_op)
                    8'h72: begin    // 'r'
                       rg_dmi_op <= dmi_op_read;
                       rg_state  <= ST_DMI_SETUP;
                    end
                    8'h77: begin    // 'w'
                       rg_dmi_op <= dmi_op_write;
                       rg_state  <= ST_DMI_SETUP;
                    end
                    8'h71: begin    // 'q': disarm
                       rg_state  <= ST_HUNT;
                       rg_rsp_req <= tagged Valid ({8'h00, 32'h0});
                       if (isValid (rg_rsp_req)) pw_rsp_lost.send;
                    end
                    default: begin
                       rg_rsp_req <= tagged Valid ({8'h02, 32'h0});    // unknown op
                       if (isValid (rg_rsp_req)) pw_rsp_lost.send;
                    end
                 endcase
              end
              else
                 rg_cnt <= rg_cnt + 1;
           end

           default: begin
              // DMI transaction in flight; host protocol violation.
              // Drop the byte to keep the framing aligned.
           end
         endcase
      endmethod
   endinterface

   interface Get rx_to_console = toGet (f_console);

   interface Get dbg_tx = toGet (f_dbg_tx);

   method Bool dbg_tx_pending = f_dbg_tx.notEmpty || (rg_tx_cnt != 0);

   interface Client client = adapter.client;

   method tr_feed        = rw_feed.wget;
   method tr_drop        = pw_drop;
   method tr_rsp_lost    = pw_rsp_lost;
   method tr_timeout     = pw_timeout;
   method tr_dmi_done    = pw_dmi_done;

endmodule

endpackage
