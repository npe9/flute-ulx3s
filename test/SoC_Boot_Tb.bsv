// ================================================================
// SoC_Boot_Tb: full-system Bluesim test of mkULX3S_Top.
//
// Wires the real SoC top (CPU + caches + fabric + boot ROM + 16550 +
// UART pins + DMI bridge) to the behavioral W9825G6KH model from
// Sdram_Tb.  The TB plays the UART host: waits for the boot banner,
// sends the load header + sw/hello.bin, then decodes the TX stream and
// prints it.  Goal: reproduce (or exonerate) the hardware failure where
// D-side SDRAM reads verify correct but the first instruction fetch of
// the loaded image returns zeros (E00000002 at the entry point).
//
// Run (from flute-ulx3s):
//   bsc -sim -g mkSoC_Boot_Tb <same -p path and defines as Makefile> \
//       -bdir build/bsc-sim test/SoC_Boot_Tb.bsv
//   bsc -sim -e mkSoC_Boot_Tb -o build/soc_boot_tb ...
//   ./build/soc_boot_tb
// ================================================================

package SoC_Boot_Tb;

import Vector   :: *;
import RegFile  :: *;
import FIFOF    :: *;

import ULX3S_Top :: *;

// fn_hello_bytes (i) -> byte i of sw/hello.bin (generated)
`include "fn_hello_bytes.bsvi"

// ================================================================

// Same system clock as ULX3S_Top (src/ULX3S_Top.bsv): the UART bit time must match the DUT's.
`ifdef SYS_CLK_HZ
Integer clk_hz = `SYS_CLK_HZ;
`else
Integer clk_hz = 25_000_000;
`endif
Integer baud   = 625_000;
Integer cycles_per_bit = clk_hz / baud;    // 40 at 25 MHz

Integer max_cycles = 70_000_000;    // > boot ROM's 60M-cycle repair window

// Model: one 16-bit halfword per {bank, row, col}
typedef Bit #(24) ModelAddr;    // {bank[1:0], row[12:0], col[8:0]}

Bit #(4) m_cmd_act   = 4'b0011;
Bit #(4) m_cmd_read  = 4'b0101;
Bit #(4) m_cmd_write = 4'b0100;

// ================================================================

(* synthesize *)
module mkSoC_Boot_Tb (Empty);

   ULX3S_Top_IFC dut <- mkULX3S_Top;

   // --------------------------------------------------
   // Behavioral SDRAM model (lifted from Sdram_Tb.bsv)

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
`ifdef TB_PROBES
         $display ("%0t MDLRD beat=%0d addr=%0h dq=%0h", $time, m_beat, m_addr (), model_mem.sub (m_addr ()));
