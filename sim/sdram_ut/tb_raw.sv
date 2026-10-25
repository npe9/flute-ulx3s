// Sdram_Controller raw port, driven directly with the streaming
// Mem_Controller's request shapes: reads of bursts b_first..b_last (single
// bursts, odd first burst, whole line), writes of one 32-byte half with a
// random byte mask (empty bursts and empty masks included), over 64 lines
// spread across all 4 banks (same-bank back-to-back requests are common).
// The chunk consumer is throttled so the controller's credit gate holds
// reads back.  PASS = every chunk matches the shadow, chunk counts match,
// and the timing checker reports 0 errors.  TCK_PS sets the checker's clock;
// RAW_PLL selects the controller built for the 32.14 MHz PLL clock.  The model
// clock period is TCK_PS too.
// VENDOR: the Micron MT48LC16M16A2 Verilog model (same organization as the
// W9825G6KH; its own timing checks and tAC/tOH output timing) wired as on the
// board: SDRAM clock = inverted system clock through the ODDR (+1 ns), command
// and DQ outputs 2 ns after the system edge, DQ captured by the IOB register on
// the system edge.  Our pin-level checker still watches the commands.
`timescale 1ns/1ps
`ifndef TCK_PS
`define TCK_PS 40000
`endif
module tb;
   localparam int NREQ   = 6000;
   localparam int MAXOUT = 6;          // reads queued ahead of the consumer

   reg clk = 0;  always #(`TCK_PS / 2000.0) clk = ~clk;   // controller clock
   reg rst_n = 0;

   wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
   wire [1:0]  ba, dqm;
   wire [12:0] a;
   wire [15:0] dq_out;
   tri  [15:0] dq;
   reg  [15:0] dq_iob;
`ifdef VENDOR
   assign #2 dq = dq_oe ? dq_out : 16'hzzzz;
`else
   assign dq = dq_oe ? dq_out : 16'hzzzz;
`endif
   always @(posedge clk) dq_iob <= dq;           // src/Top.v useioff register

   // Raw_Mem_Req = {write, line[18:0], b_first[1:0], b_last[1:0], wdata[255:0], wbe[31:0]}
   reg  [311:0] req;  reg req_en = 0;  wire req_rdy;
   wire [63:0]  rsp;  reg rsp_en = 0;  wire rsp_rdy;
   wire init_done;

`ifdef RAW_PLL
   mkSdram_RawUT_PLL dut (
`else
   mkSdram_RawUT dut (
`endif.CLK(clk), .RST_N(rst_n),
      .raw_request_put(req), .EN_raw_request_put(req_en), .RDY_raw_request_put(req_rdy),
      .EN_raw_response_get(rsp_en), .raw_response_get(rsp), .RDY_raw_response_get(rsp_rdy),
      .init_done(init_done),
      .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
      .sdram_ba(ba), .sdram_a(a), .sdram_dqm(dqm), .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe),
      .sdram_dq_in_v(dq_iob));

`ifdef VENDOR
   wire        sd_clk;
   wire        p_cke, p_cs_n, p_ras_n, p_cas_n, p_we_n;
   wire [1:0]  p_ba, p_dqm;
   wire [12:0] p_a;
   assign #1 sd_clk = ~clk;                      // ODDRX1F D0=0 D1=1
   assign #2 {p_cke, p_cs_n, p_ras_n, p_cas_n, p_we_n, p_ba, p_dqm, p_a}
                = {cke, cs_n, ras_n, cas_n, we_n, ba, dqm, a};
   // W9825G6KH-6 is stricter on tRAS (42 ns); the other Micron defaults are equal or stricter
   mt48lc16m16a2 #(.tRAS(42.0)) mem (.Dq(dq), .Addr(p_a), .Ba(p_ba), .Clk(sd_clk), .Cke(p_cke),
                .Cs_n(p_cs_n), .Ras_n(p_ras_n), .Cas_n(p_cas_n), .We_n(p_we_n), .Dqm(p_dqm));
   // The Micron arrays start unknown; the shadow (and sdram_model.v) start at zero. The test
   // lines use rows 0..3 of each bank: index {row, col} < 4 * 512.
   initial for (int i = 0; i < 2048; i++) begin
      mem.Bank0[i] = 0; mem.Bank1[i] = 0; mem.Bank2[i] = 0; mem.Bank3[i] = 0;
   end
`else
   w9825g6 mem (.clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
                .ba(ba), .a(a), .dqm(dqm), .dq(dq));
