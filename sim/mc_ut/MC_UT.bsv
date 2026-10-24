// MC_UT: Mem_Controller data-integrity test (Bluesim).
// Random AXI traffic through mkMem_Controller into a streaming raw-memory
// model (Raw_Mem_Req lines, 64-bit chunks, random start latency and chunk
// gaps) over 8 lines (64 dwords):
//   - single-beat reads and writes (random byte strobes),
//   - line-aligned 8-beat read bursts (the L1 refills),
//   - INCR read bursts of 1..8 beats at any dword, crossing a line,
//   - INCR write bursts of 2..4 beats.
// Up to 15 requests in flight, with random quiet periods (idle writebacks).
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

typedef struct { Bit #(6) slot; Bit #(4) n; } Span deriving (Bits);

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

   rule rl_seed (! rg_seeded);
      lfsr.seed ('h1234_5679);
      rg_seeded <= True;
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
         rg_mdelay <= lfsr.value [10:8];
         rg_mbusy  <= True;
         rg_raw_rd <= rg_raw_rd + 1;
      end
   endrule

   rule rl_mem_rsp (rg_mbusy);
      if (rg_mdelay != 0) rg_mdelay <= rg_mdelay - 1;
      else if (lfsr.value [12:11] != 0) begin       // ~25% gap cycles between chunks
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
   Bit #(4) rlen  = (rend > 64) ? truncate (rroom) : rlen0;
   // write span: single, or a 2..4 beat burst (clipped)
   Bit #(4) wlen0 = (bsel == 3) ? zeroExtend (lfsr.value [16:15]) + 1 : 1;
   Bit #(7) wend  = zeroExtend (slot) + zeroExtend (wlen0);
   Bit #(7) wroom = 64 - zeroExtend (slot);
   Bit #(4) wlen  = (wend > 64) ? truncate (wroom) : wlen0;

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

   function Action fa_wbeat (Bit #(6) s, Bool last);
      action
         Bit #(64) d  = { lfsr.value, ~ lfsr.value [31:16], lfsr.value [15:0] };
         Bit #(8) st  = lfsr.value [27:20];
         if (st == 0) st = 8'h01;
         mx.i_wr_data.enq (AXI4_Wr_Data {wdata: d, wstrb: st, wlast: last, wuser: 0});
         Vector #(8, Bit #(8)) o = unpack (shadow [s]);
         Vector #(8, Bit #(8)) n = unpack (d);
         for (Integer j = 0; j < 8; j = j + 1) if (st [j] == 1) o [j] = n [j];
         shadow [s] <= pack (o);
      endaction
   endfunction

   rule rl_issue_wr (go && do_wr && span_free (pend_rd, slot, wlen));
      Bit #(64) a  = base + (zeroExtend (slot) << 3);
      mx.i_wr_addr.enq (AXI4_Wr_Addr {awid: 0, awaddr: a, awlen: zeroExtend (wlen - 1), awsize: axsize_8,
                                      awburst: axburst_incr, awlock: 0, awcache: 0, awprot: 0,
                                      awqos: 0, awregion: 0, awuser: 0});
      fa_wbeat (slot, wlen == 1);
      for (Integer i = 0; i < valueOf (NSlots); i = i + 1)
         if (in_span (i, slot, wlen)) pend_wr [i] <= pend_wr [i] + 1;
      f_wspan.enq (Span {slot: slot, n: wlen});
      rg_wleft <= truncate (wlen - 1);
      rg_wslot <= slot + 1;
      if (wlen > 1) rg_wbursts <= rg_wbursts + 1;
      rg_out  <= rg_out + 1;
      rg_ops  <= rg_ops + 1;
   endrule

   rule rl_issue_wbeat (rg_wleft != 0);
      fa_wbeat (rg_wslot, rg_wleft == 1);
      rg_wslot <= rg_wslot + 1;
      rg_wleft <= rg_wleft - 1;
   endrule

   rule rl_issue_rd (go && ! do_wr && span_free (pend_wr, rslot, rlen) && rg_rd_out < 4);
      Bit #(64) a  = base + (zeroExtend (rslot) << 3);
      mx.i_rd_addr.enq (AXI4_Rd_Addr {arid: 0, araddr: a, arlen: zeroExtend (rlen - 1), arsize: axsize_8,
                                      arburst: axburst_incr, arlock: 0, arcache: 0, arprot: 0,
                                      arqos: 0, arregion: 0, aruser: 0});
      f_rexp.enq (Span {slot: rslot, n: rlen});
      for (Integer i = 0; i < valueOf (NSlots); i = i + 1)
         if (in_span (i, rslot, rlen)) pend_rd [i] <= pend_rd [i] + 1;
      if (rlen > 1) rg_bursts <= rg_bursts + 1;
      rg_rd_out <= rg_rd_out + 1;
      rg_out  <= rg_out + 1;
      rg_ops  <= rg_ops + 1;
   endrule

   (* descending_urgency = "rl_b, rl_r, rl_issue_wbeat, rl_issue_wr, rl_issue_rd" *)
   rule rl_b;
      let b <- pop_o (mx.o_wr_resp);
      let sp = f_wspan.first; f_wspan.deq;
      if (b.bresp != axi4_resp_okay) begin
         $display ("ERROR: bresp %0d", b.bresp);
         rg_errs <= rg_errs + 1;
      end
      for (Integer i = 0; i < valueOf (NSlots); i = i + 1)
         if (in_span (i, sp.slot, sp.n)) pend_wr [i] <= pend_wr [i] - 1;
      rg_out <= rg_out - 1;
   endrule

   rule rl_r;
      let r <- pop_o (mx.o_rd_data);
      let sp = f_rexp.first;
      Bit #(6) s = sp.slot + zeroExtend (rg_rbeat);
      Bool last = (rg_rbeat + 1 == sp.n);
      if (r.rresp != axi4_resp_okay || r.rdata != shadow [s] || r.rlast != last) begin
         if (rg_errs < 10)
            $display ("ERROR: op %0d slot %0d (burst %0d+%0d) got %h exp %h resp %0d rlast %0d",
                      rg_ops, s, sp.slot, rg_rbeat, r.rdata, shadow [s], r.rresp, r.rlast);
         rg_errs <= rg_errs + 1;
      end
      pend_rd [s] <= pend_rd [s] - 1;
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

   rule rl_done (rg_ops >= fromInteger (n_ops) && rg_out == 0 && rg_wleft == 0);
      $display ("[mc_ut] %0d ops (%0d read bursts, %0d write bursts), %0d R beats checked, %0d errors; raw reads %0d, raw writes %0d",
                rg_ops, rg_bursts, rg_wbursts, rg_rbeats, rg_errs, rg_raw_rd, rg_raw_wr);
      $display ((rg_errs == 0 && rg_rbeats > 0) ? "[mc_ut] PASS" : "[mc_ut] FAIL");
      $finish (0);
   endrule
endmodule

endpackage
