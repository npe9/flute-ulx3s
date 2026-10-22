// Stand-alone Sdram_Controller unit test: controller + Top.v's DQ pad
// register + the W9825G6KH model + the JEDEC timing checker, driven
// with up to MAXOUT reads in flight and a randomly throttled response
// consumer, so f_rsps fills and the final-beat response stall path runs.
// PASS needs every read to match the shadow memory and 0 checker errors.
`timescale 1ns/1ps
module tb;
   localparam int NREQ   = 4000;
   localparam int MAXOUT = 4;

   reg clk = 0;  always #20 clk = ~clk;          // 25 MHz
   reg rst_n = 0;

   wire        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
   wire [1:0]  ba, dqm;
   wire [12:0] a;
   wire [15:0] dq_out;
   tri  [15:0] dq;
   reg  [15:0] dq_iob;
   assign dq = dq_oe ? dq_out : 16'hzzzz;
   always @(posedge clk) dq_iob <= dq;           // src/Top.v useioff register

   reg  [352:0] req;  reg req_en = 0;  wire req_rdy;
   wire [255:0] rsp;  reg rsp_en = 0;  wire rsp_rdy;
   wire init_done;

   mkSdram_UT dut (.CLK(clk), .RST_N(rst_n),
      .mem_server_request_put(req), .EN_mem_server_request_put(req_en), .RDY_mem_server_request_put(req_rdy),
      .EN_mem_server_response_get(rsp_en), .mem_server_response_get(rsp), .RDY_mem_server_response_get(rsp_rdy),
      .init_done(init_done),
      .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
      .sdram_ba(ba), .sdram_a(a), .sdram_dqm(dqm), .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe),
      .sdram_dq_in_v(dq_iob));

   w9825g6 mem (.clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
                .ba(ba), .a(a), .dqm(dqm), .dq(dq));
   sdram_timing_check #(.TCK_PS(40000)) chk (.clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n),
                .cas_n(cas_n), .we_n(we_n), .ba(ba), .a(a), .dqm(dqm));

   // 64 test words spread over 8 rows x 4 banks x 2 columns
   function automatic [63:0] sel2addr (input [5:0] s);
      sel2addr = {44'b0, 7'b0, s[5:3], 2'b0, s[1:0], 4'b0, s[2]};   // row[9:7] bank[6:5] col[0]
   endfunction

   reg [255:0] shadow [0:63];
   reg [255:0] expq [$];
   int n_req = 0, n_rd = 0, n_chk = 0, n_err = 0, outst = 0, n_stall = 0;
   int phase_throttle;
   initial for (int i = 0; i < 64; i++) shadow[i] = '0;

   function automatic [255:0] be2mask (input [31:0] be);
      for (int i = 0; i < 32; i++) be2mask[i*8 +: 8] = {8{be[i]}};
   endfunction

   // Drive at negedge from RDY values that are stable mid-cycle; the DUT
   // samples EN/data at the next posedge.
   always @(negedge clk) begin
      rsp_en = 0; req_en = 0;
      if (rst_n && init_done) begin
         // ---- response side: 1 in 60, then 1 in 6, then every cycle ----
         phase_throttle = (n_req < NREQ/3) ? 60 : (n_req < 2*NREQ/3) ? 6 : 1;
         if (rsp_rdy) begin
            if ($urandom % phase_throttle == 0) begin
               rsp_en = 1;
               if (expq.size() == 0) begin $display("FAIL: response with nothing outstanding"); n_err++; end
               else begin
                  if (rsp !== expq[0]) begin
                     n_err++;
                     if (n_err <= 5) $display("FAIL: read %0d got %h exp %h", n_chk, rsp, expq[0]);
                  end
                  void'(expq.pop_front());
                  n_chk++; outst--;
               end
            end else n_stall++;
         end
         // ---- request side ----
         if (req_rdy && n_req < NREQ && outst < MAXOUT) begin
            automatic int r = $urandom;
            automatic logic [5:0] s = r[5:0];
            automatic logic wr = r[6] | r[7];
            automatic logic [31:0] be = r[8] ? 32'hFFFF_FFFF : $urandom;
            automatic logic [255:0] d = {$urandom,$urandom,$urandom,$urandom,$urandom,$urandom,$urandom,$urandom};
            req    = {wr, be, sel2addr(s), d};
            req_en = 1;
            n_req++;
            if (wr) shadow[s] = (shadow[s] & ~be2mask(be)) | (d & be2mask(be));
            else begin expq.push_back(shadow[s]); outst++; n_rd++; end
         end
      end
   end

   initial begin
      repeat (10) @(posedge clk);
      rst_n = 1;
      wait (n_req == NREQ && expq.size() == 0);
      repeat (50) @(posedge clk);
      $display("[sdram_ut] %0d requests, %0d reads checked, %0d mismatches, %0d response-stall cycles",
               n_req, n_chk, n_err, n_stall);
      if (n_err == 0 && n_chk == n_rd) $display("[sdram_ut] PASS (see sdram_chk summary for timing)");
      else $display("[sdram_ut] FAIL");
      $finish;
   end
   initial begin #200ms; $display("[sdram_ut] FAIL: timeout"); $finish; end
endmodule
