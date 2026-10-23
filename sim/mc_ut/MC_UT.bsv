// MC_UT: Mem_Controller data-integrity test (Bluesim).
// Random single-beat AXI reads and writes (random byte strobes) to 8 raw
// words, through mkMem_Controller, into a byte-enable raw-memory model with
// random response latency.  Up to 15 requests in flight, mixed, with random
// quiet periods (so writebacks run both idle and on a pending request);
// every returned dword is checked against a shadow copy.  Covers the
// dirty-byte writeback, the no-read write-miss takeover and the reload
// merge of a partially valid word.
package MC_UT;

import Vector       :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;
import Connectable  :: *;
import LFSR         :: *;
import Memory       :: *;

import Semi_FIFOF     :: *;
import AXI4_Types     :: *;
import Fabric_Defs    :: *;
import Mem_Controller :: *;

typedef 8 NWords;                        // raw words under test
typedef TMul #(NWords, 4) NSlots;        // dwords
Integer n_ops = 300000;
Bit #(64) base = 'h8000_0000;

(* synthesize *)
module mkMC_UT (Empty);
   Mem_Controller_IFC mc <- mkMem_Controller;
   AXI4_Master_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) mx <- mkAXI4_Master_Xactor;
   mkConnection (mx.axi_side, mc.slave);

   LFSR #(Bit #(32)) lfsr <- mkLFSR_32;
   Reg #(Bool) rg_seeded <- mkReg (False);

   // raw memory model
   Vector #(NWords, Reg #(Bit #(256))) mem <- replicateM (mkReg (0));
   FIFOF #(Bit #(256)) f_mrsp <- mkSizedFIFOF (2);
   Reg #(Bit #(3)) rg_mdelay <- mkReg (0);
   Reg #(Bool)     rg_mbusy  <- mkReg (False);
   Reg #(Bit #(256)) rg_mdata <- mkRegU;

   Vector #(NSlots, Reg #(Bit #(64))) shadow <- replicateM (mkReg (0));
   FIFOF #(Bit #(5)) f_exp <- mkSizedFIFOF (16);

   Reg #(Bool)      rg_mapped <- mkReg (False);
   Reg #(Bit #(4))  rg_quiet  <- mkReg (0);
   Reg #(Bit #(5))  rg_out    <- mkReg (0);
   Reg #(Bit #(5))  rg_rd_out <- mkReg (0);    // reads in flight (capped, or writes starve)
   // per-slot in-flight writes / reads: a slot is only read with no write to
   // it in flight and written with no read of it in flight (AXI does not
   // order the read and write channels), so the shadow is exact at issue
   Vector #(NSlots, Reg #(Bit #(4))) pend_wr <- replicateM (mkReg (0));
   Vector #(NSlots, Reg #(Bit #(4))) pend_rd <- replicateM (mkReg (0));
   FIFOF #(Bit #(5)) f_wslot <- mkSizedFIFOF (16);
   Reg #(UInt #(32)) rg_ops   <- mkReg (0);
   Reg #(UInt #(32)) rg_rds   <- mkReg (0);
   Reg #(UInt #(32)) rg_errs  <- mkReg (0);
   Reg #(UInt #(32)) rg_raw_rd <- mkReg (0);
   Reg #(UInt #(32)) rg_raw_wr <- mkReg (0);

   rule rl_seed (! rg_seeded);
      lfsr.seed ('h1234_5679);
      rg_seeded <= True;
   endrule

   rule rl_map (rg_seeded && ! rg_mapped);
      mc.set_addr_map (base, base + fromInteger (valueOf (NWords) * 32));
      rg_mapped <= True;
   endrule

   // ---- raw memory: writes apply at once; reads answer after 0-7 cycles
   rule rl_mem_req (! rg_mbusy);
      let r <- mc.to_raw_mem.request.get;
      Bit #(3) w = truncate (r.address);
      if (r.write) begin
         Vector #(32, Bit #(8)) o = unpack (mem [w]);
         Vector #(32, Bit #(8)) n = unpack (r.data);
         for (Integer j = 0; j < 32; j = j + 1)
            if (r.byteen [j] == 1) o [j] = n [j];
         mem [w] <= pack (o);
         rg_raw_wr <= rg_raw_wr + 1;
      end
      else begin
         rg_mdata  <= mem [w];
         rg_mdelay <= lfsr.value [10:8];
         rg_mbusy  <= True;
         rg_raw_rd <= rg_raw_rd + 1;
      end
   endrule

   rule rl_mem_rsp (rg_mbusy);
      if (rg_mdelay == 0) begin
         mc.to_raw_mem.response.put (MemoryResponse {data: rg_mdata});
         rg_mbusy <= False;
      end
      else rg_mdelay <= rg_mdelay - 1;
   endrule

   // ---- traffic
   rule rl_step (rg_mapped);
      lfsr.next;
   endrule

   Bool go = rg_mapped && rg_quiet == 0 && rg_ops < fromInteger (n_ops) && rg_out < 15
             && (lfsr.value [0] == 1 || lfsr.value [1] == 1);   // ~75% issue
   Bit #(5) slot = lfsr.value [6:2];
   Bool     do_wr = lfsr.value [7] == 1 || lfsr.value [8] == 1;   // 3:1, reads get through more often

   // ~1 in 64 cycles: stop issuing for up to 15 cycles (idle writebacks)
   rule rl_quiet (rg_mapped);
      if (rg_quiet != 0) rg_quiet <= rg_quiet - 1;
      else if (lfsr.value [31:26] == 0) rg_quiet <= lfsr.value [19:16];
   endrule

   rule rl_issue_wr (go && do_wr && pend_rd [slot] == 0);
      Bit #(64) d  = { lfsr.value, ~ lfsr.value [31:16], lfsr.value [15:0] };
      Bit #(8) st  = lfsr.value [27:20];
      if (st == 0) st = 8'h01;
      Bit #(64) a  = base + (zeroExtend (slot) << 3);
      mx.i_wr_addr.enq (AXI4_Wr_Addr {awid: 0, awaddr: a, awlen: 0, awsize: axsize_8,
                                      awburst: axburst_incr, awlock: 0, awcache: 0, awprot: 0,
                                      awqos: 0, awregion: 0, awuser: 0});
      mx.i_wr_data.enq (AXI4_Wr_Data {wdata: d, wstrb: st, wlast: True, wuser: 0});
      Vector #(8, Bit #(8)) o = unpack (shadow [slot]);
      Vector #(8, Bit #(8)) n = unpack (d);
      for (Integer j = 0; j < 8; j = j + 1) if (st [j] == 1) o [j] = n [j];
      shadow [slot] <= pack (o);
      pend_wr [slot] <= pend_wr [slot] + 1;
      f_wslot.enq (slot);
      rg_out  <= rg_out + 1;
      rg_ops  <= rg_ops + 1;
   endrule

   rule rl_issue_rd (go && ! do_wr && pend_wr [slot] == 0 && rg_rd_out < 4);
      Bit #(64) a  = base + (zeroExtend (slot) << 3);
      mx.i_rd_addr.enq (AXI4_Rd_Addr {arid: 0, araddr: a, arlen: 0, arsize: axsize_8,
                                      arburst: axburst_incr, arlock: 0, arcache: 0, arprot: 0,
                                      arqos: 0, arregion: 0, aruser: 0});
      f_exp.enq (slot);
      pend_rd [slot] <= pend_rd [slot] + 1;
      rg_rd_out <= rg_rd_out + 1;
      rg_out  <= rg_out + 1;
      rg_ops  <= rg_ops + 1;
   endrule

   (* descending_urgency = "rl_b, rl_r, rl_issue_wr, rl_issue_rd" *)
   rule rl_b;
      let b <- pop_o (mx.o_wr_resp);
      let s = f_wslot.first; f_wslot.deq;
      if (b.bresp != axi4_resp_okay) begin
         $display ("ERROR: bresp %0d", b.bresp);
         rg_errs <= rg_errs + 1;
      end
      pend_wr [s] <= pend_wr [s] - 1;
      rg_out <= rg_out - 1;
   endrule

   rule rl_r;
      let r <- pop_o (mx.o_rd_data);
      let s = f_exp.first; f_exp.deq;
      if (r.rresp != axi4_resp_okay || r.rdata != shadow [s]) begin
         if (rg_errs < 10)
            $display ("ERROR: op %0d slot %0d got %h exp %h resp %0d", rg_ops, s, r.rdata, shadow [s], r.rresp);
         rg_errs <= rg_errs + 1;
      end
      pend_rd [s] <= pend_rd [s] - 1;
      rg_rd_out <= rg_rd_out - 1;
      rg_rds <= rg_rds + 1;
      rg_out <= rg_out - 1;
   endrule

   rule rl_done (rg_ops >= fromInteger (n_ops) && rg_out == 0);
      $display ("[mc_ut] %0d ops, %0d reads checked, %0d errors; raw reads %0d, raw writes %0d",
                rg_ops, rg_rds, rg_errs, rg_raw_rd, rg_raw_wr);
      $display ((rg_errs == 0 && rg_rds > 0) ? "[mc_ut] PASS" : "[mc_ut] FAIL");
      $finish (0);
   endrule
endmodule

endpackage
