// Bluesim unit test for src/AXI4_SPI.bsv: drives the registers in the order Linux spi-sifive
// does, against (a) a mode-0 SPI device model (samples MOSI on rising sck, presents MISO after
// the falling edge with an output delay; answers each byte with ~previous byte, 0x5A first) and
// (b) a MISO = MOSI wire for mode 3.  Prints PASS / FAIL and finishes.
package Tb_AXI4_SPI;

import StmtFSM     :: *;
import Connectable :: *;
import Semi_FIFOF  :: *;
import AXI4_Types  :: *;
import AXI4_Xactors :: *;
import Fabric_Defs :: *;
import AXI4_SPI    :: *;

Bit #(64) base = 'hC000_4000;

(* synthesize *)
module mkTb_AXI4_SPI (Empty);
   AXI4_SPI_IFC spi <- mkAXI4_SPI;
   AXI4_Master_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) mx <- mkAXI4_Master_Xactor;
   mkConnection (mx.axi_side, spi.slave);

   Reg #(Bool)      rg_loop   <- mkReg (False);   // MISO = MOSI instead of the device model
   Reg #(Bit #(4))  rg_dly    <- mkReg (2);       // device output delay (clocks)
   // device model
   Reg #(Bit #(1))  d_sck_prev <- mkReg (0);
   Reg #(Bit #(1))  d_cs_prev  <- mkReg (1);
   Reg #(Bit #(8))  d_in   <- mkReg (0);
   Reg #(Bit #(8))  d_out  <- mkReg (8'h5A);
   Reg #(Bit #(4))  d_n    <- mkReg (0);
   Reg #(Bit #(8))  d_last <- mkReg (8'hA5);       // ~0x5A: first answer is 0x5A
   Reg #(Bit #(1))  d_miso <- mkReg (1);
   Reg #(Bit #(1))  d_pend_v <- mkReg (0);
   Reg #(Bit #(4))  d_pend_t <- mkReg (0);
   Reg #(Bit #(1))  d_pend_b <- mkReg (0);
   Reg #(UInt #(32)) rg_edges <- mkReg (0);

   Reg #(Bit #(32)) rg_r    <- mkReg (0);
   Reg #(UInt #(32)) rg_err <- mkReg (0);
   Reg #(Bit #(4))  rg_i    <- mkReg (0);
   Reg #(UInt #(32)) rg_t   <- mkReg (0);

   (* fire_when_enabled, no_implicit_conditions *)
   rule rl_dev;
      Bit #(1) sck = spi.sclk;
      Bit #(1) cs  = spi.cs_n [0];
      if (sck != d_sck_prev) rg_edges <= rg_edges + 1;
      Bit #(8) din = d_in; Bit #(8) dout = d_out; Bit #(4) n = d_n;
      Bit #(1) pv = d_pend_v; Bit #(4) pt = d_pend_t; Bit #(1) pb = d_pend_b;
      Bit #(1) miso = d_miso;
      if (cs == 1) begin
         n = 0; dout = ~ d_last; miso = 1; pv = 0;
      end
      else begin
         if ((d_cs_prev == 1)) begin pv = 1; pt = rg_dly; pb = dout [7]; end
         if ((sck == 1) && (d_sck_prev == 0)) begin     // rising: sample
            din = { din [6:0], spi.mosi };
            n = n + 1;
         end
         if ((sck == 0) && (d_sck_prev == 1)) begin     // falling: next bit
            if (n == 8) begin
               n = 0;
               d_last <= din;
               dout = ~ din;
            end
            else
               dout = dout << 1;
            pv = 1; pt = rg_dly; pb = dout [7];
         end
         if (pv == 1) begin
            if (pt == 0) begin miso = pb; pv = 0; end
            else pt = pt - 1;
         end
      end
      d_in <= din; d_out <= dout; d_n <= n; d_miso <= miso;
      d_pend_v <= pv; d_pend_t <= pt; d_pend_b <= pb;
      d_sck_prev <= sck; d_cs_prev <= cs;
      spi.miso0 (rg_loop ? spi.mosi : miso);
      spi.miso1 (~ spi.mosi);                            // CS 1 device: inverting loopback
   endrule

   rule rl_tick; rg_t <= rg_t + 1; endrule

   function Action wr_req (Bit #(7) off, Bit #(32) v);
      action
         Bit #(64) a = base + zeroExtend (off);
         Bit #(64) d = (a [2] == 1) ? { v, 32'b0 } : zeroExtend (v);
         Bit #(8)  s = (a [2] == 1) ? 8'hF0 : 8'h0F;
         mx.i_wr_addr.enq (AXI4_Wr_Addr {awid: 0, awaddr: truncate (a), awlen: 0, awsize: axsize_4,
                                         awburst: 1, awlock: 0, awcache: 0, awprot: 0, awqos: 0,
                                         awregion: 0, awuser: 0});
         mx.i_wr_data.enq (AXI4_Wr_Data {wdata: truncate (d), wstrb: truncate (s), wlast: True, wuser: 0});
      endaction
   endfunction
   function Stmt wr (Bit #(7) off, Bit #(32) v) = seq
      wr_req (off, v);
      action let r <- pop_o (mx.o_wr_resp); if (r.bresp != 0) begin $display ("FAIL wr resp %h", off); rg_err <= rg_err + 1; end endaction
   endseq;
   function Stmt rd (Bit #(7) off) = seq
      action
         Bit #(64) a = base + zeroExtend (off);
         mx.i_rd_addr.enq (AXI4_Rd_Addr {arid: 0, araddr: truncate (a), arlen: 0, arsize: axsize_4,
                                         arburst: 1, arlock: 0, arcache: 0, arprot: 0, arqos: 0,
                                         arregion: 0, aruser: 0});
      endaction
      action
         let r <- pop_o (mx.o_rd_data);
         Bit #(64) d = zeroExtend (r.rdata);
         rg_r <= (off [2] == 1) ? d [63:32] : d [31:0];
      endaction
   endseq;
   function Action chk (String what, Bit #(32) got, Bit #(32) exp) = action
      if (got != exp) begin $display ("FAIL %s: got %h exp %h", what, got, exp); rg_err <= rg_err + 1; end
   endaction;

   Bit #(8) tx [8] = { 8'hA5, 8'h3C, 8'h00, 8'hFF, 8'h81, 8'h7E, 8'h12, 8'hED };

   function Stmt xfer8 (Bit #(8) first_exp) = seq
      for (rg_i <= 0; rg_i < 8; rg_i <= rg_i + 1) wr ('h48, zeroExtend (tx [rg_i]));
      wr ('h54, 7);                                      // RXMARK = n - 1
      rg_r <= 0;
      while ((rg_r & 2) == 0) rd ('h74);                 // poll IP.RXWM
      for (rg_i <= 0; rg_i < 8; rg_i <= rg_i + 1) seq
         rd ('h4c);
         chk ("rx", rg_r, zeroExtend ((rg_i == 0) ? first_exp : ~ tx [rg_i - 1]));
      endseq
      rd ('h4c); chk ("rx empty after", rg_r, 32'h8000_0000);
   endseq;

   mkAutoFSM (seq
      spi.init (0, truncate (base), truncate (base + 64'h1000));
      action chk ("cs idle", zeroExtend (spi.cs_n), 3); endaction
      // CSDEF probe (two CS lines)
      rd ('h14); chk ("csdef reset", rg_r, 3);
      wr ('h14, 32'hFFFF_FFFF); rd ('h14); chk ("csdef probe", rg_r, 3);
      wr ('h14, 1);
      // init as sifive_spi_init
      wr ('h70, 0); wr ('h50, 1); wr ('h54, 0); wr ('h28, 32'h0001_0001); wr ('h2c, 1); wr ('h60, 0);
      rd ('h48); chk ("tx not full", rg_r, 0);
      rd ('h4c); chk ("rx empty", rg_r, 32'h8000_0000);
      // message: CSDEF, CSID, SCKMODE 0; select (HOLD); 8-byte RX transfer at div 2, delay 2
      wr ('h14, 1); wr ('h10, 0); wr ('h04, 0); wr ('h18, 2);
      wr ('h00, 2); wr ('h40, 32'h0008_0000);
      rg_edges <= 0;
      xfer8 (8'h5A);
      action chk ("edges", pack (rg_edges), 128); endaction
      action chk ("cs held", zeroExtend (spi.cs_n [0]), 0); endaction
      // next message (Linux spi-sifive prepare_message + set_cs): rewriting the same CSDEF,
      // CSID and CSMODE must not end HOLD (mmc_spi keeps CS across command/data messages)
      wr ('h14, 1); wr ('h10, 0); wr ('h18, 2); delay (4);
      action chk ("cs held across rewrite", zeroExtend (spi.cs_n [0]), 0); endaction
      // div 0 (sck = clk/2), device delay 0
      rg_dly <= 0; wr ('h00, 0);
      xfer8 (~ 8'hED);
      // TX-only (DIR = 1): nothing lands in RX
      wr ('h40, 32'h0008_0008);
      wr ('h48, 32'h11); wr ('h48, 32'h22); wr ('h48, 32'h33);
      rg_r <= 0;
      while ((rg_r & 1) == 0) rd ('h74);                 // IP.TXWM (level < 1)
      delay (200);
      rd ('h4c); chk ("dir: rx empty", rg_r, 32'h8000_0000);
      // deselect (AUTO): CS returns to CSDEF
      wr ('h18, 0); delay (4);
      action chk ("cs released", zeroExtend (spi.cs_n), 3); endaction
      // CS_HIGH device: CSDEF 0 -> idle low, active high
      wr ('h14, 0); delay (4);
      action chk ("csdef 0 idle", zeroExtend (spi.cs_n), 2); endaction    // CS 1 ignores CSDEF
      wr ('h14, 1);
      // mode 3 loopback, div 3, LSB-first
      rg_loop <= True; wr ('h04, 3); wr ('h00, 3); wr ('h40, 32'h0008_0004); wr ('h18, 2);
      action chk ("mode3 sck idle", zeroExtend (spi.sclk), 1); endaction
      wr ('h48, 32'hC3); wr ('h48, 32'h96);
      wr ('h54, 1);
      rg_r <= 0;
      while ((rg_r & 2) == 0) rd ('h74);
      rd ('h4c); chk ("m3 rx0", rg_r, 32'hC3);
      rd ('h4c); chk ("m3 rx1", rg_r, 32'h96);
      // interrupt: IE.RXWM with RX empty and RXMARK 0 -> no irq; one byte -> irq
      wr ('h18, 0); wr ('h04, 0); wr ('h40, 32'h0008_0000); wr ('h54, 0); wr ('h70, 2);
      delay (4);
      action if (spi.interrupt_req) begin $display ("FAIL irq early"); rg_err <= rg_err + 1; end endaction
      wr ('h48, 32'h55);
      await (spi.interrupt_req);
      rd ('h4c); chk ("irq rx", rg_r, 32'h55);
      delay (4);
      action if (spi.interrupt_req) begin $display ("FAIL irq stuck"); rg_err <= rg_err + 1; end endaction
      // CS 1 (flash): HOLD on CS 1 only, MISO from the CS 1 input
      wr ('h70, 0); wr ('h10, 1); wr ('h18, 2); wr ('h00, 1);
      wr ('h48, 32'h3C); wr ('h48, 32'h0F);
      wr ('h54, 1);
      rg_r <= 0;
      while ((rg_r & 2) == 0) rd ('h74);
      action chk ("cs1 held", zeroExtend (spi.cs_n), 1); endaction
      rd ('h4c); chk ("cs1 rx0", rg_r, 32'hC3);
      rd ('h4c); chk ("cs1 rx1", rg_r, 32'hF0);
      wr ('h18, 0); delay (4);
      action chk ("cs1 released", zeroExtend (spi.cs_n), 3); endaction
      wr ('h10, 0);
      action
         if (rg_err == 0) $display ("Tb_AXI4_SPI: PASS (%0d cycles)", rg_t);
         else $display ("Tb_AXI4_SPI: FAIL (%0d errors)", rg_err);
      endaction
   endseq);
endmodule
endpackage
