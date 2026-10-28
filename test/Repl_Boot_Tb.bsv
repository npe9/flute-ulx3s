// ================================================================
// Repl_Boot_Tb: full-system Bluesim run of the 2.9 MB TempleOS HolyC
// REPL blob on mkULX3S_Top -- no hardware, no UART byte-drop problem.
//
//   1. preloads the behavioral W9825G6KH SDRAM model from
//      templeos/build/ulx3s_repl.blob.bin over BDPI.  The controller
//      maps AXI 0x80000000+X to model halfword index X>>1, so this is a
//      linear poke of blob bytes {2i+1,2i} LE into model_mem[i].
//   2. lets the boot ROM run, then sends the loader header
//      {addr=0x80000000, len=0}; per boot_loader.c a zero length makes
//      it jump straight to the kernel without loading.
//   3. watches the console for the REPL prompt "> " and sends
//      "1+1;\r\n" (the known miscompile hang).
//   4. on console silence (hang) -- or a second prompt (REPL actually
//      answered) -- halts the hart THROUGH THE IN-SIM UART DMI BRIDGE,
//      using the same fixed-frame protocol as scripts/dmi.py, and dumps
//      dpc + x0..x31 + 8 words of code at dpc.
//
// Run (from flute-ulx3s):  make sim-repl
// ================================================================

package Repl_Boot_Tb;

import Vector   :: *;
import RegFile  :: *;
import FIFOF    :: *;

import ULX3S_Top :: *;

// ================================================================

// Same system clock as ULX3S_Top (src/ULX3S_Top.bsv): the UART bit time must match the DUT's.
`ifdef SYS_CLK_HZ
Integer clk_hz = `SYS_CLK_HZ;
`else
Integer clk_hz = 25_000_000;
`endif
Integer baud   = 625_000;
Integer cycles_per_bit = clk_hz / baud;    // 40 at 25 MHz

Integer max_cycles  = 600_000_000;    // global cap (24 s at 25 MHz)
Integer quiet_max   = 60_000_000;     // console silence => hang (4.8 s)
Integer wprompt_cap = 200_000_000;     // REPL reaches its prompt ~72M cycles after the jump (2026-10-28)
Integer watch_cap   = 100_000_000;     // eval is mul-heavy I64 emulation
Integer dmi_timeout = 5_000_000;      // per-request response timeout
Integer preload_end = 16777216;       // zero-fill the whole 24-bit model

Bit #(4) m_cmd_act   = 4'b0011;
Bit #(4) m_cmd_read  = 4'b0101;
Bit #(4) m_cmd_write = 4'b0100;

typedef Bit #(24) ModelAddr;

// ---------------- BDPI blob access (test/sim_preload.c)

import "BDPI" function Bit #(32) c_blob_open ();    // open + return halfword count
import "BDPI" function Bit #(16) c_blob_half (Bit #(32) idx);
// Console mode (test/sim_preload.c): with SIM_PASS_STR set, the image is judged on its console
// (e.g. OpenSBI + Linux to "tick 2"): no prompt/command phases, the sim ends when the string
// appears.  SIM_MAX_CYCLES overrides the global cap.
import "BDPI" function ActionValue #(Bit #(8))  c_sim_mode ();
import "BDPI" function ActionValue #(Bit #(64)) c_sim_max_cycles (Bit #(64) dflt);
import "BDPI" function ActionValue #(Bit #(8))  c_console (Bit #(8) c);

// ================================================================

typedef enum {P_PRELOAD, P_WARMUP, P_HDR, P_WAITPROMPT, P_CMD, P_WATCH,
              P_CRASHMD, P_DMI, P_DONE, P_CONSOLE} Phase deriving (Bits, Eq);

typedef enum {D_MAGIC,
              D_RDSTATUS,
              D_HALT, D_POLHALT,
              D_CLEAN0, D_CMD_DPC, D_BUSY0, D_DPC, D_DPC2,
              D_CSR_CLEAN, D_CSR_CMD, D_CSR_BUSY, D_CSR_DATA,
              D_REG_CLEAN, D_REG_CMD, D_REG_BUSY, D_REG_DATA,
              D_MEM_SBCS, D_MEM_ADDR, D_MEM_SPACER, D_MEM_DATA,
              D_FINISH } DSt deriving (Bits, Eq);

// ----------------------------------------------------------------
// helpers

// Request bytes for a DMI state: [op, addr, data(4, big-endian)]; the
// magic is 8 bytes and expects no response.  Every other state is a
// fixed 6-byte request whose response is interpreted while dst is
// unchanged (see rl_dmi_resp).
// Timeout diagnostic memory map: 1216 reads.  i<64: MEM_TRAP_SNAP block
// (0x81800100; slot 18=cause, 19=epc, 20=tval per TrapSnapPublish);
// 64..1119: linear dump of the 4 KB stack window 0x81FFF000..0x82000000;
// 1120..1151: host-slot table head 0x81801000..0x8180107c (disp fn slot
// at +0x60, fallback vec at +0x68); 1152..1215: the fault region around
// 0x80200354 (image/code that Md insists is zero).
function Bit #(32) diag_addr (Bit #(16) i);
   if (i < 64)        return 32'h8180_0100 + (zeroExtend (i) << 2);
   else if (i < 1120) return 32'h81FF_F000 + (zeroExtend (i - 64) << 2);
   else if (i < 1152) return 32'h8180_1000 + (zeroExtend (i - 1120) << 2);
   else               return 32'h8020_0000 + (zeroExtend (i - 1152) << 2);
