// Step-3 debug unit tb: CPU_Fetch_C (new vs stock) against a stub near-mem
// that models the response protocol (one outstanding request; response a few
// cycles after the req; "DRAM" addresses take ~12 cycles to emulate refill).
// Drives consumes exactly like CPU.bsv rl_pipe (consume + next-pc req in the
// same cycle) plus periodic redirects.

package Fetch_C_Unit_Tb;

export mkFetch_C_Unit_Tb;

import CPU_Fetch_C   :: *;
import ISA_Decls     :: *;
import Near_Mem_IFC  :: *;
import Cur_Cycle     :: *;

function Instr fn_stub_instr (WordXL a);
   // Word stream (4B words):
   //  0x1000: two c.nop (0x0001 0x0001)
   //  0x1004: two c.nop
   //  0x1008: c.nop + 32b-span-lower at [31:16] (0x0003 = ....0011)
   //  0x100C: span-upper half in [15:0]
   //  0x1010..: c.nop words; every 4th word has a c.j (0xa001 = c.j -2 loop) at [31:16]
   case (a [11:0])
      12'h000: return 32'h00010001;
      12'h004: return 32'h00010001;
      12'h008: return 32'h00030001;
      12'h00C: return 32'h00041010;
      default: begin
	 if (a [3:2] == 2'b11) return 32'h0001a001; // [31:16]=c.j -2 (16b), [15:0]=c.nop
	 else                  return 32'h00010001;
      end
   endcase
endfunction

module mkStubIMem (IMem_IFC);

   // req-written state
   Reg #(WordXL) rg_addr     <- mkRegU;
   Reg #(Bool)   rg_req_seq  <- mkReg (False);

   // tick-written state (disjoint from req-written state, mirroring the
   // real near-mem's req vs rl_capture/rl_age register split)
   Reg #(Bool)     rg_seen     <- mkReg (False);
   Reg #(Bit #(4)) rg_cnt      <- mkReg (0);
   Reg #(Bit #(4)) rg_target   <- mkReg (3);
   Reg #(Bool)     rg_rsp_v    <- mkReg (False);
   Reg #(WordXL)   rg_rsp_addr <- mkRegU;

   Wire #(Bool)   dw_valid <- mkDWire (False);
   Wire #(WordXL) dw_pc    <- mkDWire (?);
   Wire #(Instr)  dw_instr <- mkDWire (?);

   // Response latency models the backing store: "ROM" addresses (bit 28
   // clear) respond in 3 cycles; "DRAM" addresses (bit 28 set) miss and
   // take 12 (refill emulation). One outstanding request at all times, as
   // the real near-mem FSM guarantees.
   rule rl_tick;
      if (rg_seen != rg_req_seq) begin
	 rg_seen   <= rg_req_seq;
	 rg_cnt    <= 1;
	 rg_target <= (rg_addr [28] == 1'b1) ? 4'd12 : 4'd3;
	 rg_rsp_v  <= False;    // new read launched: response not ready
      end
      else if (rg_cnt != rg_target) begin
	 rg_cnt <= rg_cnt + 1;
	 if (rg_cnt + 1 == rg_target) begin
	    rg_rsp_v    <= True;
	    rg_rsp_addr <= rg_addr;
	 end
      end
   endrule

   // Mirror the real near-mem: response outputs are Wires driven by a rule
   // with an explicit condition (the shape CPU_Fetch_C's fire_when_enabled
   // rule composes with in the full SoC).
   rule rl_drive_rsp (rg_rsp_v);
      dw_valid <= True;
      dw_pc    <= rg_rsp_addr;
      dw_instr <= fn_stub_instr (rg_rsp_addr);
   endrule

   method Action req (Bit #(3) f3, WordXL addr, Priv_Mode priv,
		      Bit #(1) sstatus_SUM, Bit #(1) mstatus_MXR, WordXL satp);
      rg_addr    <= addr;
      rg_req_seq <= ! rg_req_seq;
   endmethod

   method Bool valid = dw_valid;

   method Bool is_i32_not_i16 = True;

   method WordXL pc = dw_pc;

   method Instr instr = dw_instr;

   method Bool exc = False;

   method Exc_Code exc_code = ?;

   method WordXL tval = rg_rsp_addr;

endmodule

module mkFetch_C_Unit_Tb ();

   IMem_IFC stub   <- mkStubIMem;
   IMem_IFC imem   <- mkCPU_Fetch_C (stub);

   Reg #(Bool)    rg_started <- mkReg (False);
   Reg #(Bit#(8)) rg_count  <- mkReg (0);
   Reg #(Bit#(4)) rg_since_redirect <- mkReg (0);

   // Kick: reset-vector fetch
   rule rl_start (! rg_started);
      rg_started <= True;
      imem.req (3'b010, 32'h0000_1000, m_Priv_Mode, 0, 0, 0);
      $display ("TB: start fetch at 1000");
   endrule

   // Consume + request next, like rl_pipe Feed-stageF.
   // Phase 1 (counts 0..31): sequential + redirect every 12th, ROM region.
   // Phase 2 (counts 32..): dense DRAM region (bit 28 set) -- misses every
   // word; redirect every 8th to jump around.
   (* descending_urgency = "imem_rl_fetch_next_32b, rl_consume" *)
   rule rl_consume (rg_started && imem.valid);
      let is32 = imem.is_i32_not_i16;
      WordXL npc = imem.pc + (is32 ? 4 : 2);
      if (rg_count < 32) begin
	 if (rg_since_redirect == 11) begin
	    npc = 32'h0000_1000 + (zeroExtend (rg_count [3:0]) << 4);
	    rg_since_redirect <= 0;
	 end
	 else
	    rg_since_redirect <= rg_since_redirect + 1;
      end
      else begin
	 if (rg_since_redirect == 7) begin
	    npc = 32'h1000_0000 | (zeroExtend (rg_count [5:0]) << 5);
	    rg_since_redirect <= 0;
	 end
	 else
	    rg_since_redirect <= rg_since_redirect + 1;
      end

      $display ("%0d: TB: pc=%h instr=%h %s", cur_cycle, imem.pc, imem.instr, is32 ? "i32" : "i16");
      rg_count <= rg_count + 1;
      if (rg_count == 100) begin
	 $display ("TB: DONE");
	 $finish (0);
      end
      imem.req (3'b010, npc, m_Priv_Mode, 0, 0, 0);
   endrule

   // Liveness watchdog
   rule rl_watchdog (rg_started);
      let c <- $stime;
      if (c > 200000) begin
	 $display ("TB: WEDGED at count=%0d", rg_count);
	 $finish (1);
      end
   endrule

`ifdef FETCH_DEBUG
   Reg #(Bool) rg_dbg_done <- mkReg (False);
   rule rl_trace (rg_started && ! rg_dbg_done);
      $display ("%0d: TRACE pc=%h v=%b instr=%h", cur_cycle, imem.pc, imem.valid, imem.instr);
      if (rg_count == 40) begin
	 rg_dbg_done <= True;
	 $display ("TB: trace window done");
      end
   endrule
`endif

endmodule

endpackage
