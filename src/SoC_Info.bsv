// ================================================================
// SoC_Info: self-describing SoC register block (4 KB MMIO region).
//
// Lets software DISCOVER the hardware at runtime instead of trusting
// baked-in constants: magic/version/build, clock, memory size, a
// features bitmask, and a device descriptor ROM generated at
// elaboration time from the SAME declarative table the AXI fabric
// decodes (SoC_Map.fn_soc_memmap) -- so the software-visible device
// list cannot drift from the address decoder.
//
// Address map (32-bit registers at 4-byte offsets from base):
//   0x000  SOC_MAGIC        0x464C5331 ("FLS1")
//   0x004  SOC_VERSION      hardware ABI version (1)
//   0x008  SOC_BUILD_DATE   YYYYMMDD from -D SOC_BUILD_DATE (0 if absent)
//   0x00C  SOC_FEATURES     feature bitmask (see below)
//   0x010  SOC_CPU_HZ
//   0x014  SOC_TIMER_HZ
//   0x018  SOC_MEMORY_SIZE  bytes of main memory
//   0x01C  SOC_DEVICE_COUNT
//   0x020  SOC_DEVICE_TABLE byte offset of the descriptor ROM (0x100)
//   0x024  SOC_RESET_REASON 0 until the watchdog/reset controller lands
//   0x028  BUSERR_STATUS    bit0 captured, bit1 is_write, bits[15:8]
//                           master, bits[17:16] resp
//   0x02C  BUSERR_COUNT     saturating decode-error count
//   0x030  BUSERR_ADDR_LO   first captured error address (frozen)
//   0x034  BUSERR_ADDR_HI
//   0x038  BUSERR_ID        AXI transaction id
//   0x03C  BUSERR_CLEAR     write anything to clear count + capture
//   0x040..0x04C  PERF_SELECT_0..3  RW: event code for counter 0..3
//   0x080..0x08C  PERF_COUNT_0..3   RO: counter value; write anything to clear
//   0x100.. device records, 8 x u32 each:
//          type(=DeviceId), version, base, size, irq(0xFF=none), flags,
//          rsvd, rsvd
//          flags: bit0 = decoded by AXI fabric; bits[3:1] bus
//                 (0=axi, 1=near_mem, 2=reserved)
// FEATURES bits: 0 uart0, 1 gpio, 2 clint, 3 soc_info, 4 buserr_mon,
//                5 trace, 6 watchdog, 7 perf, 8 dma (5-8: reserved/future).
// PERF event codes (PERF_SELECT value):
//   0 cycles (free-running)   1 retired instructions
//   2 I-cache refills         3 D-cache refills
//   4 external interrupts     5 UART0 interrupts
//   6 branch redirects        7 bus decode errors
//   (8..15 reserved: counter frozen)
// Reads only; writes to SELECT/clear are handled, others return OKAY and
// are ignored.
// ================================================================

package SoC_Info;

export SoC_Info_IFC (..), mkSoC_Info;

import Vector      :: *;
import RegFile      :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;
import Cur_Cycle    :: *;
import GetPut_Aux   :: *;
import Semi_FIFOF   :: *;
import List         :: *;

import AXI4_Types   :: *;
import AXI4_Xactors :: *;
import Fabric_Defs  :: *;
import SoC_Map      :: *;    // MemRegion, fn_soc_memmap, DeviceId

// ================================================================

interface SoC_Info_IFC;
   method Action init (Bit #(Wd_Id) axi4_id, Bit #(Wd_Addr) addr_base, Bit #(Wd_Addr) addr_lim);
   interface AXI4_Slave_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) slave;
   // Bus-error monitor feed (from the AXI fabric's decode-error events).
   method Action note_err (BusErrEvent e);
   // Performance-monitoring event pulses (one cycle each; producers are
   // wired up in SoC_Top).  Each note method may be called at most once
   // per cycle (enforced by the compiler for same-method conflicts; the
   // events are rare enough that this always holds).
   method Action note_retire;
   method Action note_imiss;
   method Action note_dmiss;
   method Action note_ext_irq;
   method Action note_uart_irq;
   method Action note_redirect;
endinterface