endfunction

function Vector #(8, Bit #(8)) req_bytes (DSt s, Bit #(8) dreg,
                                          Bit #(32) mem_base, Bit #(16) mem_i,
                                          Bit #(8) csr_idx);
   Vector #(8, Bit #(8)) v = replicate (0);
   Bit #(32) cmd   = 32'h0022_0000 | (32'h0000_1000 + zeroExtend (dreg));
   Bit #(32) ccmd  = 32'h0022_0000 | (32'h0000_0341 + zeroExtend (csr_idx));
   Bit #(32) maddr = diag_addr (mem_i);
   case (s)
      D_MAGIC: begin
         v [0] = 8'hDB; v [1] = 8'h53; v [2] = 8'h44; v [3] = 8'h4D;
         v [4] = 8'h01; v [5] = 8'h02; v [6] = 8'h03; v [7] = 8'h04;
      end
      D_RDSTATUS: begin
         v [0] = 8'h72; v [1] = 8'h11;
      end
      D_HALT: begin
         v [0] = 8'h77; v [1] = 8'h10;
         v [2] = 8'h80; v [3] = 8'h00; v [4] = 8'h00; v [5] = 8'h01;
      end
      D_POLHALT: begin
         v [0] = 8'h72; v [1] = 8'h11;
      end
      D_CLEAN0, D_REG_CLEAN, D_CSR_CLEAN: begin
         v [0] = 8'h77; v [1] = 8'h16;
         v [4] = 8'h07;
      end
      D_CMD_DPC: begin
         v [0] = 8'h77; v [1] = 8'h17;
         v [3] = 8'h22; v [4] = 8'h07; v [5] = 8'hB1;
      end
      D_BUSY0, D_REG_BUSY, D_CSR_BUSY: begin
         v [0] = 8'h72; v [1] = 8'h16;
      end
      D_DPC, D_DPC2, D_REG_DATA, D_CSR_DATA: begin
         v [0] = 8'h72; v [1] = 8'h04;
      end
      D_REG_CMD: begin
         v [0] = 8'h77; v [1] = 8'h17;
         v [2] = cmd [31:24]; v [3] = cmd [23:16];
         v [4] = cmd [15:8];  v [5] = cmd [7:0];
      end
      D_CSR_CMD: begin
         v [0] = 8'h77; v [1] = 8'h17;
         v [2] = ccmd [31:24]; v [3] = ccmd [23:16];
         v [4] = ccmd [15:8];  v [5] = ccmd [7:0];
      end
      D_MEM_SBCS: begin
         v [0] = 8'h77; v [1] = 8'h38;
         v [2] = 8'h00; v [3] = 8'h14; v [4] = 8'h70;
      end
      D_MEM_ADDR: begin
         v [0] = 8'h77; v [1] = 8'h39;
         v [2] = maddr [31:24]; v [3] = maddr [23:16];
         v [4] = maddr [15:8];  v [5] = maddr [7:0];
      end
      D_MEM_SPACER: begin
         v [0] = 8'h72; v [1] = 8'h11;
      end
      D_MEM_DATA: begin
         v [0] = 8'h72; v [1] = 8'h3C;
      end
      default: v = replicate (0);
   endcase
   return v;
endfunction

function Bit #(4) req_len_of (DSt s);
   return (s == D_MAGIC) ? 8 : 6;
endfunction

// ================================================================

