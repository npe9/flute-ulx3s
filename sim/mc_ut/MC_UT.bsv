// MC_UT: Mem_Controller data-integrity test (Bluesim).
// Random AXI traffic through mkMem_Controller into a streaming raw-memory
// model (Raw_Mem_Req lines, 64-bit chunks, random start latency and chunk
// gaps) over 8 lines (64 dwords):
//   - single-beat reads and writes (random byte strobes),
//   - line-aligned 8-beat read bursts (the L1 refills),
//   - INCR read bursts of 1..8 beats at any dword, crossing a line,
//   - INCR write bursts of 2..4 beats.
// Up to 15 requests in flight, with random quiet periods (idle writebacks).
// Every request carries a random ID, which R and B must echo.  About 1 in 8
// bursts that would cross the top of the window is issued unclipped: every
// R beat must be SLVERR (rlast on the last), a write gets one SLVERR B and
// changes no memory.  Half the raw reads use the SDRAM cadence (a fixed
// first-chunk delay, then one chunk every 4 cycles), the rest random gaps.
// A dword is only read with no write to it in flight and written with no
// read of it in flight (AXI does not order the read and write channels), so
// the shadow is exact at issue.  Every R beat is checked (data, rlast).
package MC_UT;

import Vector       :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;
import Connectable  :: *;
import LFSR         :: *;

import Semi_FIFOF     :: *;
import AXI4_Types     :: *;
import Fabric_Defs    :: *;
import Mem_Controller :: *;

typedef 8  NLines;
typedef 64 NSlots;                       // dwords
Integer n_ops = 300000;
Bit #(64) base = 'h8000_0000;

