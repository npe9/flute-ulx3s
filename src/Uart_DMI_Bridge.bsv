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
// appears, bytes pass straight through to the console.  Pass-through
// is LOSSLESS: on a partial magic match followed by a mismatch, the
// buffered candidate bytes (including the 0xDB itself) are replayed
// ahead of the stream (they are constants, see fn_magic).  This
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
// Scheduling note: the rx_from_uart put-method is the sole writer of
// f_replay (pass-through queue) and never touches f_console; a single
// feeder rule owns f_console.  All FIFO/FIFOF writes from rules have
// exactly one writer per FIFO.  This keeps the BSV scheduler happy.
// ================================================================

package Uart_DMI_Bridge;

export Uart_DMI_Bridge_IFC (..), mkUart_DMI_Bridge;

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
endinterface

// ----------------------------------------------------------------

typedef enum {ST_HUNT, ST_MAGIC, ST_FRAME,
              ST_DMI_SETUP, ST_DMI_PULSE, ST_DMI_WAIT}
   State deriving (Bits, Eq);

Integer timeout_cycles       = 50_000_000;    // >=1 s at any sys_clk up to 50 MHz (armed)
Integer magic_timeout_cycles = 500_000;       // ~10-40 ms (partial magic match)

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

(* synthesize *)
module mkUart_DMI_Bridge (Uart_DMI_Bridge_IFC);

   // DMI <-> Control_Req conversion, reused from the JTAG path.
   Jtag_Control_Adapter_IFC adapter <- mkJtag_Control_Adapter;

   // Pass-through queue: sole writer is the rx_from_uart method; sole
   // reader is rl_feed.  Decouples the tap from console FIFO fullness.
   FIFOF #(Bit #(8)) f_replay <- mkSizedFIFOF (16);

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

   // Partial-magic replay: rg_replay_n bytes fn_magic(rg_replay_pos),
   // fn_magic(rg_replay_pos+1), ... still owed to the console.
   Reg #(Bit #(4))  rg_replay_n    <- mkReg (0);
   Reg #(Bit #(4))  rg_replay_pos <- mkReg (1);

   // Response sources, drained by a single rule into f_rsp.
   Reg #(Bool)        rg_dmi_rsp_v <- mkReg (False);
   Reg #(Bit #(40))   rg_dmi_rsp   <- mkRegU;
   Reg #(Maybe #(Bit #(40))) rg_rsp_req <- mkReg (Invalid);

   // ----------------------------------------------------------------
   // Console feeder: replayed partial-magic prefix bytes first, then
   // the pass-through queue.
   rule rl_feed (f_console.notFull);
      if (rg_replay_n != 0) begin
         f_console.enq (fn_magic (rg_replay_pos));
         rg_replay_pos <= rg_replay_pos + 1;
         rg_replay_n   <= rg_replay_n - 1;
      end
      else if (f_replay.notEmpty) begin
         f_console.enq (f_replay.first);
         f_replay.deq;
      end
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
         if ((rg_state == ST_MAGIC) && (rg_replay_n == 0)) begin
            rg_replay_n   <= rg_sync_idx;
            rg_replay_pos <= 0;
         end
         rg_sync_idx <= 0;
         rg_state    <= ST_HUNT;
      end
      else if (rg_replay_n == 0)
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
              end
              else if (f_replay.notFull)
                 f_replay.enq (b);
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
                 // Mismatch: replay the buffered prefix bytes
                 // fn_magic(0..rg_sync_idx-1) through rl_feed -- they
                 // are constants, and the replay MUST include the 0xDB
                 // itself or every bare 0xDB in a binary load is
                 // silently dropped (one-byte stream shift).  Guard
                 // against clobbering an in-flight replay (unreachable
                 // at UART byte spacing, but cheap to be safe).
                 if (rg_replay_n == 0) begin
                    rg_replay_n   <= rg_sync_idx;
                    rg_replay_pos <= 0;
                 end
                 if (b == fn_magic (0)) begin
                    rg_sync_idx <= 1;
                    rg_state    <= ST_MAGIC;
                 end
                 else begin
                    rg_sync_idx <= 0;
                    rg_state    <= ST_HUNT;
                    if (f_replay.notFull)
                       f_replay.enq (b);
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
                    end
                    default:
                       rg_rsp_req <= tagged Valid ({8'h02, 32'h0});    // unknown op
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

endmodule

endpackage
