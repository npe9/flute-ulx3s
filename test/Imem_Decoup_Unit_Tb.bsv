// Step-4 unit tb: cycle-exact comparison of the stock fetch path
// (CPU_Fetch_C wrapper + stock near-mem imem adapter + stub MMU_Cache)
// against the step-4 path (CPU_Fetch_C wrapper + mkNear_Mem_Imem_Decoup
// shim + an identical stub MMU_Cache).
//
// The two sides are driven by INDEPENDENT but schedule-identical agents
// (each side's consume/redirect decisions come from its own outputs, so
// an injected divergence cannot mask itself), and their CPU-visible
// outputs (valid/pc/instr/exc) are compared every cycle.
//
// The stub models the real I-side MMU_Cache CPU-visible protocol:
//   - req at C0 -> response first valid at C0+2 (ROM) or C0+12 (DRAM,
//     bit 28 set; emulates a miss+refill);
//   - the response is re-driven every cycle and dies at the cycle after
//     the next req (age-toggle kill), like the real probe re-drive;
//   - a back-to-back req clobbers the previous read (its response never
//     surfaces; the response timing restarts from the newest req).
//
// Streams (v2 lesson list): dense RVC sequential, RVC odd-16b spans
// across word boundaries, back-to-back deposits (fetch_next + consume),
// redirects mid-stream, consume stalls (hold presentation), DRAM-latency
// misses, and a shim ma_clear + redirect recovery phase (fence.i model).
//
// STEP 5C spec-bound coverage: the consume stalls exercise "bound
// reached" (the spec-ahead counter saturates at 2 during a stall) and
// "consume-paced restart" (the next deposits drain it and the chain
// resumes); the mid-stream redirects exercise "redirect-under-bound"
// (a demand launch resets the counter, re-earning run-ahead).  The
// shim itself asserts the bound every cycle ("spec run-ahead bound
// violated"); the gate greps for ASSERT FAIL == 0.

package Imem_Decoup_Unit_Tb;

export mkImem_Decoup_Unit_Tb;

import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;

import Cur_Cycle     :: *;
import ISA_Decls     :: *;
import Near_Mem_IFC  :: *;
import MMU_Cache     :: *;
import MMU_Cache_Common :: *;
import Near_Mem_Caches  :: *;
import CPU_Fetch_C   :: *;
import AXI4_Types    :: *;

function Bit #(64) fn_stub_cword (WordXL a);
   // Word stream (4B words), mirrored in the two stub instances:
   //  0x1000: two c.nop (0x0001 0x0001)
   //  0x1004: two c.nop
   //  0x1008: c.nop + 32b-span-lower at [31:16] (0x0003)
   //  0x100C: span-upper half in [15:0] (0x1010)
   //  0x1010..: c.nop words; every 4th word has a c.j (0xa001) at [31:16]
   // DRAM region (bit 28): c.nop words (all miss; 12-cycle latency)
   Bit #(32) lo = ((a [3:2] == 2'b11) && (a [28] == 1'b0)) ? 32'h0001a001 : 32'h00010001;
   case (a [11:0])
      12'h000:  lo = 32'h00010001;
      12'h004:  lo = 32'h00010001;
      12'h008:  lo = 32'h00030001;
      12'h00C:  lo = 32'h00041010;
      default:  lo = lo;
   endcase
   return zeroExtend (lo);
endfunction

// ----------------------------------------------------------------
// Stub I-side MMU_Cache: latency-modeled CPU-side protocol only.

