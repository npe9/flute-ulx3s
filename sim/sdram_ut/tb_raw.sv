// Sdram_Controller raw port, driven directly with the streaming
// Mem_Controller's request shapes: reads of bursts b_first..b_last (single
// bursts, odd first burst, whole line), writes of one 32-byte half with a
// random byte mask (empty bursts and empty masks included), over 64 lines
// spread across all 4 banks (same-bank back-to-back requests are common).
// The chunk consumer is throttled so the controller's credit gate holds
// reads back.  PASS = every chunk matches the shadow, chunk counts match,
// and the timing checker reports 0 errors.  TCK_PS sets the checker's clock;
// RAW_PLL selects the controller built for the 32.14 MHz PLL clock.
`timescale 1ns/1ps
`ifndef TCK_PS
`define TCK_PS 40000
`endif
module tb;
   localparam int NREQ   = 6000;
   localparam int MAXOUT = 6;          // reads queued ahead of the consumer

   reg clk = 0;  always #20 clk = ~clk;          // 25 MHz model clock
   reg rst_n = 0;

   wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
   wire [1:0]  ba, dqm;
   wire [12:0] a;
   wire [15:0] dq_out;
   tri  [15:0] dq;
   reg  [15:0] dq_iob;
   assign dq = dq_oe ? dq_out : 16'hzzzz;
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

   w9825g6 mem (.clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
                .ba(ba), .a(a), .dqm(dqm), .dq(dq));
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
                  void'(expq.pop_front());
                  n_chk++;
               end
            end else n_stall++;
         end
         if (req_rdy && n_req < NREQ && expq.size() < MAXOUT * 8) begin
            automatic int r = $urandom;
            automatic logic [5:0] s = r[5:0];
            automatic logic wr = r[6] | r[7];
            automatic logic [1:0] b0, b1;
            automatic logic [255:0] d;
            automatic logic [31:0] be;
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
      wait (n_req == NREQ && expq.size() == 0);
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