`endif
         if (m_beat == 7)
            n_reading = False;
         else
            n_beat = m_beat + 1;
      end

      Bool wr_new = (cur_cmd == m_cmd_write);
      if (wr_new || m_writing) begin
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
`ifdef TB_PROBES
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

      if (m_cmd_d1 == m_cmd_act)
         m_open_row [m_ba_d1] <= m_a_d1 [12:0];

      else if (m_cmd_d1 == m_cmd_read) begin
         m_bank  <= m_ba_d1;
         m_col   <= m_a_d1 [8:0];
         // Real W9825G6KH: first beat driven 2 cycles after the READ cmd
         // is clocked in, i.e. during this decode cycle; the controller
         // (registered cmd, t_cas_first=2) samples it at end of cycle.
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

      dut.sdram_dq_in (m_dq);
   endrule

   // --------------------------------------------------
   // TX decoder: sample the TX pin mid-bit, print chars.

   Reg #(Bit #(1))  tx_prev   <- mkReg (1);
   Reg #(Bit #(4))  tx_cnt    <- mkReg (0);
   Reg #(Bit #(8))  tx_sh     <- mkReg (0);
   Reg #(Bool)      tx_active <- mkReg (False);
   Reg #(Bit #(16)) tx_timer  <- mkReg (0);

   // Byte-level TX capture for the RX host's ACK/NAK pacing
   Reg #(Bit #(16)) rg_tx_count <- mkReg (0);    // bumped per TX byte
   Reg #(Bit #(8))  rg_tx_last  <- mkReg (0);

   rule rl_tx;
      let b = dut.serial_txd;
      if (! tx_active) begin
         if (tx_prev == 1 && b == 0) begin
            // start bit; sample 1.5 bits in
            tx_active <= True;
            tx_timer  <= fromInteger (cycles_per_bit + cycles_per_bit / 2);
            tx_cnt    <= 0;
         end
      end
      else begin
         if (tx_timer != 0)
            tx_timer <= tx_timer - 1;
         else begin
            tx_timer <= fromInteger (cycles_per_bit - 1);
            if (tx_cnt == 8) begin
               // stop bit
               tx_active <= False;
               rg_tx_count <= rg_tx_count + 1;
               rg_tx_last  <= tx_sh;
               $display ("TX: %c", tx_sh);
            end
            else begin
               tx_sh <= { b, tx_sh [7:1] };
               tx_cnt <= tx_cnt + 1;
            end
         end
      end
      tx_prev <= b;
   endrule

   // --------------------------------------------------
   // RX host: after a warmup, send the load header
   // (addr=0x80000000, len=fn_hello_len, both LE), then the payload in
   // the CHUNKED framing the real ROM loader speaks (boot/boot_loader.c
   // chunked path): per chunk [seq=(off>>8)&0xFF, <=256 data bytes,
   // xor of data, 0x55 pad], ACK-paced on the ROM's TX stream
   // (0x06 = ACK -> next chunk, 0x15 = NAK -> resend this chunk).
   //
   // The old version of this block streamed the payload RAW, which the
   // ROM hasn't accepted since seq framing was added — sim-boot "passed"
   // only because its criteria were run-to-completion (see HANDOFF.md,
   // Track D0).

   Reg #(Bool)      rx_started <- mkReg (False);
   Reg #(Bit #(4))  rx_bit     <- mkReg (0);
   Reg #(Bit #(16)) rx_timer   <- mkReg (0);
   Reg #(Bit #(1))  rg_rxd     <- mkReg (1);
   Reg #(Bit #(64)) rg_cycle   <- mkReg (0);
   Reg #(Bit #(32)) rx_warmup  <- mkReg (200_000);

   Reg #(Bool)      rx_in_payload <- mkReg (False);
   Reg #(Bool)      rx_wait_ack   <- mkReg (False);
   Reg #(Bool)      rx_load_done  <- mkReg (False);
   Reg #(Bit #(3))  rx_hdr_idx    <- mkReg (0);   // header byte 0..7
   Reg #(Bit #(16)) rx_off        <- mkReg (0);   // chunk base (absolute)
   Reg #(Bit #(9))  rx_pos        <- mkReg (0);   // position within chunk
   Reg #(Bit #(8))  rx_xor        <- mkReg (0);   // running xor of data bytes
   Reg #(Bit #(16)) rx_ack_seen   <- mkReg (0);   // tx_count at last ack/nak

   function Bit #(16) chunk_len (Bit #(16) off);
      let rem = fn_hello_len () - off;
      return (rem > 256) ? 256 : rem;
   endfunction

   rule rl_rx;
      let m = chunk_len (rx_off);

      if (! rx_started) begin
         if (rx_warmup != 0)
            rx_warmup <= rx_warmup - 1;
         else begin
            rx_started <= True;
            rx_bit     <= 0;    // start bit of byte 0
            rx_timer   <= fromInteger (cycles_per_bit - 1);
         end
      end

      else if (rx_wait_ack) begin
         // line idles until the ROM ACKs/NAKs the in-flight chunk
         if (rg_tx_count != rx_ack_seen) begin
            rx_ack_seen <= rg_tx_count;
            rx_wait_ack <= False;
            rx_bit      <= 0;    // restart byte cleanly: full start bit
            rx_timer    <= fromInteger (cycles_per_bit - 1);
            if (rg_tx_last == 8'h06) begin
               let off_next = rx_off + m;
               if (off_next >= fn_hello_len ()) begin
                  rx_load_done <= True;
                  $display ("RX: all chunks ACKed; image loaded");
               end
               else begin
                  rx_off <= off_next;
                  rx_pos <= 0;
               end
            end
            else if (rg_tx_last == 8'h15) begin
               $display ("RX: NAK; resending chunk at off %0d", rx_off);
               rx_pos <= 0;
            end
         end
      end

      else if (rx_timer != 0)
         rx_timer <= rx_timer - 1;

      else begin
         rx_timer <= fromInteger (cycles_per_bit - 1);
         if (rx_bit == 9) begin
            rx_bit <= 0;
            // current byte fully sent; advance stream position
            if (! rx_in_payload) begin
               rx_hdr_idx <= rx_hdr_idx + 1;    // Bit #(3): wraps 7->0
               if (rx_hdr_idx == 7)
                  rx_in_payload <= True;
            end
            else if (extend (rx_pos) == m + 2)
               rx_wait_ack <= True;    // whole chunk on the wire
            else
               rx_pos <= rx_pos + 1;
         end
         else
            rx_bit <= rx_bit + 1;
      end

      // -------- value of the byte currently on the wire --------
      Bit #(8) cur_byte = 8'h00;
      if (! rx_in_payload) begin
         case (rx_hdr_idx)
            3:       cur_byte = 8'h80;                          // dst 0x80000000
            4:       cur_byte = truncate (fn_hello_len ());     // len LE
            5:       cur_byte = truncate (fn_hello_len () >> 8);
            default: cur_byte = 8'h00;
         endcase
      end
      else if (rx_pos == 0)
         cur_byte = truncate (rx_off >> 8);                     // seq
      else if (extend (rx_pos) <= m)
         cur_byte = fn_hello_bytes (rx_off + extend (rx_pos) - 1);
      else if (extend (rx_pos) == m + 1)
         cur_byte = rx_xor;                                     // checksum
      else
         cur_byte = 8'h55;                                      // pad

      Bit #(1) bit_v = 1;
      if (rx_started && (! rx_load_done) && (! rx_wait_ack)) begin
         if (rx_bit == 0)     bit_v = 0;          // start
         else if (rx_bit < 9) bit_v = cur_byte [rx_bit - 1];
      end
      rg_rxd <= bit_v;

      // running xor over the chunk's data bytes (pos 1..m), once per byte: at the end of the
      // stop bit (rx_timer == 0), the same cycle the stream position advances.
      if (rx_started && rx_in_payload && (! rx_wait_ack) && (rx_bit == 9) && (rx_timer == 0)) begin
         if (rx_pos == 0)
            rx_xor <= 0;
         else if (extend (rx_pos) <= m)
            rx_xor <= rx_xor ^ cur_byte;
      end
   endrule

   rule rl_pins;
      dut.serial_rxd (rg_rxd);
      dut.btn1 (1'b0);
      rg_cycle <= rg_cycle + 1;
      if (rg_cycle > fromInteger (max_cycles)) begin
         $display ("TIMEOUT after %0d cycles", rg_cycle);
         $finish (0);
      end
   endrule

endmodule

endpackage