(* synthesize *)
module mkRepl_Boot_Tb (Empty);

   ULX3S_Top_IFC dut <- mkULX3S_Top;

   // --------------------------------------------------
   // Shared state (declared before any rule that uses it)

   // phase / script
   Reg #(Phase)     phase    <- mkReg (P_PRELOAD);
   Reg #(Bit #(40)) rg_cycle <- mkReg (0);
   Reg #(Bool)      console_mode <- mkReg (False);
   Reg #(Bit #(40)) rg_max_cycles <- mkReg (fromInteger (max_cycles));
   Reg #(Bit #(40)) ph_enter <- mkReg (0);
   Reg #(Bit #(32)) ph_idx   <- mkReg (0);
   Reg #(Bit #(32)) warmup   <- mkReg (500_000);

   // console observation.  Cross-rule signaling keeps the rule-ordering
   // graph acyclic: rl_tx owns saw_prompt (sticky, set on "> " decode);
   // rl_saw_w forwards it to the phase rules through a wire; tx_cap is
   // written only by the phase-transition rules and read only by rl_tx
   // (one ordering edge rl_tx -> writers, no cycle).  The earlier
   // PulseWire version never delivered: tx_cap stayed False and the DMI
   // dump decoded 446k re-sent requests as console bytes.
   Reg #(Bit #(40)) quiet        <- mkReg (0);
   Reg #(Bit #(8))  prev_txc     <- mkReg (0);
   Reg #(Bit #(8))  prev2_txc    <- mkReg (0);
   Wire #(Bool)     w_char       <- mkDWire (False);
   Reg #(Bool)      saw_prompt   <- mkReg (False);
   Wire #(Bool)     saw_w        <- mkDWire (False);
   Reg #(Bool)      tx_cap       <- mkReg (False);

   // DMI session
   Reg #(DSt)      dst       <- mkReg (D_MAGIC);
   Reg #(Bool)     send_req  <- mkReg (False);
   Reg #(Bool)     rsp_pending <- mkReg (False);
   Reg #(Bit #(8)) dreg      <- mkReg (0);
   Reg #(Bit #(16)) mem_i    <- mkReg (0);
   Reg #(Bit #(8)) csr_idx   <- mkReg (0);
   Reg #(Bit #(8)) poll_ct   <- mkReg (0);
   Reg #(Bit #(32)) dpc      <- mkReg (0);
   Reg #(Bit #(32)) mem_base <- mkReg (0);
   Reg #(Bit #(32)) req_age  <- mkReg (0);
   Reg #(Bool)     repl_responded <- mkReg (False);

   // DMI request byte buffer (filled one shot, drained into f_rx_host)
   Reg #(Vector #(8, Bit #(8))) req_buf <- mkReg (replicate (0));
   Reg #(Bit #(4)) req_len <- mkReg (0);
   Reg #(Bit #(4)) req_ptr <- mkReg (0);

   Vector #(6, Reg #(Bit #(8))) fr <- replicateM (mkReg (0));
   Reg #(Bit #(3)) fr_n <- mkReg (0);
   FIFOF #(Bit #(1)) f_frames <- mkSizedFIFOF (8);
   Reg #(Bit #(32)) drain_cnt <- mkReg (0);

   // host -> DUT serial
   FIFOF #(Bit #(8)) f_rx_host <- mkSizedFIFOF (32);
   Reg #(Bit #(4))  rx_bit  <- mkReg (0);
   Reg #(Bit #(16)) rx_tmr  <- mkReg (0);
   Reg #(Bool)      rx_busy <- mkReg (False);
   Reg #(Bit #(1))  rg_rxd  <- mkReg (1);

   // DUT TX pin sampling
   Reg #(Bit #(1))  tx_prev   <- mkReg (1);
   Reg #(Bit #(4))  tx_cnt    <- mkReg (0);
   Reg #(Bit #(8))  tx_sh     <- mkReg (0);
   Reg #(Bool)      tx_active <- mkReg (False);
   Reg #(Bit #(16)) tx_timer  <- mkReg (0);
   Reg #(Bit #(16)) tx_frame_age <- mkReg (0);

   Reg #(Bit #(8)) prev_leds <- mkReg (8'hFF);

   // blob preload (poked from rl_model, the model_mem writer)
   Reg #(Bool)      pl_opened <- mkReg (False);
   Reg #(Bool)      pl_done   <- mkReg (False);
   Reg #(Bit #(32)) pl_idx    <- mkReg (0);
   Reg #(Bit #(32)) pl_total  <- mkReg (0);
   Reg #(Bit #(32)) pl_dump_i <- mkReg (0);

   // --------------------------------------------------
   // Behavioral SDRAM model (identical to SoC_Boot_Tb;
   // per-beat prints gated behind TB_PROBES)

   RegFile #(ModelAddr, Bit #(16)) model_mem <- mkRegFile (0, 16777215);

   Reg #(Bit #(4))  m_cmd_d1  <- mkReg (4'b0111);
   Reg #(Bit #(13)) m_a_d1    <- mkReg (0);
   Reg #(Bit #(2))  m_ba_d1   <- mkReg (0);

   Vector #(4, Reg #(Bit #(13))) m_open_row <- replicateM (mkReg (0));

   Reg #(Bool)      m_reading  <- mkReg (False);
   Reg #(Bool)      m_writing  <- mkReg (False);
   Reg #(Bit #(2))  m_cas_cnt  <- mkReg (0);
   Reg #(Bit #(4))  m_beat     <- mkReg (0);
   Reg #(Bit #(2))  m_bank     <- mkReg (0);
   Reg #(Bit #(9))  m_col      <- mkReg (0);
   Reg #(Bit #(2))  m_wr_bank  <- mkReg (0);
   Reg #(Bit #(9))  m_wr_col   <- mkReg (0);
   Reg #(Bit #(16)) m_dq       <- mkReg (0);

   function ModelAddr m_addr ();
      return { m_bank, m_open_row [m_bank], m_col } + extend (m_beat);
   endfunction

   rule rl_model;
      let cur_cmd = { dut.sdram_cs_n, dut.sdram_ras_n, dut.sdram_cas_n, dut.sdram_we_n };
      let cur_a   = dut.sdram_a;
      let cur_ba  = dut.sdram_ba;
      let cur_dq  = dut.sdram_dq_out;
      let cur_dqm = dut.sdram_dqm;

      Bit #(2)  n_cas_cnt = m_cas_cnt;
      Bool      n_reading = m_reading;
      Bool      n_writing = m_writing;
      Bit #(4)  n_beat    = m_beat;
      Bit #(16) n_dq      = m_dq;
      Bool      n_drive   = False;

      if (m_cas_cnt != 0)
         n_cas_cnt = m_cas_cnt - 1;
      else if (m_reading) begin
         n_dq      = model_mem.sub (m_addr ());
         n_drive   = True;