// ================================================================

Bit #(32) soc_magic = 32'h464C_5331;    // "FLS1"

(* synthesize *)
module mkSoC_Info #(int clk_hz) (SoC_Info_IFC);

   Reg #(Bit #(Wd_Addr)) rg_addr_base <- mkRegU;
   Reg #(Bit #(Wd_Addr)) rg_addr_lim  <- mkRegU;

   AXI4_Slave_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) slave_xactor <- mkAXI4_Slave_Xactor;

   // ---- elaboration-time constants -------------------------------------

   // Features bitmask: bits for what this elaboration actually contains.
`ifdef INCLUDE_ACCEL0
   Bit #(32) feat_gpio = 32'h2;
`else
   Bit #(32) feat_gpio = 0;
`endif
   // uart0 | gpio | clint (near-mem) | soc_info (self) | bus error monitor |
   // perf counters; bits 5,6,8 (trace, watchdog, dma) read 0 until built.
   Bit #(32) features = 32'h0000_009D | feat_gpio;

`ifdef SOC_BUILD_DATE
   Bit #(32) build_date = `SOC_BUILD_DATE;
`else
   Bit #(32) build_date = 0;
`endif

   Integer n_devices = List::length (fn_soc_memmap ());

   // ---- bus error capture ------------------------------------------------
   // Count saturates; the FIRST error's details are frozen until cleared
   // (write anything to BUSERR_CLEAR, offset 0x03C).

   Reg #(Bit #(32)) rg_err_count  <- mkReg (0);
   Reg #(Bool)      rg_err_valid  <- mkReg (False);
   Reg #(Bit #(64)) rg_err_addr   <- mkReg (0);
   Reg #(Bool)      rg_err_iswr   <- mkReg (False);
   Reg #(Bit #(8))  rg_err_master <- mkReg (0);
   Reg #(Bit #(2))  rg_err_resp   <- mkReg (0);

   // ---- performance counters ------------------------------------------
   // Four independent 32-bit saturating counters.  Each counter counts the
   // event selected by its PERF_SELECT register (codes in the header
   // comment above).  Event pulses arrive via PulseWires fed by the
   // note_* methods below.

   Reg #(Vector #(4, Bit #(4)))  rg_perf_select <- mkReg (replicate (0));
   Reg #(Vector #(4, Bit #(32))) rg_perf_count  <- mkReg (replicate (0));

   PulseWire pw_retire    <- mkPulseWire;
   PulseWire pw_imiss     <- mkPulseWire;
   PulseWire pw_dmiss     <- mkPulseWire;
   PulseWire pw_ext_irq   <- mkPulseWire;
   PulseWire pw_uart_irq  <- mkPulseWire;
   PulseWire pw_redirect  <- mkPulseWire;
   PulseWire pw_buserr    <- mkPulseWire;

   // Cross-rule channel for register writes issued by rl_wr (below).
   // rg_perf_select / rg_perf_count are written ONLY by rl_perf_count;
   // rl_wr signals updates through these wires.  (Two rules writing the
   // same register starve the lower-urgency one -- that silently wedged
   // every write to this slave once rl_perf_count fired every cycle.)
   RWire #(Tuple2 #(Bit #(2), Bit #(4))) rw_sel_wr  <- mkRWire;
   RWire #(Bit #(2))                     rw_cnt_clr <- mkRWire;

   rule rl_perf_count;
      Vector #(4, Bit #(4))  new_sels   = rg_perf_select;
      Vector #(4, Bit #(32)) new_counts = rg_perf_count;
      Maybe #(Bit #(2)) m_clr = rw_cnt_clr.wget;
      if (rw_sel_wr.wget matches tagged Valid {.i, .v})
	 new_sels [i] = v;
      if (m_clr matches tagged Valid .clr_idx)
	 new_counts [clr_idx] = 0;
      for (Integer i = 0; i < 4; i = i + 1) begin
	 let sel = rg_perf_select [i];
	 Bool fire = (sel == 0)                                  // cycles
		     || ((sel == 1) && pw_retire)
		     || ((sel == 2) && pw_imiss)
		     || ((sel == 3) && pw_dmiss)
		     || ((sel == 4) && pw_ext_irq)
		     || ((sel == 5) && pw_uart_irq)
		     || ((sel == 6) && pw_redirect)
		     || ((sel == 7) && pw_buserr);
	 Bool clr_this = (m_clr == tagged Valid fromInteger (i));
	 if (fire && (rg_perf_count [i] != 32'hFFFF_FFFF) && (! clr_this))
	    new_counts [i] = rg_perf_count [i] + 1;
      end
      rg_perf_select <= new_sels;
      rg_perf_count  <= new_counts;
   endrule

   // ---- device descriptor ROM (combinational walk of the table) --------

   function Bit #(32) fn_devrom_field (MemRegion r, Bit #(32) f);
      if (f == 0)      return zeroExtend (pack (r.device));
      else if (f == 1) return 1;                          // record version
      else if (f == 2) return r.base;
      else if (f == 3) return r.size;
      else if (f == 4) return r.irq;
      else if (f == 5) return r.flags;
      else             return 0;
   endfunction

   function Bit #(32) fn_devrom_walk (Bit #(32) idx, List #(MemRegion) rs);
      if (List::isNull (rs))
         return 0;
      else if (idx < 8)
         return fn_devrom_field (List::head (rs), idx);
      else
         return fn_devrom_walk (idx - 8, List::tail (rs));
   endfunction

   // u32 index within the ROM (each record = 8 u32)
   function Bit #(32) fn_devrom (Bit #(32) u32_idx);
      return fn_devrom_walk (u32_idx, fn_soc_memmap ());
   endfunction

   // ---- combinational register read ------------------------------------
   // 32-bit registers at 4-byte offsets (two per 64-bit AXI word); the
   // device ROM starts at 0x100.

   function Bit #(32) fn_read32 (Bit #(32) byte_addr);
      Bit #(32) w    = byte_addr >> 3;    // 64-bit word index
      Bool      high = (byte_addr [2] == 1'b1);
      Bit #(32) v    = 0;
      if (w == 0)
         v = (high ? 1 : soc_magic);                       // 0x00 MAGIC, 0x04 VERSION
      else if (w == 1)
         v = (high ? features : build_date);               // 0x08 BUILD_DATE, 0x00C FEATURES
      else if (w == 2)
         v = pack (clk_hz);                               // 0x010 CPU_HZ, 0x014 TIMER_HZ
      else if (w == 3)
         v = (high ? fromInteger (n_devices)              // 0x018 MEMORY_SIZE, 0x01C DEVICE_COUNT
              : truncate (mem0_controller_addr_size));
      else if (w == 4)
         v = (high ? 0 : 32'h100);                        // 0x020 DEVICE_TABLE, 0x024 RESET_REASON
      else if (w == 5)
         v = (high ? rg_err_count                          // 0x02C BUSERR_COUNT
              : ((rg_err_valid ? 1 : 0)                    // 0x028 BUSERR_STATUS
                | (rg_err_iswr ? 2 : 0)
                | ({24'h0, rg_err_master} << 8)
                | ({30'h0, rg_err_resp} << 16)));
      else if (w == 6)
         v = truncate (rg_err_addr);                       // 0x030 BUSERR_ADDR_LO, 0x034 BUSERR_ADDR_HI
      else if (w == 7)
         v = 0;                                            // 0x038 rsvd (id dropped), 0x03C BUSERR_CLEAR
      else if ((w == 8) || (w == 9))
         // 0x040..0x04C PERF_SELECT_0..3
         v = zeroExtend (rg_perf_select [(w == 8) ? (high ? 1 : 0) : (high ? 3 : 2)]);
      else if ((w == 16) || (w == 17))
         // 0x080..0x08C PERF_COUNT_0..3
         v = rg_perf_count [(w == 16) ? (high ? 1 : 0) : (high ? 3 : 2)];
      else if (byte_addr >= 256)
         v = fn_devrom ((byte_addr - 256) >> 2);          // u32 index into ROM
      return v;
   endfunction

   // AXI narrow-read lane discipline: a 32-bit read at byte offset 4
   // expects its data in bus lanes [63:32].  Assemble the FULL 64-bit
   // word containing the address; the requester picks the lanes.
   function Bit #(Wd_Data) fn_read (Bit #(Wd_Addr) addr);
      Bit #(32) word_addr = truncate (addr) & 32'hFFFF_FFF8;
      return { fn_read32 (word_addr + 4), fn_read32 (word_addr) };
   endfunction


   // ---- write handler (ignore, acknowledge) ----------------------------

   rule rl_wr;
      let wra <- pop_o (slave_xactor.o_wr_addr);
      let wrd <- pop_o (slave_xactor.o_wr_data);
      Bit #(32) wr_byte_addr = truncate (wra.awaddr - rg_addr_base);
      AXI4_Resp bresp = ((wra.awaddr < rg_addr_base) || (wra.awaddr >= rg_addr_lim))
                        ? axi4_resp_decerr : axi4_resp_okay;
      if ((wra.awaddr >= rg_addr_base) && (wra.awaddr < rg_addr_lim)) begin
	 if (wr_byte_addr == 60) begin
	    // BUSERR_CLEAR (0x03C): write-anything clears count + capture
	    rg_err_count <= 0;
	    rg_err_valid <= False;
	 end
	 else if ((wr_byte_addr >= 64) && (wr_byte_addr <= 76)) begin
	    // PERF_SELECT_i (0x040..0x04C): 32-bit register, lane by addr[2]
	    Bit #(32) w32 = (wr_byte_addr [2] == 1'b1) ? wrd.wdata [63:32]
						       : wrd.wdata [31:0];
	    rw_sel_wr.wset (tuple2 (wr_byte_addr [3:2], w32 [3:0]));
	 end
	 else if ((wr_byte_addr >= 128) && (wr_byte_addr <= 140)) begin
	    // PERF_COUNT_i (0x080..0x08C): write-anything clears
	    rw_cnt_clr.wset (wr_byte_addr [3:2]);
	 end
      end
      slave_xactor.i_wr_resp.enq (AXI4_Wr_Resp {bid: wra.awid, bresp: bresp,
                                                 buser: wra.awuser});
   endrule

   // ---- read handler ----------------------------------------------------

   rule rl_rd;
      let rda <- pop_o (slave_xactor.o_rd_addr);
      AXI4_Resp   rresp = ((rda.araddr < rg_addr_base) || (rda.araddr >= rg_addr_lim))
                          ? axi4_resp_decerr : axi4_resp_okay;
      Fabric_Data rdata = ((rda.araddr < rg_addr_base) || (rda.araddr >= rg_addr_lim))
                          ? 0 : fn_read (rda.araddr - rg_addr_base);
      slave_xactor.i_rd_data.enq (AXI4_Rd_Data {rid:   rda.arid,
                                                rdata: rdata,
                                                rresp: rresp,
                                                rlast: True,
                                                ruser: rda.aruser});
   endrule

   // ---- INTERFACE

   method Action note_err (BusErrEvent e);
      rg_err_count <= (rg_err_count == 32'hFFFF_FFFF) ? 32'hFFFF_FFFF
                                                      : rg_err_count + 1;
      if (! rg_err_valid) begin
         rg_err_valid  <= True;
         rg_err_addr   <= e.addr;
         rg_err_iswr   <= e.is_wr;
         rg_err_master <= e.master;
         rg_err_resp   <= e.resp;
      end
      pw_buserr.send;
   endmethod

   method Action note_retire;    pw_retire.send;   endmethod
   method Action note_imiss;     pw_imiss.send;   endmethod
   method Action note_dmiss;     pw_dmiss.send;   endmethod
   method Action note_ext_irq;   pw_ext_irq.send;   endmethod
   method Action note_uart_irq;  pw_uart_irq.send;   endmethod
   method Action note_redirect;  pw_redirect.send;   endmethod

   method Action init (Bit #(Wd_Id) axi4_id, Bit #(Wd_Addr) addr_base, Bit #(Wd_Addr) addr_lim);
      rg_addr_base <= addr_base;
      rg_addr_lim  <= addr_lim;
   endmethod

   interface slave = slave_xactor.axi_side;

endmodule

endpackage