`endif
   sdram_timing_check #(.TCK_PS(`TCK_PS)) chk (.clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n),
                .cas_n(cas_n), .we_n(we_n), .ba(ba), .a(a), .dqm(dqm));

   // 64 test lines: bank s[1:0], column group s[3:2], row s[5:4] (rows 0, 1, 2, 3)
   function automatic [18:0] sel2line (input [5:0] s);
      sel2line = {11'b0, s[5:4], 2'b0, s[3:2], s[1:0]};
   endfunction

   reg [63:0] shadow [0:63][0:7];
   reg [63:0] expq [$];
   int n_req = 0, n_rd = 0, n_wr = 0, n_chk = 0, n_err = 0, n_stall = 0, outst = 0;
   int n_single = 0, n_odd = 0, n_full = 0, n_emptymask = 0;
   int phase_throttle;
   // request fields (module scope: Icarus has no automatic variables in always blocks)
   int r;
   logic [5:0] s;
   logic wr;
   logic [1:0] b0, b1;
   logic [255:0] d;
   logic [31:0] be;
   initial for (int i = 0; i < 64; i++) for (int k = 0; k < 8; k++) shadow[i][k] = '0;

   always @(negedge clk) begin
      rsp_en = 0; req_en = 0;
      if (rst_n && init_done) begin
         phase_throttle = (n_req < NREQ/3) ? 20 : (n_req < 2*NREQ/3) ? 3 : 1;
         if (rsp_rdy) begin
            if ($urandom % phase_throttle == 0) begin
               rsp_en = 1;
               if (expq.size() == 0) begin $display("FAIL: chunk with nothing outstanding"); n_err++; end
               else begin
                  if (rsp !== expq[0]) begin
                     n_err++;
                     if (n_err <= 5) $display("FAIL: chunk %0d got %h exp %h", n_chk, rsp, expq[0]);
                  end
                  expq.pop_front();
                  n_chk++;
               end
            end else n_stall++;
         end
         if (req_rdy && n_req < NREQ && expq.size() < MAXOUT * 8) begin
            r  = $urandom;
            s  = r[5:0];
            wr = r[6] | r[7];
            for (int k = 0; k < 8; k++) d[k*32 +: 32] = $urandom;
            be = $urandom;
            if (wr) begin
               b0 = {r[8], 1'b0}; b1 = {r[8], 1'b1};      // one half, as Mem_Controller writes back
               case (r[11:9])
                  3'd0: be = '1;
                  3'd1: be = 32'h0000_FFFF << (r[12] ? 16 : 0);   // one burst only
                  3'd2: be = '0;                                    // empty mask (no command)
                  3'd3: be = 32'h1 << r[17:13];                     // one byte
                  default: ;
               endcase
               if (be == 0) n_emptymask++;
               for (int k = 0; k < 4; k++)
                  for (int j = 0; j < 8; j++)
                     if (be[k*8 + j]) shadow[s][r[8]*4 + k][j*8 +: 8] = d[k*64 + j*8 +: 8];
               n_wr++;
            end else begin
               b0 = r[9:8]; b1 = r[11:10];
               if (b1 < b0) b1 = b0;
               if (r[12]) b1 = b0;                        // single burst often
               if (b0 == b1) n_single++;
               if (b0[0]) n_odd++;
               if (b0 == 0 && b1 == 3) n_full++;
               for (int k = b0 * 2; k <= b1 * 2 + 1; k++) expq.push_back(shadow[s][k]);
               n_rd++;
            end
            req    = {wr, sel2line(s), b0, b1, d, be};
            req_en = 1;
            n_req++;
         end
      end
   end

   initial begin
      repeat (10) @(posedge clk);
      rst_n = 1;
      while (!(n_req == NREQ && expq.size() == 0)) @(posedge clk);   // Icarus: no wait() on a queue method
      repeat (100) @(posedge clk);
      if (rsp_rdy) begin $display("FAIL: extra chunk after the last read"); n_err++; end
      $display("[sdram_raw] %0d requests (%0d reads: %0d single-burst, %0d odd-first, %0d whole-line; %0d writes, %0d empty masks), %0d chunks checked, %0d mismatches, %0d stall cycles",
               n_req, n_rd, n_single, n_odd, n_full, n_wr, n_emptymask, n_chk, n_err, n_stall);
      if (n_err == 0) $display("[sdram_raw] PASS (see sdram_chk summary for timing)");
      else $display("[sdram_raw] FAIL");
      $finish;
   end
   initial begin #400ms; $display("[sdram_raw] FAIL: timeout"); $finish; end
endmodule
