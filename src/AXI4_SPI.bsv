// ================================================================
// AXI4_SPI: SPI host, register-compatible with the SiFive SPI controller (sifive,spi0), so the
// stock Linux spi-sifive + mmc_spi drivers run the ULX3S microSD slot in SPI mode.  One chip
// select, single-lane frames of 8 bits, 8-deep TX and RX FIFOs.  Offsets (32-bit registers;
// on the 64-bit fabric a register at +4 is in lanes [63:32]):
//   0x00 SCKDIV   [11:0]  sck = clk / (2 * (div + 1))
//   0x04 SCKMODE  [0] PHA, [1] POL
//   0x10 CSID     chip select index (only 0 has a pin)
//   0x14 CSDEF    [0] inactive level of CS (reset 1: active low); one bit implemented
//   0x18 CSMODE   0 AUTO (asserted during each frame), 2 HOLD (asserted from the first frame
//                 until CSMODE / CSID / CSDEF changes), 3 OFF
//   0x28 DELAY0, 0x2c DELAY1, 0x60 FCTRL, 0x64 FFMT: stored, no effect
//   0x40 FMT      [1:0] proto (single only), [2] LSB first, [3] DIR (1: RX discarded), [19:16] len
//   0x48 TXDATA   write: enqueue [7:0]; read: [31] FULL
//   0x4c RXDATA   read: [31] EMPTY, else dequeue and return [7:0]
//   0x50 TXMARK, 0x54 RXMARK   IP.TXWM = (TX level < TXMARK), IP.RXWM = (RX level > RXMARK)
//   0x70 IE, 0x74 IP           interrupt_req = |(IE & IP)
// Frame timing: CS asserts, a half period, 16 sck edges, a half period.  MISO is sampled
// through an input flop at the end of the half period after the sampling edge (PHA=0: the
// leading edge, PHA=1: the trailing edge), so it tolerates a card output delay up to a half
// period minus one clock.  Mode 0 is what SD uses.
// ================================================================

package AXI4_SPI;

export AXI4_SPI_IFC (..), mkAXI4_SPI;

import Vector       :: *;
import ConfigReg    :: *;
import FIFOF        :: *;
import GetPut       :: *;
import Semi_FIFOF   :: *;

import AXI4_Types   :: *;
import AXI4_Xactors :: *;
import Fabric_Defs  :: *;

// ================================================================