typedef struct { Bit #(6) slot; Bit #(4) n; Fabric_Id id; Bool err; } Span deriving (Bits);

(* synthesize *)
module mkMC_UT (Empty);
   Mem_Controller_IFC mc <- mkMem_Controller;
   AXI4_Master_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) mx <- mkAXI4_Master_Xactor;
   mkConnection (mx.axi_side, mc.slave);

   LFSR #(Bit #(32)) lfsr <- mkLFSR_32;
   Reg #(Bool) rg_seeded <- mkReg (False);

   // ---- streaming raw memory model
   Vector #(NSlots, Reg #(Bit #(64))) mem <- replicateM (mkReg (0));
   Reg #(Bool)     rg_mbusy  <- mkReg (False);
   Reg #(Bit #(3)) rg_mdelay <- mkReg (0);
   Reg #(Bit #(6)) rg_mslot  <- mkRegU;     // next dword to return
   Reg #(Bit #(4)) rg_mleft  <- mkReg (0);  // chunks left
   Reg #(Bool)     rg_mcad   <- mkReg (False);   // SDRAM cadence for this read
   Reg #(Bit #(2)) rg_mphase <- mkReg (0);

   Vector #(NSlots, Reg #(Bit #(64))) shadow  <- replicateM (mkReg (0));
   Vector #(NSlots, Reg #(Bit #(4)))  pend_wr <- replicateM (mkReg (0));
   Vector #(NSlots, Reg #(Bit #(4)))  pend_rd <- replicateM (mkReg (0));
   FIFOF #(Span) f_rexp  <- mkSizedFIFOF (16);   // reads in flight
   FIFOF #(Span) f_wspan <- mkSizedFIFOF (16);   // write bursts awaiting B

   Reg #(Bool)      rg_mapped <- mkReg (False);
   Reg #(Bit #(4))  rg_quiet  <- mkReg (0);
   Reg #(Bit #(5))  rg_out    <- mkReg (0);
   Reg #(Bit #(5))  rg_rd_out <- mkReg (0);    // reads in flight (capped, or writes starve)
   Reg #(Bit #(4))  rg_rbeat  <- mkReg (0);    // beat within f_rexp.first
   Reg #(Bit #(3))  rg_wleft  <- mkReg (0);    // write-burst beats still to send
   Reg #(Bit #(6))  rg_wslot  <- mkRegU;
   Reg #(UInt #(32)) rg_ops    <- mkReg (0);
   Reg #(UInt #(32)) rg_rbeats <- mkReg (0);
   Reg #(UInt #(32)) rg_bursts <- mkReg (0);
   Reg #(UInt #(32)) rg_wbursts <- mkReg (0);
   Reg #(UInt #(32)) rg_errs   <- mkReg (0);
   Reg #(UInt #(32)) rg_raw_rd <- mkReg (0);
   Reg #(UInt #(32)) rg_raw_wr <- mkReg (0);
   Reg #(UInt #(32)) rg_err_r  <- mkReg (0);   // SLVERR R beats seen (expected)
   Reg #(UInt #(32)) rg_err_b  <- mkReg (0);   // SLVERR B seen (expected)
   // Liveness: after the random traffic, back-to-back stores to one dword
   // (no idle gap); the raw memory must see one of them (the buffer ages out).
   Reg #(Bool)       rg_spin      <- mkReg (False);
   Reg #(UInt #(16)) rg_spin_cyc  <- mkReg (0);
   Reg #(Bool)       rg_spin_seen <- mkReg (False);

   // +reset_test: after the store spin, reset Mem_Controller while a raw read
   // is being delivered (the raw memory keeps sending its chunks, as
   // Sdram_Controller does), then read back a line known to be in memory.
   Reg #(Bool)     rg_rt_mode <- mkReg (False);
   Reg #(Bit #(4)) rg_rt      <- mkReg (0);      // reset-test phase
   Reg #(Bit #(9)) rg_rt_n    <- mkReg (0);

   rule rl_seed (! rg_seeded);
      lfsr.seed ('h1234_5679);
      rg_seeded <= True;
      let m <- $test$plusargs ("reset_test");
      rg_rt_mode <= m;
   endrule

   rule rl_map (rg_seeded && ! rg_mapped);
      mc.set_addr_map (base, base + fromInteger (valueOf (NLines) * 64));
      rg_mapped <= True;
   endrule

   rule rl_mem_req (! rg_mbusy);
      let r <- mc.to_raw_mem.request.get;
      Bit #(3) l = truncate (r.line);
      if (r.write) begin
         for (Integer j = 0; j < 4; j = j + 1) begin
            Bit #(6) s = { l, r.b_first [1], fromInteger (j) };
            Vector #(8, Bit #(8)) o = unpack (mem [s]);
            Vector #(8, Bit #(8)) n = unpack (r.wdata [j * 64 + 63 : j * 64]);
            for (Integer k = 0; k < 8; k = k + 1)
               if (r.wbe [j * 8 + k] == 1) o [k] = n [k];
            mem [s] <= pack (o);
         end
         rg_raw_wr <= rg_raw_wr + 1;
      end
      else begin
         rg_mslot  <= { l, r.b_first, 1'b0 };
         rg_mleft  <= (zeroExtend (r.b_last - r.b_first) + 1) << 1;
         Bool cad = (lfsr.value [13] == 1);
         rg_mcad   <= cad;
         rg_mphase <= 0;
         rg_mdelay <= cad ? 7 : lfsr.value [10:8];
         rg_mbusy  <= True;
         rg_raw_rd <= rg_raw_rd + 1;
      end
   endrule

   rule rl_mem_rsp (rg_mbusy);
      if (rg_mdelay != 0) rg_mdelay <= rg_mdelay - 1;
      else if (rg_mcad && rg_mphase != 3) rg_mphase <= rg_mphase + 1;
      else if (rg_mcad || lfsr.value [12:11] != 0) begin   // cadence, or ~25% random gaps
         rg_mphase <= 0;
         mc.to_raw_mem.response.put (mem [rg_mslot]);
         rg_mslot <= rg_mslot + 1;
         if (rg_mleft == 1) rg_mbusy <= False;
         rg_mleft <= rg_mleft - 1;
      end
   endrule

   // ---- traffic
   rule rl_step (rg_mapped);
      lfsr.next;
   endrule

   rule rl_quiet (rg_mapped);
      if (rg_quiet != 0) rg_quiet <= rg_quiet - 1;
      else if (lfsr.value [31:26] == 0) rg_quiet <= lfsr.value [19:16];
   endrule

   Bool go = rg_mapped && rg_quiet == 0 && rg_ops < fromInteger (n_ops) && rg_out < 15
             && rg_wleft == 0 && (lfsr.value [0] == 1 || lfsr.value [1] == 1);
   Bit #(6) slot  = lfsr.value [7:2];
   Bit #(2) kind  = lfsr.value [9:8];
   Bit #(2) bsel  = lfsr.value [14:13];

   // read span: single, line refill, or random INCR burst (clipped to the map)
   Bit #(4) rlen0 = (bsel == 0) ? 8 : ((bsel == 1) ? zeroExtend (lfsr.value [17:15]) + 1 : 1);
   Bit #(6) rslot = (bsel == 0) ? { slot [5:3], 3'b0 } : slot;
   Bit #(7) rend  = zeroExtend (rslot) + zeroExtend (rlen0);
   Bit #(7) rroom = 64 - zeroExtend (rslot);
   Bool     rerr  = (rend > 64) && (lfsr.value [21:19] == 0);    // issued unclipped: SLVERR
   Bit #(4) rlen  = ((rend > 64) && ! rerr) ? truncate (rroom) : rlen0;
   // write span: single, or a 2..4 beat burst (clipped)
   Bit #(4) wlen0 = (bsel == 3) ? zeroExtend (lfsr.value [16:15]) + 1 : 1;
   Bit #(7) wend  = zeroExtend (slot) + zeroExtend (wlen0);
   Bit #(7) wroom = 64 - zeroExtend (slot);
   Bool     werr  = (wend > 64) && (lfsr.value [21:19] == 0);
   Bit #(4) wlen  = ((wend > 64) && ! werr) ? truncate (wroom) : wlen0;
   Fabric_Id tid  = truncate (lfsr.value [25:22]);

   function Bool in_span (Integer i, Bit #(6) s, Bit #(4) n);
      Bit #(7) ii = fromInteger (i);
      return (ii >= zeroExtend (s)) && (ii < zeroExtend (s) + zeroExtend (n));
   endfunction
   function Bool span_free (Vector #(NSlots, Reg #(Bit #(4))) p, Bit #(6) s, Bit #(4) n);
      Bool ok = True;
      for (Integer i = 0; i < valueOf (NSlots); i = i + 1)
         if (in_span (i, s, n) && p [i] != 0) ok = False;
      return ok;
   endfunction

   Bool do_wr = kind != 0;    // 3:1 writes (reads get through more often)

   Reg #(Bool) rg_werr <- mkReg (False);    // the write burst being sent is out of range

   function Action fa_wbeat (Bit #(6) s, Bool last, Bool err);
      action
         Bit #(64) d  = { lfsr.value, ~ lfsr.value [31:16], lfsr.value [15:0] };
         Bit #(8) st  = lfsr.value [27:20];
         if (st == 0) st = 8'h01;
         mx.i_wr_data.enq (AXI4_Wr_Data {wdata: d, wstrb: st, wlast: last, wuser: 0});
         Vector #(8, Bit #(8)) o = unpack (shadow [s]);
         Vector #(8, Bit #(8)) n = unpack (d);
         for (Integer j = 0; j < 8; j = j + 1) if (st [j] == 1) o [j] = n [j];
         if (! err) shadow [s] <= pack (o);
      endaction
   endfunction

   rule rl_issue_wr (go && do_wr && (werr || span_free (pend_rd, slot, wlen)));
      Bit #(64) a  = base + (zeroExtend (slot) << 3);
      mx.i_wr_addr.enq (AXI4_Wr_Addr {awid: tid, awaddr: a, awlen: zeroExtend (wlen - 1), awsize: axsize_8,
                                      awburst: axburst_incr, awlock: 0, awcache: 0, awprot: 0,
                                      awqos: 0, awregion: 0, awuser: 0});
      fa_wbeat (slot, wlen == 1, werr);
      if (! werr)
         for (Integer i = 0; i < valueOf (NSlots); i = i + 1)
            if (in_span (i, slot, wlen)) pend_wr [i] <= pend_wr [i] + 1;
      f_wspan.enq (Span {slot: slot, n: wlen, id: tid, err: werr});
      rg_werr  <= werr;
      rg_wleft <= truncate (wlen - 1);
      rg_wslot <= slot + 1;
      if (wlen > 1) rg_wbursts <= rg_wbursts + 1;
      rg_out  <= rg_out + 1;
      rg_ops  <= rg_ops + 1;
   endrule

   rule rl_issue_wbeat (rg_wleft != 0);
      fa_wbeat (rg_wslot, rg_wleft == 1, rg_werr);
      rg_wslot <= rg_wslot + 1;
      rg_wleft <= rg_wleft - 1;
   endrule

   rule rl_issue_rd (go && ! do_wr && (rerr || span_free (pend_wr, rslot, rlen)) && rg_rd_out < 4);
      Bit #(64) a  = base + (zeroExtend (rslot) << 3);
      mx.i_rd_addr.enq (AXI4_Rd_Addr {arid: tid, araddr: a, arlen: zeroExtend (rlen - 1), arsize: axsize_8,
                                      arburst: axburst_incr, arlock: 0, arcache: 0, arprot: 0,
                                      arqos: 0, arregion: 0, aruser: 0});
      f_rexp.enq (Span {slot: rslot, n: rlen, id: tid, err: rerr});
      if (! rerr)
         for (Integer i = 0; i < valueOf (NSlots); i = i + 1)
            if (in_span (i, rslot, rlen)) pend_rd [i] <= pend_rd [i] + 1;
      if (rlen > 1) rg_bursts <= rg_bursts + 1;
      rg_rd_out <= rg_rd_out + 1;
      rg_out  <= rg_out + 1;
      rg_ops  <= rg_ops + 1;
   endrule

   // Watchdog: a hang reports its state instead of running forever
   Reg #(UInt #(32)) rg_cyc <- mkReg (0);
   rule rl_watchdog;
      rg_cyc <= rg_cyc + 1;
      if (rg_cyc == 20000000) begin
         $display ("[mc_ut] HANG: ops %0d out %0d rd_out %0d wleft %0d spin %0d spin_cyc %0d raw rd %0d wr %0d",
                   rg_ops, rg_out, rg_rd_out, rg_wleft, rg_spin, rg_spin_cyc, rg_raw_rd, rg_raw_wr);
         $display ("[mc_ut] FAIL");
         $finish (1);
      end
   endrule

   rule rl_spin_start (! rg_spin && rg_ops >= fromInteger (n_ops) && rg_out == 0 && rg_wleft == 0);
      rg_spin <= True;
   endrule

   rule rl_spin_wr (rg_spin && rg_spin_cyc < 1000 && rg_out < 4);
      mx.i_wr_addr.enq (AXI4_Wr_Addr {awid: 0, awaddr: base, awlen: 0, awsize: axsize_8,
                                      awburst: axburst_incr, awlock: 0, awcache: 0, awprot: 0,
                                      awqos: 0, awregion: 0, awuser: 0});
      mx.i_wr_data.enq (AXI4_Wr_Data {wdata: { 32'h5A5A_5A5A, 16'h0, pack (rg_spin_cyc) }, wstrb: '1, wlast: True, wuser: 0});
      pend_wr [0] <= pend_wr [0] + 1;
      f_wspan.enq (Span {slot: 0, n: 1, id: 0, err: False});
      rg_out <= rg_out + 1;
   endrule

   rule rl_spin_tick (rg_spin);
      if (rg_spin_cyc < 1100) rg_spin_cyc <= rg_spin_cyc + 1;
      if (mem [0][63:32] == 32'h5A5A_5A5A) rg_spin_seen <= True;
   endrule

   (* descending_urgency = "rl_b, rl_r, rl_issue_wbeat, rl_issue_wr, rl_issue_rd, rl_spin_wr" *)
   rule rl_b;
      let b <- pop_o (mx.o_wr_resp);
      let sp = f_wspan.first; f_wspan.deq;
      if (b.bresp != (sp.err ? axi4_resp_slverr : axi4_resp_okay) || b.bid != sp.id) begin
         $display ("ERROR: bresp %0d bid %0d (exp err %0d id %0d)", b.bresp, b.bid, sp.err, sp.id);
         rg_errs <= rg_errs + 1;
      end
      if (! sp.err)
         for (Integer i = 0; i < valueOf (NSlots); i = i + 1)
            if (in_span (i, sp.slot, sp.n)) pend_wr [i] <= pend_wr [i] - 1;
      if (sp.err) rg_err_b <= rg_err_b + 1;
      rg_out <= rg_out - 1;
   endrule

   rule rl_r;
      let r <- pop_o (mx.o_rd_data);
      let sp = f_rexp.first;
      Bit #(6) s = sp.slot + zeroExtend (rg_rbeat);
      Bool last = (rg_rbeat + 1 == sp.n);
      Bool bad = sp.err ? (r.rresp != axi4_resp_slverr)
                        : (r.rresp != axi4_resp_okay || r.rdata != shadow [s]);
      if (bad || r.rlast != last || r.rid != sp.id) begin
         if (rg_errs < 10)
            $display ("ERROR: op %0d slot %0d (burst %0d+%0d) got %h exp %h resp %0d rlast %0d",
                      rg_ops, s, sp.slot, rg_rbeat, r.rdata, shadow [s], r.rresp, r.rlast);
         if (rg_errs < 10 && r.rid != sp.id) $display ("ERROR: rid %0d exp %0d", r.rid, sp.id);
         rg_errs <= rg_errs + 1;
      end
      if (! sp.err) pend_rd [s] <= pend_rd [s] - 1;
      else rg_err_r <= rg_err_r + 1;
      rg_rbeats <= rg_rbeats + 1;
      if (last) begin
         f_rexp.deq;
         rg_rbeat  <= 0;
         rg_rd_out <= rg_rd_out - 1;
         rg_out    <= rg_out - 1;
      end
      else
         rg_rbeat <= rg_rbeat + 1;
   endrule

   Bool spin_done = rg_spin && rg_spin_cyc >= 1000 && rg_out == 0;

   // phase 1: line 0 <- pattern (8 single writes); 2: wait for the B's and 300 idle cycles
   rule rl_rt_write (rg_rt_mode && spin_done && rg_rt == 0 && rg_rt_n < 8);
      Bit #(6)  sl = truncate (rg_rt_n);
      Bit #(64) d  = 64'hC0DE_0000_0000_0000 | zeroExtend (rg_rt_n);
      mx.i_wr_addr.enq (AXI4_Wr_Addr {awid: 0, awaddr: base + (zeroExtend (sl) << 3), awlen: 0, awsize: axsize_8,
                                      awburst: axburst_incr, awlock: 0, awcache: 0, awprot: 0,
                                      awqos: 0, awregion: 0, awuser: 0});
      mx.i_wr_data.enq (AXI4_Wr_Data {wdata: d, wstrb: '1, wlast: True, wuser: 0});
      shadow [sl] <= d;
      pend_wr [sl] <= pend_wr [sl] + 1;
      f_wspan.enq (Span {slot: sl, n: 1, id: 0, err: False});
      rg_out  <= rg_out + 1;
      rg_rt_n <= rg_rt_n + 1;
   endrule
   rule rl_rt_settle (rg_rt_mode && rg_rt == 0 && rg_rt_n >= 8 && rg_out == 0);
      if (rg_rt_n == 308) begin rg_rt <= 1; rg_rt_n <= 0; end
      else rg_rt_n <= rg_rt_n + 1;
   endrule
   // phase 3: a line read of line 4, never answered (it is reset away)
   rule rl_rt_read4 (rg_rt == 1);
      mx.i_rd_addr.enq (AXI4_Rd_Addr {arid: 0, araddr: base + 32 * 8, arlen: 7, arsize: axsize_8,
                                      arburst: axburst_incr, arlock: 0, arcache: 0, arprot: 0,
                                      arqos: 0, arregion: 0, aruser: 0});
      rg_rt <= 2;
   endrule
   // phase 4: reset while the raw read is mid-delivery
   rule rl_rt_reset (rg_rt == 2 && rg_mbusy && rg_mdelay == 0 && rg_mleft <= 6 && rg_mleft >= 2);
      mc.server_reset.request.put (?);
      rg_rt <= 3;
      $display ("[mc_ut] reset with %0d raw chunks still to come", rg_mleft);
   endrule
   rule rl_rt_reset_done (rg_rt == 3);
      let r <- mc.server_reset.response.get;
      mx.reset;
      rg_rt <= 4;
   endrule
   // phase 5: read line 0 back (checked by rl_r against the pattern)
   rule rl_rt_read0 (rg_rt == 4);
      mx.i_rd_addr.enq (AXI4_Rd_Addr {arid: 0, araddr: base, arlen: 7, arsize: axsize_8,
                                      arburst: axburst_incr, arlock: 0, arcache: 0, arprot: 0,
                                      arqos: 0, arregion: 0, aruser: 0});
      f_rexp.enq (Span {slot: 0, n: 8, id: 0, err: False});
      for (Integer i = 0; i < 8; i = i + 1) pend_rd [i] <= pend_rd [i] + 1;
      rg_out <= rg_out + 1; rg_rd_out <= rg_rd_out + 1;
      rg_rt <= 5;
   endrule

   rule rl_done (spin_done && ((! rg_rt_mode) || rg_rt == 5));
      $display ("[mc_ut] %0d ops (%0d read bursts, %0d write bursts), %0d R beats checked, %0d errors; raw reads %0d, raw writes %0d",
                rg_ops, rg_bursts, rg_wbursts, rg_rbeats, rg_errs, rg_raw_rd, rg_raw_wr);
      $display ("[mc_ut] out-of-range: %0d SLVERR R beats, %0d SLVERR B", rg_err_r, rg_err_b);
      if (rg_rt_mode) $display ("[mc_ut] reset test: line 0 read back after a mid-read reset (%0d errors total)", rg_errs);
      $display ("[mc_ut] store spin (1000 cycles, no idle gap) reached memory: %s", rg_spin_seen ? "yes" : "NO");
      $display ((rg_errs == 0 && rg_rbeats > 0 && rg_spin_seen && rg_err_r > 0 && rg_err_b > 0) ? "[mc_ut] PASS" : "[mc_ut] FAIL");
      $finish (0);
   endrule
endmodule

endpackage