module mkStubMMU_Cache (MMU_Cache_IFC);

   // req-written state
   Reg #(WordXL) rg_addr     <- mkRegU;
   Reg #(Bool)   rg_req_seq  <- mkReg (False);

   // tick-written state
   Reg #(Bool)     rg_age_seen  <- mkReg (False);
   Reg #(Bool)     rg_rsp_ready <- mkReg (False);
   Reg #(Bit #(4)) rg_cnt       <- mkReg (0);

   Wire #(Bool)      dw_valid <- mkDWire (False);
   Wire #(WordXL)    dw_addr  <- mkDWire (?);
   Wire #(Bit #(64)) dw_cword <- mkDWire (?);

   Bool dram = (rg_addr [28] == 1'b1);

   // Age toggle + latency counter.  One wait cycle after each req (the
   // RAM-read + probe latency), then the remaining DRAM delay.  On a
   // back-to-back req the mismatch branch restarts the timing from the
   // newest req, modeling the clobbered read.
   rule rl_tick;
      if (rg_age_seen != rg_req_seq) begin
	 rg_age_seen  <= rg_req_seq;
	 rg_rsp_ready <= (! dram);
	 rg_cnt       <= (dram ? 2 : 0);
      end
      else if (rg_cnt != 0) begin
	 if (rg_cnt == 12) begin
	    rg_rsp_ready <= True;
	    rg_cnt       <= 0;
	 end
	 else
	    rg_cnt <= rg_cnt + 1;
      end
   endrule

   // Response drive: re-driven while the age matches; a req kills the
   // presentation at req+1 via the age gate, exactly like the probe.
   rule rl_drive (rg_rsp_ready && (rg_age_seen == rg_req_seq));
      dw_valid <= True;
      dw_addr  <= rg_addr;
      dw_cword <= fn_stub_cword (rg_addr);
   endrule

   interface Server server_reset;
      interface Put request;
	 method Action put (Token t) = noAction;
      endinterface
      interface Get response;
	 method ActionValue #(Token) get ();
	    return ?;
	 endmethod
      endinterface
   endinterface

   method Action set_verbosity (Bit #(4) verbosity) = noAction;

   method Action req (CacheOp op,
		      Bit #(3) f3,
`ifdef ISA_A
		      Bit #(7) amo_funct7,
`endif
		      WordXL addr,
		      Bit #(64) st_value,
		      Priv_Mode  priv,
		      Bit #(1)   sstatus_SUM,
		      Bit #(1)   mstatus_MXR,
		      WordXL     satp);
      rg_addr    <= addr;
      rg_req_seq <= ! rg_req_seq;
   endmethod

   method Bool       valid      = dw_valid;
   method WordXL     addr       = dw_addr;
   method Bit #(64)  cword      = dw_cword;
   method Bit #(64)  st_amo_val = 0;
   method Bool       exc        = False;
   method Exc_Code   exc_code   = ?;

   interface Server server_flush;
      interface Put request;
	 method Action put (Token t) = noAction;
      endinterface
      interface Get response;
	 method ActionValue #(Token) get ();
	    return ?;
	 endmethod
      endinterface
   endinterface

   method Action tlb_flush = noAction;

   interface mem_master = dummy_AXI4_Master_ifc;

   method Action ma_ddr4_ready = noAction;

   method Bit #(8) mv_status = 0;

   method Bool mv_perf_miss = False;

endmodule: mkStubMMU_Cache

// ----------------------------------------------------------------
// Stock near-mem imem adapter (what Near_Mem_Caches forwarded before
// Step 4): MMU_Cache CPU port -> IMem_IFC.

module mkImem_Adapter #(MMU_Cache_IFC inner) (IMem_IFC);

   method Action req (Bit #(3) f3,
		      WordXL addr,
		      Priv_Mode  priv,
		      Bit #(1)   sstatus_SUM,
		      Bit #(1)   mstatus_MXR,
		      WordXL     satp);
      Bit #(7)  amo_funct7  = ?;
      Bit #(64) store_value = ?;
      inner.req (CACHE_LD, f3,
`ifdef ISA_A
		 amo_funct7,
`endif
		 addr, store_value, priv, sstatus_SUM, mstatus_MXR, satp);
   endmethod

   method Bool     valid          = inner.valid;
   method Bool     is_i32_not_i16 = True;
   method WordXL   pc             = inner.addr;
   method Instr    instr          = truncate (inner.cword);
   method Bool     exc            = inner.exc;
   method Exc_Code exc_code       = inner.exc_code;
   method WordXL   tval           = inner.addr;

endmodule: mkImem_Adapter

// ----------------------------------------------------------------
// Testbench: two independent schedule-identical agents, cycle compare.

module mkImem_Decoup_Unit_Tb ();

   // ---------------- Golden: stock adapter + wrapper
   MMU_Cache_IFC inner_g <- mkStubMMU_Cache;
   IMem_IFC      adap_g  <- mkImem_Adapter (inner_g);
   IMem_IFC      imem_g  <- mkCPU_Fetch_C (adap_g);

   // ---------------- DUT: shim + wrapper
   MMU_Cache_IFC    inner_d <- mkStubMMU_Cache;
   Imem_Decoup_IFC  shim_d  <- mkNear_Mem_Imem_Decoup (inner_d);
   IMem_IFC         imem_d  <- mkCPU_Fetch_C (shim_d.imem);

   // ---------------- Shared probe state
   Reg #(Bool)    rg_started <- mkReg (False);
   Reg #(Bool)    rg_mask_g  <- mkReg (False);    // golden probe window
   Reg #(Bool)    rg_mask_d  <- mkReg (False);    // DUT probe window
   Reg #(WordXL)  rg_resync_pc <- mkReg (32'h0000_1010);
   Reg #(Bit #(8)) rg_mismatches <- mkReg (0);
   Reg #(Bit #(8)) rg_mismatch_prints <- mkReg (0);
   Reg #(Bit #(32)) rg_prev_delta <- mkReg (0);

   // ---------------- Per-agent state
   Reg #(Bool)     rg_started_g <- mkReg (False);
   Reg #(Bit #(8)) rg_count_g   <- mkReg (0);
   Reg #(Bit #(2)) rg_stall_g   <- mkReg (0);
   Reg #(Bool)     rg_redir_g   <- mkReg (False);
   Reg #(Bool)     rg_resync_g  <- mkReg (False);
   Reg #(Bool)     rg_probed_g  <- mkReg (False);

   Reg #(Bool)     rg_started_d <- mkReg (False);
   Reg #(Bit #(8)) rg_count_d   <- mkReg (0);
   Reg #(Bit #(2)) rg_stall_d   <- mkReg (0);
   Reg #(Bool)     rg_redir_d   <- mkReg (False);
   Reg #(Bool)     rg_resync_d  <- mkReg (False);
   Reg #(Bool)     rg_clear_d   <- mkReg (False);
   Reg #(Bool)     rg_probed_d  <- mkReg (False);

   // Kick: reset-vector fetch (idle pipe -> DUT inline-launch path)
   rule rl_start (! rg_started);
      rg_started   <= True;
      rg_started_g <= True;
      rg_started_d <= True;
      imem_g.req (3'b010, 32'h0000_1000, m_Priv_Mode, 0, 0, 0);
      imem_d.req (3'b010, 32'h0000_1000, m_Priv_Mode, 0, 0, 0);
      $display ("TB: start fetch at 1000");
   endrule

   // Stream-record FIFOs: each side records its consumes (pc, instr,
   // cycle, count); an independent rule pairs them.  (A single cross
   // FIFO would block the DUT's consume on the golden's enqueue -- a
   // tb-induced +1 artifact.)
   FIFOF #(Tuple4 #(WordXL, Bit #(32), Bit #(32), Bit #(8))) f_g <- mkSizedFIFOF (64);
   FIFOF #(Tuple4 #(WordXL, Bit #(32), Bit #(32), Bit #(8))) f_d <- mkSizedFIFOF (64);

   // STEP 5D spec-off expected-delta table: the MEASURED spec-off
   // golden (empirical re-base; deltas are monotonically non-decreasing,
   // +~1 per word cycle-locked, DRAM phase +1 per ask, fence probe net
   // +1 from count 80 -- see step5/STATUS.md "re-baseline").  The stream
   // check (pc/instr bit-exact) remains the correctness guard; this
   // table pins the re-based timing exactly.
   function Bit #(8) fn_expected_delta (Bit #(8) count);
      case (count)
         8'd0: return 8'd1;
         8'd1: return 8'd1;
         8'd2: return 8'd2;
         8'd3: return 8'd2;
         8'd4: return 8'd3;
         8'd5: return 8'd3;
         8'd6: return 8'd3;
         8'd7: return 8'd4;
         8'd8: return 8'd4;
         8'd9: return 8'd5;
         8'd10: return 8'd5;
         8'd11: return 8'd6;
         8'd12: return 8'd7;
         8'd13: return 8'd7;
         8'd14: return 8'd7;
         8'd15: return 8'd7;
         8'd16: return 8'd8;
         8'd17: return 8'd8;
         8'd18: return 8'd9;
         8'd19: return 8'd9;
         8'd20: return 8'd10;
         8'd21: return 8'd10;
         8'd22: return 8'd11;
         8'd23: return 8'd11;
         8'd24: return 8'd12;
         8'd25: return 8'd12;
         8'd26: return 8'd13;
         8'd27: return 8'd13;
         8'd28: return 8'd14;
         8'd29: return 8'd14;
         8'd30: return 8'd15;
         8'd31: return 8'd15;
         8'd32: return 8'd15;
         8'd33: return 8'd15;
         8'd34: return 8'd16;
         8'd35: return 8'd16;
         8'd36: return 8'd17;
         8'd37: return 8'd17;
         8'd38: return 8'd18;
         8'd39: return 8'd18;
         8'd40: return 8'd19;
         8'd41: return 8'd19;
         8'd42: return 8'd20;
         8'd43: return 8'd20;
         8'd44: return 8'd21;
         8'd45: return 8'd21;
         8'd46: return 8'd22;
         8'd47: return 8'd22;
         8'd48: return 8'd23;
         8'd49: return 8'd23;
         8'd50: return 8'd23;
         8'd51: return 8'd23;
         8'd52: return 8'd24;
         8'd53: return 8'd24;
         8'd54: return 8'd25;
         8'd55: return 8'd25;
         8'd56: return 8'd26;
         8'd57: return 8'd26;
         8'd58: return 8'd27;
         8'd59: return 8'd27;
         8'd60: return 8'd28;
         8'd61: return 8'd29;
         8'd62: return 8'd30;
         8'd63: return 8'd31;
         8'd64: return 8'd32;
         8'd65: return 8'd33;
         8'd66: return 8'd34;
         8'd67: return 8'd35;
         8'd68: return 8'd36;
         8'd69: return 8'd37;
         8'd70: return 8'd38;
         8'd71: return 8'd39;
         8'd72: return 8'd40;
         8'd73: return 8'd41;
         8'd74: return 8'd42;
         8'd75: return 8'd43;
         8'd76: return 8'd44;
         8'd77: return 8'd45;
         8'd78: return 8'd46;
         8'd79: return 8'd47;
         8'd80: return 8'd49;
         8'd81: return 8'd49;
         8'd82: return 8'd50;
         8'd83: return 8'd50;
         8'd84: return 8'd51;
         8'd85: return 8'd51;
         8'd86: return 8'd51;
         8'd87: return 8'd51;
         8'd88: return 8'd52;
         8'd89: return 8'd52;
         8'd90: return 8'd53;
         8'd91: return 8'd53;
         8'd92: return 8'd54;
         8'd93: return 8'd54;
         8'd94: return 8'd55;
         8'd95: return 8'd55;
         8'd96: return 8'd56;
         8'd97: return 8'd56;
         8'd98: return 8'd57;
         8'd99: return 8'd57;
         default: return 8'd57;
      endcase
   endfunction

   // =====================================================================
   // Golden-side agent

   rule rl_stall_dec_g (rg_started_g && (rg_stall_g != 0));
      rg_stall_g <= rg_stall_g - 1;
   endrule

   function WordXL fn_sched_npc (Bit #(8) count, WordXL pc, Bool is32);
      WordXL npc = pc + (is32 ? 4 : 2);
      if (count < 60) begin
	 if ((count % 12) == 11)
	    npc = 32'h0000_1000 + (zeroExtend (count [3:0]) << 4);
      end
      else if (count < 80) begin
	 if ((count % 8) == 7)
	    npc = 32'h1000_0000 | (zeroExtend (count [5:0]) << 5);
	 else
	    npc = 32'h1000_0000 | (zeroExtend (count [5:0]) << 3);
      end
      else begin
	 if ((count % 12) == 11)
	    npc = 32'h0000_1000 + (zeroExtend (count [3:0]) << 4);
      end
      return npc;
   endfunction

   (* descending_urgency = "imem_g_rl_fetch_next_32b, rl_consume_g" *)
   rule rl_consume_g (rg_started_g
		      && imem_g.valid
		      && (rg_stall_g == 0)
		      && ! rg_mask_g
		      && ! rg_redir_g
		      && ! rg_resync_g);
      let is32 = imem_g.is_i32_not_i16;
      WordXL npc = fn_sched_npc (rg_count_g, imem_g.pc, is32);
      let cyc <- cur_cycle;

      $display ("%0d: TB: g pc=%h instr=%h %s", cyc, imem_g.pc, imem_g.instr, is32 ? "i32" : "i16");
      f_g.enq (tuple4 (imem_g.pc, imem_g.instr, cyc, rg_count_g));
      rg_count_g <= rg_count_g + 1;
      if ((rg_count_g % 9) == 4)
	 rg_stall_g <= 2;

      imem_g.req (3'b010, npc, m_Priv_Mode, 0, 0, 0);
   endrule

   rule rl_redirect_arm_g (rg_started_g && (rg_count_g == 80) && ! rg_probed_g
			   && ! rg_mask_g && ! rg_redir_g && ! rg_resync_g);
      rg_redir_g  <= True;
      rg_probed_g <= True;
      rg_mask_g   <= True;
   endrule

   rule rl_redirect_g (rg_redir_g);
      rg_redir_g  <= False;
      rg_resync_g <= True;
      imem_g.req (3'b010, rg_resync_pc, m_Priv_Mode, 0, 0, 0);
      $display ("%0d: TB: g redirect to %h", cur_cycle, rg_resync_pc);
   endrule

   rule rl_resync_g (rg_resync_g && imem_g.valid && (imem_g.pc == rg_resync_pc));
      rg_resync_g <= False;
      rg_mask_g   <= False;
      $display ("%0d: TB: g resync ok", cur_cycle);
   endrule

   // =====================================================================
   // DUT-side agent (identical schedule; plus the fence.i clear probe)

   rule rl_stall_dec_d (rg_started_d && (rg_stall_d != 0));
      rg_stall_d <= rg_stall_d - 1;
   endrule

   (* descending_urgency = "imem_d_rl_fetch_next_32b, rl_consume_d, shim_d_rl_shim_step" *)
   rule rl_consume_d (rg_started_d
		      && imem_d.valid
		      && (rg_stall_d == 0)
		      && ! rg_mask_d
		      && ! rg_redir_d
		      && ! rg_resync_d);
      let is32 = imem_d.is_i32_not_i16;
      WordXL npc = fn_sched_npc (rg_count_d, imem_d.pc, is32);
      let cyc <- cur_cycle;

      $display ("%0d: TB: d pc=%h instr=%h %s", cyc, imem_d.pc, imem_d.instr, is32 ? "i32" : "i16");
      f_d.enq (tuple4 (imem_d.pc, imem_d.instr, cyc, rg_count_d));
      rg_count_d <= rg_count_d + 1;
      if ((rg_count_d % 9) == 4)
	 rg_stall_d <= 2;

      imem_d.req (3'b010, npc, m_Priv_Mode, 0, 0, 0);
   endrule

   // Fence.i probe step 1: clear the shim (drops the outstanding DRAM
   // ask, exactly like a flush killing a wrong-path presentation in the
   // real system), mask the compare, and arm the redirect.
   rule rl_clear_d (rg_started_d && (rg_count_d == 80) && ! rg_clear_d
		    && ! rg_mask_d && ! rg_redir_d && ! rg_resync_d);
      shim_d.ma_clear;
      rg_clear_d <= True;
      rg_mask_d  <= True;
      $display ("%0d: TB: d ma_clear (fence.i probe)", cur_cycle);
   endrule

   rule rl_redirect_arm_d (rg_clear_d && ! rg_redir_d && ! rg_probed_d);
      rg_redir_d  <= True;
      rg_probed_d <= True;
   endrule

   // Fence.i probe step 2 (one cycle after the clear, so the shim has
   // observed it before this ask lands): redirect to a ROM target.
   rule rl_redirect_d (rg_redir_d);
      rg_redir_d  <= False;
      rg_resync_d <= True;
      imem_d.req (3'b010, rg_resync_pc, m_Priv_Mode, 0, 0, 0);
      $display ("%0d: TB: d redirect to %h after clear", cur_cycle, rg_resync_pc);
   endrule

   // Fence.i probe step 3: the DUT must come back to presenting the
   // redirect target; then unmask the comparison.
   rule rl_resync_d (rg_resync_d && imem_d.valid && (imem_d.pc == rg_resync_pc));
      rg_resync_d <= False;
      rg_mask_d   <= False;
      $display ("%0d: TB: d resync ok", cur_cycle);
   endrule

   // Independent stream/delta comparison (never gates the consumes).
   rule rl_compare (f_g.notEmpty && f_d.notEmpty && ! rg_mask_g && ! rg_mask_d);
      match { .g_pc, .g_instr, .g_cycle, .g_count } = f_g.first;
      match { .d_pc, .d_instr, .d_cycle, .d_count } = f_d.first;
      f_g.deq;
      f_d.deq;
      Bit #(32) exp_delta = zeroExtend (fn_expected_delta (d_count));
      Bit #(32) act_delta = d_cycle - g_cycle;
      // The expected-delta formula counts the divergent events
      // (redirects, DRAM-latency asks) exactly; individual asks can
      // additionally land +/-1 cycle depending on whether speculative
      // coverage was inflight- or same-cycle-spec-based (unit-tb
      // inventoried).  What must NEVER happen: an unexplained delta
      // GROWTH across a straight-line run (the chain-death signature)
      // or a stream divergence.  So: exact stream check, and a delta
      // band of [-2, +2] around the formula, plus a hard floor at the
      // previous delta minus 2 (no lasting catch-up either).
      if ((g_count != d_count) || (g_pc != d_pc) || (g_instr != d_instr)) begin
	 rg_mismatches <= rg_mismatches + 1;
	 if (rg_mismatch_prints < 20) begin
	    rg_mismatch_prints <= rg_mismatch_prints + 1;
	    $display ("%0d: TB: STREAM MISMATCH g(c=%0d pc=%h i=%h) d(c=%0d pc=%h i=%h)",
		      cur_cycle, g_count, g_pc, g_instr, d_count, d_pc, d_instr);
	 end
      end
      else if (   (act_delta != exp_delta)
	       || (act_delta + 2 < rg_prev_delta)) begin
	 rg_mismatches <= rg_mismatches + 1;
	 if (rg_mismatch_prints < 20) begin
	    rg_mismatch_prints <= rg_mismatch_prints + 1;
	    $display ("%0d: TB: DELTA MISMATCH count=%0d g_cycle=%0d d_cycle=%0d delta=%0d expected=%0d prev=%0d",
		      cur_cycle, d_count, g_cycle, d_cycle, act_delta, exp_delta, rg_prev_delta);
	 end
      end
      rg_prev_delta <= act_delta;
   endrule

   // =====================================================================
   // Done + verdict: the DUT is always last (it lags by the divergence
   // delta).  At d_count==100 every golden consume must have been
   // recorded and matched (both FIFOs empty).
   rule rl_done (rg_started_d && (rg_count_d == 100));
      if ((rg_mismatches == 0) && (! f_g.notEmpty) && (! f_d.notEmpty))
	 $display ("TB: DONE, STREAM-EXACT MATCH, DELTAS AS EXPECTED");
      else
	 $display ("TB: DONE, %0d MISMATCHES, g_count=%0d d_count=%0d gq=%b dq=%b",
		   rg_mismatches, rg_count_g, rg_count_d, f_g.notEmpty, f_d.notEmpty);
      $finish (((rg_mismatches == 0) && (! f_g.notEmpty) && (! f_d.notEmpty)) ? 0 : 1);
   endrule

   // Liveness watchdog
   rule rl_watchdog (rg_started);
      let c <- $stime;
      if (c > 2000000) begin
	 $display ("TB: WEDGED g_count=%0d d_count=%0d mismatches=%0d maskg=%b maskd=%b resync_g=%b resync_d=%b",
		   rg_count_g, rg_count_d, rg_mismatches, rg_mask_g, rg_mask_d, rg_resync_g, rg_resync_d);
	 $finish (1);
      end
   endrule

`ifdef SHIM_TB_TRACE
   // Windowed probe of both sides' CPU-visible response signals.
   Reg #(Bit #(32)) rg_cyc_cnt <- mkReg (0);
   rule rl_dbg (rg_started_d);
      rg_cyc_cnt <= rg_cyc_cnt + 1;
      if ((rg_cyc_cnt >= 395) && (rg_cyc_cnt <= 412))
	 $display ("%0d: DBG d32 v=%b pc=%h | wrapd v=%b pc=%h i=%h | wrapg v=%b pc=%h i=%h | sg=%0d mg=%b sm=%0d fgnf=%b cg=%0d cd=%0d",
		   rg_cyc_cnt, shim_d.imem.valid, shim_d.imem.pc,
		   imem_d.valid, imem_d.pc, imem_d.instr,
		   imem_g.valid, imem_g.pc, imem_g.instr,
		   rg_stall_g, rg_mask_g, rg_stall_d, f_g.notFull, rg_count_g, rg_count_d);
   endrule
`endif

endmodule: mkImem_Decoup_Unit_Tb

endpackage: Imem_Decoup_Unit_Tb