interface AXI4_SPI_IFC;
   method Action init (Bit #(Wd_Id) axi4_id, Bit #(Wd_Addr) addr_base, Bit #(Wd_Addr) addr_lim);
   // SoC soft reset (ndmreset): drop transactions in flight with the fabric (see AXI4_GPIO)
   method Action reset;

   interface AXI4_Slave_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) slave;

   method Bool interrupt_req;

   (* always_ready *)   method Bit #(1) sclk;
   (* always_ready *)   method Bit #(1) mosi;
   (* always_ready *)   method Bit #(1) cs_n;
   (* always_enabled *) method Action   miso (Bit #(1) v);
endinterface

// ================================================================

function Bit #(8) fv_rev8 (Bit #(8) x) = reverseBits (x);

(* synthesize *)
module mkAXI4_SPI (AXI4_SPI_IFC);

   Reg #(Bit #(Wd_Addr)) rg_addr_base <- mkRegU;
   Reg #(Bit #(Wd_Addr)) rg_addr_lim  <- mkRegU;

   AXI4_Slave_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) slave_xactor <- mkAXI4_Slave_Xactor;

   // ---- Control registers (written by rl_wr only)
   Reg #(Bit #(12)) rg_sckdiv  <- mkReg (3);
   Reg #(Bit #(2))  rg_sckmode <- mkReg (0);
   Reg #(Bit #(32)) rg_csid    <- mkReg (0);
   Reg #(Bit #(1))  rg_csdef   <- mkReg (1);
   Reg #(Bit #(2))  rg_csmode  <- mkReg (0);
   Reg #(Bit #(32)) rg_delay0  <- mkReg (32'h0001_0001);
   Reg #(Bit #(32)) rg_delay1  <- mkReg (32'h0000_0001);
   Reg #(Bit #(1))  rg_fmt_endian <- mkReg (0);
   Reg #(Bit #(1))  rg_fmt_dir    <- mkReg (0);
   Reg #(Bit #(2))  rg_fmt_proto  <- mkReg (0);
   Reg #(Bit #(4))  rg_fmt_len    <- mkReg (8);
   Reg #(Bit #(3))  rg_txmark  <- mkReg (0);
   Reg #(Bit #(3))  rg_rxmark  <- mkReg (0);
   Reg #(Bit #(1))  rg_fctrl   <- mkReg (1);
   Reg #(Bit #(32)) rg_ffmt    <- mkReg (0);
   Reg #(Bit #(2))  rg_ie      <- mkReg (0);
   // CSMODE / CSID / CSDEF writes bump this; a HOLD lasts while it is unchanged
   Reg #(Bit #(4))  rg_cs_gen  <- mkConfigReg (0);

   // ---- FIFOs: 8 entries, pointers 4 bits; each pointer has one writer.  ConfigRegs: a reader
   // sees last cycle's value, which only makes it more conservative (fuller / emptier).
   Vector #(8, Reg #(Bit #(8))) v_tx <- replicateM (mkConfigRegU);
   Vector #(8, Reg #(Bit #(8))) v_rx <- replicateM (mkConfigRegU);
   Reg #(Bit #(4)) rg_tx_wp <- mkConfigReg (0);    // rl_wr
   Reg #(Bit #(4)) rg_tx_rp <- mkConfigReg (0);    // engine
   Reg #(Bit #(4)) rg_rx_wp <- mkConfigReg (0);    // engine
   Reg #(Bit #(4)) rg_rx_rp <- mkConfigReg (0);    // rl_rd
   Bit #(4) tx_level = rg_tx_wp - rg_tx_rp;
   Bit #(4) rx_level = rg_rx_wp - rg_rx_rp;

   // ---- Engine
   Reg #(Bool)      rg_busy   <- mkReg (False);
   Reg #(Bit #(12)) rg_cnt    <- mkReg (0);
   Reg #(Bit #(5))  rg_edge   <- mkReg (0);     // 0..15: sck edges; 16: tail half period
   Reg #(Bit #(8))  rg_sh_tx  <- mkReg (0);
   Reg #(Bit #(8))  rg_sh_rx  <- mkReg (0);
   Reg #(Bit #(12)) rg_f_div  <- mkReg (0);     // latched per frame
   Reg #(Bit #(1))  rg_f_pha  <- mkReg (0);
   Reg #(Bit #(1))  rg_f_dir  <- mkReg (0);
   Reg #(Bit #(1))  rg_f_endian <- mkReg (0);
   Reg #(Bool)      rg_hold   <- mkReg (False);  // HOLD mode: CS stays asserted
   Reg #(Bit #(4))  rg_hold_gen <- mkReg (0);
   Reg #(Bit #(1))  rg_sck    <- mkReg (0);
   Reg #(Bit #(1))  rg_mosi   <- mkReg (1);
   Reg #(Bit #(1))  rg_cs_n   <- mkReg (1);
   Reg #(Bit #(1))  rg_miso_q <- mkConfigReg (1); // input flop (ConfigReg: the pin methods stay unordered against the engine)
   Reg #(Bool)      rg_irq    <- mkReg (False);

   Bool cs_sel = (rg_csid == 0);

   // ================================================================
   // Engine: one rule, fires every cycle

   (* fire_when_enabled, no_implicit_conditions *)
   rule rl_engine;
      Bool     busy   = rg_busy;
      Bool     hold   = rg_hold && (rg_csmode == 2) && (rg_hold_gen == rg_cs_gen);
      Bit #(1) sck    = rg_sck;
      Bit #(1) mosi   = rg_mosi;
      Bit #(4) tx_rp  = rg_tx_rp;
      Bit #(4) rx_wp  = rg_rx_wp;
      Bit #(1) pol    = rg_sckmode [1];

      if (! busy) begin
         sck = pol;
         if (tx_level != 0) begin
            Bit #(8) b = v_tx [tx_rp [2:0]];
            if (rg_fmt_endian == 1) b = fv_rev8 (b);
            tx_rp = tx_rp + 1;
            rg_sh_tx    <= b;
            rg_f_div    <= rg_sckdiv;
            rg_f_pha    <= rg_sckmode [0];
            rg_f_dir    <= rg_fmt_dir;
            rg_f_endian <= rg_fmt_endian;
            rg_cnt      <= rg_sckdiv;
            rg_edge     <= 0;
            if (rg_sckmode [0] == 0) mosi = b [7];
            if (rg_csmode == 2) begin
               hold = True;
               rg_hold_gen <= rg_cs_gen;
            end
            busy = True;
         end
      end
      else if (rg_cnt != 0)
         rg_cnt <= rg_cnt - 1;
      else begin
         rg_cnt <= rg_f_div;
         Bit #(5) e = rg_edge;
         Bool leading = (e [0] == 0);
         Bool capture = (rg_f_pha == 0) ? ((e < 16) && (! leading))         // after the leading edge
                                        : ((e != 0) && leading);            // after the trailing edge
         Bit #(8) sh_rx = rg_sh_rx;
         if (capture) sh_rx = { sh_rx [6:0], rg_miso_q };
         rg_sh_rx <= sh_rx;
         if (e < 16) begin
            sck = ~ sck;
            Bool shift = (rg_f_pha == 0) ? (! leading) : leading;
            if (shift) begin
               // PHA=0: bit 7 went out at frame start; each trailing edge presents the next bit.
               // PHA=1: each leading edge presents the current bit.
               if (rg_f_pha == 0) begin
                  mosi = rg_sh_tx [6];
                  rg_sh_tx <= rg_sh_tx << 1;
               end
               else begin
                  mosi = rg_sh_tx [7];
                  rg_sh_tx <= rg_sh_tx << 1;
               end
            end
            rg_edge <= e + 1;
         end
         else begin
            // tail: frame done
            busy = False;
            if ((rg_f_dir == 0) && (rx_level != 8)) begin
               v_rx [rx_wp [2:0]] <= ((rg_f_endian == 1) ? fv_rev8 (sh_rx) : sh_rx);
               rx_wp = rx_wp + 1;
            end
         end
      end

      rg_busy  <= busy;
      rg_hold  <= hold;
      rg_sck   <= sck;
      rg_mosi  <= mosi;
      rg_tx_rp <= tx_rp;
      rg_rx_wp <= rx_wp;
      Bool active = cs_sel && (rg_csmode != 3) && (busy || hold);
      rg_cs_n  <= (active ? (~ rg_csdef) : rg_csdef);

      Bool txwm = (tx_level < zeroExtend (rg_txmark));
      Bool rxwm = (rx_level > zeroExtend (rg_rxmark));
      rg_irq <= (((rg_ie [0] == 1) && txwm) || ((rg_ie [1] == 1) && rxwm));
   endrule

   // ================================================================
   // Register reads

   function Bit #(32) fv_read (Bit #(7) off);
      Bool txwm = (tx_level < zeroExtend (rg_txmark));
      Bool rxwm = (rx_level > zeroExtend (rg_rxmark));
      case (off)
         'h00: return zeroExtend (rg_sckdiv);
         'h04: return zeroExtend (rg_sckmode);
         'h10: return rg_csid;
         'h14: return zeroExtend (rg_csdef);
         'h18: return zeroExtend (rg_csmode);
         'h28: return rg_delay0;
         'h2c: return rg_delay1;
         'h40: return { 12'b0, rg_fmt_len, 12'b0, rg_fmt_dir, rg_fmt_endian, rg_fmt_proto };
         'h48: return { pack (tx_level == 8), 31'b0 };
         'h50: return zeroExtend (rg_txmark);
         'h54: return zeroExtend (rg_rxmark);
         'h60: return zeroExtend (rg_fctrl);
         'h64: return rg_ffmt;
         'h70: return zeroExtend (rg_ie);
         'h74: return zeroExtend ({ pack (rxwm), pack (txwm) });
         default: return 0;
      endcase
   endfunction

   // ================================================================
   // Write handler

   rule rl_wr;
      let wra <- pop_o (slave_xactor.o_wr_addr);
      let wrd <- pop_o (slave_xactor.o_wr_data);

      Bit #(Wd_Addr) byte_addr = wra.awaddr - rg_addr_base;
      Bit #(64) wdata64 = zeroExtend (wrd.wdata);
      Bit #(8)  wstrb8  = zeroExtend (wrd.wstrb);
      Bool hi = ((valueOf (Wd_Data) == 64) && (byte_addr [2] == 1));
      Bit #(32) w   = hi ? wdata64 [63:32] : wdata64 [31:0];
      Bit #(4)  stb = hi ? wstrb8 [7:4] : wstrb8 [3:0];
      AXI4_Resp bresp = axi4_resp_okay;

      if ((wra.awaddr < rg_addr_base) || (wra.awaddr >= rg_addr_lim) || (byte_addr [11:7] != 0))
         bresp = axi4_resp_decerr;
      else if (stb != 0) begin
         Bit #(7) off = { byte_addr [6:2], 2'b0 };
         case (off)
            'h00: rg_sckdiv  <= w [11:0];
            'h04: rg_sckmode <= w [1:0];
            'h10: begin rg_csid   <= w;       rg_cs_gen <= rg_cs_gen + 1; end
            'h14: begin rg_csdef  <= w [0];   rg_cs_gen <= rg_cs_gen + 1; end
            'h18: begin rg_csmode <= w [1:0]; rg_cs_gen <= rg_cs_gen + 1; end
            'h28: rg_delay0  <= w;
            'h2c: rg_delay1  <= w;
            'h40: begin
                     rg_fmt_proto  <= w [1:0];
                     rg_fmt_endian <= w [2];
                     rg_fmt_dir    <= w [3];
                     rg_fmt_len    <= w [19:16];
                  end
            'h48: if (tx_level != 8) begin
                     v_tx [rg_tx_wp [2:0]] <= w [7:0];
                     rg_tx_wp <= rg_tx_wp + 1;
                  end
            'h50: rg_txmark  <= w [2:0];
            'h54: rg_rxmark  <= w [2:0];
            'h60: rg_fctrl   <= w [0];
            'h64: rg_ffmt    <= w;
            'h70: rg_ie      <= w [1:0];
            default: noAction;
         endcase
      end

      slave_xactor.i_wr_resp.enq (AXI4_Wr_Resp {bid: wra.awid, bresp: bresp, buser: wra.awuser});
   endrule

   // ================================================================
   // Read handler (RXDATA pops)

   rule rl_rd;
      let rda <- pop_o (slave_xactor.o_rd_addr);

      Bit #(Wd_Addr) byte_addr = rda.araddr - rg_addr_base;
      Bool hi = ((valueOf (Wd_Data) == 64) && (byte_addr [2] == 1));
      Bit #(7) off = { byte_addr [6:2], 2'b0 };
      Bit #(32) v = 0;
      AXI4_Resp rresp = axi4_resp_okay;

      if ((rda.araddr < rg_addr_base) || (rda.araddr >= rg_addr_lim) || (byte_addr [11:7] != 0))
         rresp = axi4_resp_decerr;
      else if (off == 'h4c) begin
         if (rx_level == 0)
            v = 32'h8000_0000;
         else begin
            v = zeroExtend (v_rx [rg_rx_rp [2:0]]);
            rg_rx_rp <= rg_rx_rp + 1;
         end
      end
      else
         v = fv_read (off);

      Bit #(64) d64 = hi ? { v, 32'b0 } : zeroExtend (v);
      slave_xactor.i_rd_data.enq (AXI4_Rd_Data {rid:   rda.arid,
                                               rdata: truncate (d64),
                                               rresp: rresp,
                                               rlast: True,
                                               ruser: rda.aruser});
   endrule

   // ================================================================
   // INTERFACE

   method Action init (Bit #(Wd_Id) axi4_id, Bit #(Wd_Addr) addr_base, Bit #(Wd_Addr) addr_lim);
      rg_addr_base <= addr_base;
      rg_addr_lim  <= addr_lim;
   endmethod

   method Action reset;
      slave_xactor.reset;
   endmethod

   interface slave = slave_xactor.axi_side;

   method Bool interrupt_req = rg_irq;

   method Bit #(1) sclk = rg_sck;
   method Bit #(1) mosi = rg_mosi;
   method Bit #(1) cs_n = rg_cs_n;
   method Action miso (Bit #(1) v);
      rg_miso_q <= v;
   endmethod
endmodule

endpackage