`ifdef MDL_PROBES
         // granule 0 only (addr < 16): model addrs 0-15 exist only for
         // row 0/bank 0, i.e. blob byte offsets 0-31 -- cheap, exact
         if (m_addr () < 16)
            $display ("%0t MDLRD beat=%0d addr=%0h dq=%0h | col=%0h row=%0h bank=%0h cas=%0d",
                      $time, m_beat, m_addr (), n_dq,
                      m_col, m_open_row [m_bank], m_bank, m_cas_cnt);
`endif
         if (m_beat == 7)
            n_reading = False;
         else
            n_beat = m_beat + 1;
      end

      Bool wr_new = (cur_cmd == m_cmd_write);

      // Blob preload owns the model write port until done.  The
      // controller interleaves bank bits into the address
      // (bank = granule[6:5] = byte offset [10:9]), so the model
      // address is the halfword index with bit fields rotated:
      //   model_addr = {idx[10:9] (bank), idx[23:11] (row), idx[8:0] (col)}
      // After the blob, keep writing ZEROS to the end of the model:
      // Bluesim's RegFile malloc is NOT zeroed, so never-written SDRAM
      // reads as heap garbage (observed 0xaaaaaaaa) that varies RUN TO
      // RUN -- the REPL boot (memfs slot scan, stack-edge reads) is
      // nondeterministic against it.  Zeroing once makes sim boots
      // reproducible (and matches a freshly-zeroed model).
      if (pl_opened && ! pl_done) begin
         Bit #(32) p_addr = ((pl_idx & 32'h0000_0600) << 13)
                          | ((pl_idx >> 2) & 32'h003F_FE00)
                          | (pl_idx & 32'h0000_01FF);
         Bit #(16) p_data = (pl_idx < pl_total) ? c_blob_half (pl_idx) : 16'h0;
         model_mem.upd (truncate (p_addr), p_data);
         if (pl_idx [19:0] == 0)
            $display ("[tb] preload %0d / %0d halfwords (zero-fill to %0h)",
                      pl_idx, pl_total, fromInteger (preload_end));
         if (pl_idx + 1 >= fromInteger (preload_end))
            pl_done <= True;
         pl_idx <= pl_idx + 1;
      end
      else if (wr_new || m_writing) begin
         Bit #(2)  w_bank = wr_new ? cur_ba : m_wr_bank;
         Bit #(9)  w_col  = wr_new ? cur_a [8:0] : m_wr_col;
         Bit #(4)  w_beat = wr_new ? 0 : m_beat;
         ModelAddr w_addr = { w_bank, m_open_row [w_bank], w_col } + extend (w_beat);
         if (cur_dqm != 2'b11) begin
            Bit #(16) d_old = model_mem.sub (w_addr);
            Bit #(16) d_new = cur_dq;
            Bit #(16) merged = zeroExtend ((cur_dqm [1] == 1'b1) ? d_old [15:8] : d_new [15:8]) << 8
                             | zeroExtend ((cur_dqm [0] == 1'b1) ? d_old [7:0]  : d_new [7:0]);
            model_mem.upd (w_addr, merged);
`ifdef MDL_PROBES
            if (w_addr < 16)
               $display ("%0t MDLWR beat=%0d addr=%0h dq=%0h dqm=%0b",
                         $time, w_beat, w_addr, cur_dq, cur_dqm);
`endif
         end
         if (wr_new) begin
            m_wr_bank <= cur_ba;
            m_wr_col  <= cur_a [8:0];
            n_beat    = 1;
            n_writing = True;
         end
         else if (m_beat == 7)
            n_writing = False;
         else
            n_beat = m_beat + 1;
      end

      if (m_cmd_d1 == m_cmd_act) begin
         m_open_row [m_ba_d1] <= m_a_d1 [12:0];
`ifdef MDL_PROBES
         $display ("%0t MDLCMd ACT bank=%0h row=%0h", $time, m_ba_d1, m_a_d1 [12:0]);
`endif
      end

      else if (m_cmd_d1 == m_cmd_read) begin
         m_bank  <= m_ba_d1;
         m_col   <= m_a_d1 [8:0];
         // Real W9825G6KH: first beat driven 2 cycles after the READ cmd
         // is clocked in, i.e. during this decode cycle; the controller
         // (registered cmd, t_cas_first=3) samples it at end of cycle.
         n_dq      = model_mem.sub ({ m_ba_d1, m_open_row [m_ba_d1], m_a_d1 [8:0] });
         n_drive   = True;
         n_reading = True;
         n_beat    = 1;
      end

      if (n_drive)
         m_dq <= n_dq;

      m_cas_cnt <= n_cas_cnt;
      m_reading <= n_reading;
      m_writing <= n_writing;
      m_beat    <= n_beat;

      m_cmd_d1 <= cur_cmd;
      m_a_d1   <= cur_a;
      m_ba_d1  <= cur_ba;

   endrule

   // DQ into the DUT from the model's register, in its own rule: the SDRAM controller may need its
   // dq_in method scheduled apart from the command/address outputs rl_model reads (the linux-isa
   // memlat controller does: G0004 when both were in rl_model).  Same timing: m_dq is a register.
   rule rl_model_dq;
      dut.sdram_dq_in (m_dq);
   endrule

   // --------------------------------------------------
   // Phase 1: preload the blob into the SDRAM model.
   //
   // The pokes happen INSIDE rl_model below: it is the only other writer
   // of model_mem, and two writers would conflict (rl_model fires every
   // cycle and would starve a separate preload rule).  While preloading,
   // DUT writes to the model are dropped -- the only early SDRAM traffic
   // is the boot ROM's probe word at 0x81FFFF00, whose loss is cosmetic
   // (the T<h> readback banner prints zeros).

   rule rl_preload_open (! pl_opened);
      let n     = c_blob_open ();
      pl_total  <= n;
      pl_opened <= True;
      $display ("[tb] preload: %0d halfwords", n);
      let md <- c_sim_mode;
      let mx <- c_sim_max_cycles (fromInteger (max_cycles));
      console_mode  <= (md != 0);
      rg_max_cycles <= truncate (mx);
      if (md != 0) $display ("[tb] console mode: pass on SIM_PASS_STR, cap %0d cycles", mx);
   endrule

   // --------------------------------------------------
   // Host -> DUT serial bit-banger (drains f_rx_host at 8N1)

   rule rl_rx_xmit (f_rx_host.notEmpty);
      if (! rx_busy) begin
         if (rx_tmr == 0) begin
            rx_busy <= True;
            rx_bit  <= 0;
            rx_tmr  <= fromInteger (cycles_per_bit - 1);
            rg_rxd  <= 0;                    // start bit
         end
         else
            rx_tmr <= rx_tmr - 1;
      end
      else if (rx_tmr != 0)
         rx_tmr <= rx_tmr - 1;
      else begin
         rx_tmr <= fromInteger (cycles_per_bit - 1);
         if (rx_bit < 8) begin
            let b = f_rx_host.first;
            rg_rxd <= b [rx_bit];
            rx_bit <= rx_bit + 1;
         end
         else begin
            rg_rxd   <= 1;                 // stop bit
            rx_busy  <= False;
            rx_bit   <= 0;
            f_rx_host.deq;
         end
      end
   endrule

   // --------------------------------------------------
   // Phase 2: header feeder.  {addr=0x80000000 LE, len=0 LE}: a zero
   // length makes the boot ROM jump to the kernel without loading.

   rule rl_ph_preload (phase == P_PRELOAD && pl_done);
      phase <= P_WARMUP;
   endrule

   // post-preload model readback: read model_mem[0] 32 times, then
   // model_mem[1..31] once each (one sub per rule -- RegFile read ports).
   // If sub(0) flips between values, the port sharing itself is broken.
`ifdef MDL_PROBES
   rule rl_pl_dump (pl_done && (pl_dump_i < 64));
      if (pl_dump_i < 32)
         $display ("[tb] rdback sub(0) #%0d = %04x (blob[0] = %04x)",
                   pl_dump_i, model_mem.sub (0), c_blob_half (0));
      else
         $display ("[tb] rdback sub(%0d) = %04x (blob[%0d] = %04x)",
                   pl_dump_i - 32, model_mem.sub (truncate (pl_dump_i - 32)),
                   pl_dump_i - 32, c_blob_half (pl_dump_i - 32));
      pl_dump_i <= pl_dump_i + 1;
   endrule
`endif

   rule rl_ph_warmup (phase == P_WARMUP);
      if (warmup != 0)
         warmup <= warmup - 1;
      else begin
         phase <= P_HDR;
         ph_idx <= 0;
         $display ("[tb] sending zero-length header (jump to 0x80000000)");
      end
   endrule

   rule rl_feed_hdr (phase == P_HDR && f_rx_host.notFull);
      // get_u32 is little-endian: bytes 00 00 00 80 = 0x80000000,
      // then len = 0 (jump without loading)
      f_rx_host.enq ((ph_idx == 3) ? 8'h80 : 8'h00);
      ph_idx <= ph_idx + 1;
      if (ph_idx == 7) begin
         phase    <= console_mode ? P_CONSOLE : P_WAITPROMPT;
         ph_enter <= rg_cycle;
      end
   endrule

   // --------------------------------------------------
   // Phase 3: wait for the first "> " prompt, then send "1+1;\r\n"

   rule rl_waitprompt (phase == P_WAITPROMPT);
      if (saw_w) begin
         $display ("[tb] prompt seen; sending '1+1;'");
         phase      <= P_CMD;
         ph_idx     <= 0;
         saw_prompt <= False;    // one-shot: consume the prompt
      end
      else if (rg_cycle - ph_enter > fromInteger (wprompt_cap)) begin
         $display ("[tb] no prompt within %0d cycles -- DMI dump anyway", wprompt_cap);
         phase    <= P_DMI;
         dst      <= D_MAGIC;
         send_req <= True;
         tx_cap   <= True;
         ph_enter <= rg_cycle;
      end
   endrule

   rule rl_feed_cmd (phase == P_CMD && f_rx_host.notFull);
      case (ph_idx)
         0: f_rx_host.enq (8'h31);                    // '1'
         1: f_rx_host.enq (8'h2B);                    // '+'
         2: f_rx_host.enq (8'h31);                    // '1'
         3: f_rx_host.enq (8'h3B);                    // ';'
         4: f_rx_host.enq (8'h0D);                    // '\r'
         default: begin
            f_rx_host.enq (8'h0A);                    // '\n'
            phase    <= P_WATCH;
            ph_enter <= rg_cycle;
         end
      endcase
      ph_idx <= ph_idx + 1;
   endrule

   // --------------------------------------------------
   // Phase 4: watch for the answer; silence == hang

   rule rl_watch (phase == P_WATCH);
      if (saw_w) begin
         repl_responded <= True;
         $display ("[tb] REPL responded to '1+1;' (unexpected!)");
         phase <= P_DMI;
         dst      <= D_MAGIC;
         send_req <= True;
         tx_cap   <= True;
      end
      else if (quiet > fromInteger (quiet_max)) begin
         $display ("[tb] console silent for %0d cycles -- treating as hang",
                   quiet);
         // drive the crash monitor first: md the image start, the fault
         // region, and the image end (the DMI sysbus read at 0x8020xxxx
         // errors out, but the crash> md goes through the CPU's own path)
         phase    <= P_CRASHMD;
         ph_idx   <= 0;
         ph_enter <= rg_cycle;
      end
      else if (rg_cycle - ph_enter > fromInteger (watch_cap)) begin
         $display ("[tb] no answer within %0d cycles -- DMI dump anyway", watch_cap);
         phase <= P_DMI;
         dst      <= D_MAGIC;
         send_req <= True;
         tx_cap   <= True;
      end
   endrule

   // --------------------------------------------------
   // Crash-md phase: feed the crash monitor md commands, then DMI dump.
   // Commands (48 chars total): md 80000000 40 / md 80200300 60 /
   // md 80275800 40 -- image start, fault region, image end.

   function Bit #(8) md_cmd_char (Bit #(32) i);
      // "md 80000000 40\r" | "md 80200300 60\r" | "md 80275800 40\r"
      case (i)
         0:  return 8'h6D; 1:  return 8'h64; 2:  return 8'h20; 3:  return 8'h38;
         4:  return 8'h30; 5:  return 8'h30; 6:  return 8'h30; 7:  return 8'h30;
         8:  return 8'h30; 9:  return 8'h30; 10: return 8'h20; 11: return 8'h34;
         12: return 8'h30; 13: return 8'h0D; 14: return 8'h6D; 15: return 8'h64;
         16: return 8'h20; 17: return 8'h38; 18: return 8'h30; 19: return 8'h32;
         20: return 8'h30; 21: return 8'h30; 22: return 8'h33; 23: return 8'h30;
         24: return 8'h30; 25: return 8'h20; 26: return 8'h36; 27: return 8'h30;
         28: return 8'h0D; 29: return 8'h6D; 30: return 8'h64; 31: return 8'h20;
         32: return 8'h38; 33: return 8'h30; 34: return 8'h32; 35: return 8'h37;
         36: return 8'h35; 37: return 8'h38; 38: return 8'h30; 39: return 8'h30;
         40: return 8'h20; 41: return 8'h34; 42: return 8'h30; 43: return 8'h0D;
         default: return 8'h0D;
      endcase
   endfunction

   rule rl_crashmd_feed (phase == P_CRASHMD && (ph_idx < 48) && f_rx_host.notFull);
      f_rx_host.enq (md_cmd_char (ph_idx));
      ph_idx <= ph_idx + 1;
   endrule

   rule rl_crashmd_wait (phase == P_CRASHMD && (ph_idx >= 48)
                         && (rg_cycle - ph_enter > 30_000_000));
      phase <= P_DMI;
      dst      <= D_MAGIC;
      send_req <= True;
      tx_cap   <= True;
   endrule

   // forward the sticky prompt flag to the phase rules (see declaration
   // comment for why this goes through a wire)
   rule rl_saw_w;
      saw_w <= saw_prompt;
   endrule

   // --------------------------------------------------
   // Phase 5: DMI-over-UART session against the in-sim bridge
   //          (identical protocol to scripts/dmi.py)

   // One request in flight at a time: while rsp_pending the sender is
   // blocked, so req_age actually ages and a lost response hits the
   // timeout instead of re-sending forever (446k re-sends observed).
   rule rl_dmi_send (phase == P_DMI && send_req && (req_ptr >= req_len)
                     && ! rsp_pending);
      req_buf <= req_bytes (dst, dreg, mem_base, mem_i, csr_idx);
      req_len <= req_len_of (dst);
      req_ptr <= 0;
      req_age <= 0;
      $display ("[tb] req state=%0d dreg=%0d csr=%0d mem=%0d",
                pack (dst), dreg, csr_idx, mem_i);
      if (dst == D_MAGIC) begin
         // magic expects no response; queue the status check right after
         dst      <= D_RDSTATUS;
         send_req <= True;    // re-fire once the buffer has drained
      end
      else
         rsp_pending <= True; // dst stays: rl_dmi_resp interprets per dst
   endrule

   rule rl_dmi_xmit (phase == P_DMI && (req_ptr < req_len) && f_rx_host.notFull);
      f_rx_host.enq (req_buf [req_ptr]);
      req_ptr <= req_ptr + 1;
   endrule

   rule rl_dmi_resp (phase == P_DMI && rsp_pending && f_frames.notEmpty);
      f_frames.deq;
      rsp_pending <= False;
      Vector #(6, Bit #(8)) frv = readVReg (fr);
      Bit #(32) v = {frv [2], frv [3], frv [4], frv [5]};
      if (frv [1] != 0) begin
         $display ("[tb] DMI error status %02x in state %0d", frv [1], pack (dst));
         dst <= D_FINISH; send_req <= False;
      end
      else case (dst)
         D_RDSTATUS: begin
            $display ("[tb] debug bridge up, dmstatus=%08x", v);
            dst <= D_HALT; send_req <= True;
         end
         D_HALT: begin
            dst <= D_POLHALT; send_req <= True; poll_ct <= 0;
         end
         D_POLHALT:
            if (v [8] == 1'b1) begin
               $display ("[tb] hart halted");
               dst <= D_CLEAN0; send_req <= True;
            end
            else if (poll_ct > 200) begin
               $display ("[tb] hart did not halt");
               dst <= D_FINISH; send_req <= False;
            end
            else begin
               poll_ct <= poll_ct + 1; send_req <= True;
            end
         D_CLEAN0: begin
            dst <= D_CMD_DPC; send_req <= True;
         end
         D_CMD_DPC: begin
            dst <= D_BUSY0; send_req <= True; poll_ct <= 0;
         end
         D_BUSY0:
            if (v [12] == 1'b1) begin
               if (poll_ct > 200) begin
                  $display ("[tb] abstract command stuck busy");
                  dst <= D_FINISH; send_req <= False;
               end
               else begin
                  poll_ct <= poll_ct + 1; send_req <= True;
               end
            end
            else if (v [10:8] != 0) begin
               $display ("[tb] abstract command error %0d", v [10:8]);
               dst <= D_FINISH; send_req <= False;
            end
            else begin
               dst <= D_DPC; send_req <= True;
            end
         D_DPC: begin
            dpc <= v;
            $display ("[tb] DPC = %08x", v);
            dst <= D_DPC2; send_req <= True;
         end
         D_DPC2: begin
            // second read of data0: distinguishes DM read pipelining
            // (value changes) from a stable register
            $display ("[tb] DPC again = %08x", v);
            dreg <= 0;
            csr_idx <= 0;
            dst <= D_CSR_CLEAN; send_req <= True;
         end
         D_CSR_CLEAN: begin
            dst <= D_CSR_CMD; send_req <= True;
         end
         D_CSR_CMD: begin
            dst <= D_CSR_BUSY; send_req <= True; poll_ct <= 0;
         end
         D_CSR_BUSY:
            if (v [12] == 1'b1) begin
               if (poll_ct > 200) begin
                  $display ("[tb] csr abstract command stuck busy at idx %0d", csr_idx);
                  dst <= D_FINISH; send_req <= False;
               end
               else begin
                  poll_ct <= poll_ct + 1; send_req <= True;
               end
            end
            else if (v [10:8] != 0) begin
               $display ("[tb] csr abstract command error %0d at idx %0d",
                         v [10:8], csr_idx);
               dst <= D_FINISH; send_req <= False;
            end
            else begin
               dst <= D_CSR_DATA; send_req <= True;
            end
         D_CSR_DATA: begin
            case (csr_idx)
               0: $display ("[tb] mepc   = %08x", v);
               1: $display ("[tb] mcause = %08x", v);
               default: $display ("[tb] mtval  = %08x", v);
            endcase
            if (csr_idx == 2) begin
               dreg <= 0;
               dst <= D_REG_CLEAN;
            end
            else
               csr_idx <= csr_idx + 1;
            send_req <= True;
         end
         D_REG_CLEAN: begin
            dst <= D_REG_CMD; send_req <= True;
         end
         D_REG_CMD: begin
            dst <= D_REG_BUSY; send_req <= True; poll_ct <= 0;
         end
         D_REG_BUSY:
            if (v [12] == 1'b1) begin
               if (poll_ct > 200) begin
                  $display ("[tb] reg abstract command stuck busy at x%0d", dreg);
                  dst <= D_FINISH; send_req <= False;
               end
               else begin
                  poll_ct <= poll_ct + 1; send_req <= True;
               end
            end
            else if (v [10:8] != 0) begin
               $display ("[tb] reg abstract command error %0d at x%0d",
                         v [10:8], dreg);
               dst <= D_FINISH; send_req <= False;
            end
            else begin
               dst <= D_REG_DATA; send_req <= True;
            end
         D_REG_DATA: begin
            $display ("[tb] x%0d = %08x", dreg, v);
            if (dreg == 31) begin
               mem_i     <= 0;
               mem_base  <= (dpc & 32'hFFFF_FFFC);
               dst <= D_MEM_SBCS;
            end
            else
               dreg <= dreg + 1;
            send_req <= True;
         end
         D_MEM_SBCS: begin
            dst <= D_MEM_ADDR; send_req <= True;
         end
         D_MEM_ADDR: begin
            dst <= D_MEM_SPACER; send_req <= True;
         end
         D_MEM_SPACER: begin
            dst <= D_MEM_DATA; send_req <= True;
         end
         D_MEM_DATA: begin
            $display ("[tb] mem[%08x] = %08x", diag_addr (mem_i), v);
            if (mem_i == 1215) begin
               // no more requests; leaving send_req False stops the
               // rl_dmi_send flood in D_FINISH
               dst <= D_FINISH;
            end
            else begin
               mem_i <= mem_i + 1;
               dst <= D_MEM_ADDR;
               send_req <= True;
            end
         end
         default: begin dst <= D_FINISH; send_req <= False; end
      endcase
   endrule

   // Per-request response timeout + age counter, one rule: as two rules
   // they fought over req_age and the timeout could never fire (G0021).
   rule rl_dmi_age (phase == P_DMI);
      if (! rsp_pending || (req_ptr < req_len))
         req_age <= 0;
      else if (req_age > fromInteger (dmi_timeout)) begin
         if (! f_frames.notEmpty && (dst != D_FINISH)) begin
            $display ("[tb] DMI response timeout in state %0d", pack (dst));
            dst <= D_FINISH; send_req <= False; rsp_pending <= False;
         end
         req_age <= 0;
      end
      else
         req_age <= req_age + 1;
   endrule

   rule rl_dmi_finish (phase == P_DMI && dst == D_FINISH && ! rsp_pending
                       && ! f_frames.notEmpty && (req_ptr >= req_len));
      if (drain_cnt < 200_000) begin
         // drain window: let console bytes stuck behind the DMI traffic
         // reach the TX pin before we tear the sim down
         drain_cnt <= drain_cnt + 1;
      end
      else begin
         $display ("[tb] done: dpc=%08x repl_responded=%0d",
                   dpc, pack (repl_responded));
         $display ("[tb] look up symbols: templeos/build/ulx3s_repl.map");
         $finish (0);
      end
   endrule

   // --------------------------------------------------
   // DUT TX pin: mid-bit sampling.  Console chars print;
   // once tx_cap latches (DMI phase entered), 0xDB-led 6-byte
   // frames are captured instead.

   rule rl_tx;
      let b = dut.serial_txd;
      // single-assignment next-state form: with -aggressive-conditions,
      // multiple textual writes to one reg across branches split into
      // conflicting parallel rule fragments.
      Bool     n_active = tx_active;
      Bit #(16) n_timer = tx_timer;
      Bit #(4)  n_cnt   = tx_cnt;
      Bit #(16) n_age   = tx_frame_age;
      Bit #(8)  n_sh    = tx_sh;
      // Frame watchdog: a 10-bit frame is ~10*cycles_per_bit cycles; if
      // tx_active outlives 10x that the decoder desynced -- report and
      // resync so one false start cannot blind the TB for a whole run.
      if (tx_active && (tx_frame_age > fromInteger (100 * cycles_per_bit))) begin
         $display ("[tb] TXDEC WATCHDOG @%0d cnt=%0d sh=%02x pin=%0b prev=%0b",
                   rg_cycle, tx_cnt, tx_sh, b, tx_prev);
         n_active = False;
         n_age    = 0;
      end
      else if (! tx_active) begin
         if (tx_prev == 1 && b == 0) begin
            n_active = True;
            n_timer  = fromInteger (cycles_per_bit + cycles_per_bit / 2);
            n_cnt    = 0;
            $display ("[tb] txstart @%0d", rg_cycle);
         end
         n_age = 0;
      end
      else begin
         n_age = tx_frame_age + 1;
         if (tx_timer != 0)
            n_timer = tx_timer - 1;
         else begin
            n_timer = fromInteger (cycles_per_bit - 1);
            if (tx_cnt == 8) begin
               // stop bit: byte complete
               n_active = False;
               n_age    = 0;
               let c = tx_sh;
               if (tx_cap) begin
                  if (fr_n == 0) begin
                     if (c == 8'hDB) begin
                        fr [0] <= c;
                        fr_n   <= 1;
                     end
                     else
                        // console bytes arriving during the DMI window
                        // (delayed flushes) are logged, not dropped
                        $display ("[tb] dmi-era console byte %02x", c);
                  end
                  else if (fr_n < 5) begin
                     fr [fr_n] <= c;
                     fr_n      <= fr_n + 1;
                  end
                  else begin
                     fr [5] <= c;
                     fr_n   <= 0;
                     if (f_frames.notFull) begin
                        f_frames.enq (?);
                        $display ("[tb] frame %02x %02x %02x %02x %02x %02x",
                                  fr [0], fr [1], fr [2], fr [3], fr [4], c);
                     end
                     else
                        $display ("[tb] FRAME DROPPED (fifo full)");
                  end
               end
               else begin
                  $display ("%c", c);
                  $display ("[tb] txc %02x", c);
                  if (console_mode) begin
                     let hit <- c_console (c);
                     if (hit != 0) begin
                        $display ("[tb] PASS: SIM_PASS_STR seen at cycle %0d", rg_cycle);
                        $finish (0);
                     end
                  end
                  w_char <= True;
                  // real REPL prompt is "> " at a line start ("\r\n> ");
                  // -- the banner itself contains "> " ("crash> ("), so
                  // require the '>' to follow a newline.
                  if ((c == 8'h20) && (prev_txc == 8'h3E)
                      && ((prev2_txc == 8'h0A) || (prev2_txc == 8'h0D)))
                     saw_prompt <= True;
                  prev2_txc <= prev_txc;
                  prev_txc <= c;
               end
            end
            else begin
               n_sh  = { b, tx_sh [7:1] };
               n_cnt = tx_cnt + 1;
            end
         end
      end
      tx_active    <= n_active;
      tx_timer     <= n_timer;
      tx_cnt       <= n_cnt;
      tx_frame_age <= n_age;
      tx_sh        <= n_sh;
      tx_prev      <= b;
   endrule

   // --------------------------------------------------
   // Global tick: pins, quiet counter, progress, cap.

   rule rl_pins;
      dut.serial_rxd (rg_rxd);
      dut.btn1 (1'b0);
      rg_cycle <= rg_cycle + 1;
      quiet <= (w_char ? 0 : quiet + 1);
      let l = dut.leds;
      if (l != prev_leds) begin
         prev_leds <= l;
         $display ("[tb] LEDs = %02x (cycle %0d)", l, rg_cycle);
      end
      if ((rg_cycle % fromInteger (50_000_000)) == 0)
         $display ("[tb] %0d cycles", rg_cycle);
      if (rg_cycle > rg_max_cycles) begin
         $display ("[tb] TIMEOUT after %0d cycles", rg_cycle);
         $finish (0);
      end
   endrule

endmodule

endpackage
