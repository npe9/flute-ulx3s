// ================================================================
// tb_bram2_unit.v — unit test for the strict BRAM2 model: drives the
// pipe2/pipe3 lost-read pattern (read at C, write same port at C+1)
// and the cross-port patterns, and checks the model reacts.
//
// Not part of the F1 deliverable set; development/validation aid.
// Run: iverilog -o /dev/null... see run_unit.sh logic (not provided);
//      iverilog -g2005 tb_bram2_unit.v BRAM2.v && vvp -n a.out +STRICT_BRAM=...
// ================================================================

`timescale 1ns/1ps

module tb_bram2_unit;
   reg         clk = 0;
   reg         en_a = 0, we_a = 0;
   reg  [8:0]  addr_a = 0;
   reg  [31:0] di_a = 0;
   wire [31:0] do_a;
   reg         en_b = 0, we_b = 0;
   reg  [8:0]  addr_b = 0;
   reg  [31:0] di_b = 0;
   wire [31:0] do_b;

   BRAM2 #(.PIPELINED(1'd0), .ADDR_WIDTH(32'd9), .DATA_WIDTH(32'd32), .MEMSIZE(10'd512))
   dut (.CLKA(clk), .ENA(en_a), .WEA(we_a), .ADDRA(addr_a), .DIA(di_a), .DOA(do_a),
        .CLKB(clk), .ENB(en_b), .WEB(we_b), .ADDRB(addr_b), .DIB(di_b), .DOB(do_b));

   always #20 clk = ~clk;

   // consumer register sampling DOA on the next edge (like the design)
   reg [31:0] consumer_q = 0;
   always @(posedge clk) consumer_q <= do_a;

   integer errors = 0;

   initial begin
      // ---- init some data
      @(negedge clk); en_a = 1; we_a = 1; addr_a = 9'h55; di_a = 32'hdeadbeef;
      @(negedge clk); en_a = 0; we_a = 0;
      @(negedge clk); @(negedge clk);

      // ---- TEST 1: plain read, no hazard -> do_a correct next cycle
      @(negedge clk); en_a = 1; we_a = 0; addr_a = 9'h55;
      @(negedge clk); en_a = 0;
      @(negedge clk);
      if (do_a !== 32'hdeadbeef) begin
         $display ("UNIT FAIL T1: clean read got %h", do_a); errors = errors + 1;
      end else $display ("UNIT OK T1: clean read = %h", do_a);

      // ---- TEST 2: LOST READ pattern (pipe2/pipe3): read at C,
      //      write SAME port at C+1 -> must flag (mode-dependent).
      //      The consumer FF (consumer_q) latches DO at the end of the
      //      collision cycle: check it one negedge after the write put
      //      was presented (that negedge is right after the latching
      //      posedge).  In corrupt mode it must hold POISONED data, in
      //      warn/error clean read data.
      @(negedge clk); en_a = 1; we_a = 0; addr_a = 9'h55;   // read @C
      @(negedge clk); en_a = 1; we_a = 1; addr_a = 9'h66; di_a = 32'hcafe0001; // write @C+1
      @(negedge clk);                                        // latching posedge passed
      $display ("UNIT INFO T2: consumer_q latched at collision edge = %h (do_a now %h)",
                consumer_q, do_a);
      if ($test$plusargs("STRICT_BRAM=corrupt")) begin
         if (consumer_q === 32'hdeadbeef) begin
            $display ("UNIT FAIL T2: corrupt mode did not poison the consumer's latched read data");
            errors = errors + 1;
         end else $display ("UNIT OK T2: corrupt mode poisoned consumer_q = %h", consumer_q);
      end else begin
         if (consumer_q !== 32'hdeadbeef) begin
            $display ("UNIT FAIL T2: non-corrupt mode poisoned the read data: %h", consumer_q);
            errors = errors + 1;
         end else $display ("UNIT OK T2: clean read data survived = %h", consumer_q);
      end
      @(negedge clk); en_a = 0; we_a = 0;
      @(negedge clk);

      // ---- TEST 3: cross-port (b1): A write + B read same addr same cycle
      @(negedge clk);
      en_a = 1; we_a = 1; addr_a = 9'h77; di_a = 32'hcafe0002;
      en_b = 1; we_b = 0; addr_b = 9'h77;
      @(negedge clk); en_a = 0; en_b = 0;
      @(negedge clk);
      $display ("UNIT INFO T3: crossport Awr+Brd fired (see strict messages)");

      // ---- TEST 4: cross-port (b2): B write + A read same addr same cycle
      @(negedge clk);
      en_b = 1; we_b = 1; addr_b = 9'h78; di_b = 32'hcafe0003;
      en_a = 1; we_a = 0; addr_a = 9'h78;
      @(negedge clk); en_a = 0; en_b = 0;
      @(negedge clk);
      $display ("UNIT INFO T4: crossport Bwr+Ard fired (benign, counted)");

      // ---- TEST 5: back-to-back reads (pipelined, LEGAL) -> no flag,
      //      both reads correct
      @(negedge clk); en_a = 1; we_a = 0; addr_a = 9'h55;   // read @C
      @(negedge clk); addr_a = 9'h66;                       // read @C+1 (legal stream)
      @(negedge clk); en_a = 0;
      @(negedge clk);
      if (do_a !== 32'hcafe0001) begin
         $display ("UNIT FAIL T5: pipelined second read got %h", do_a); errors = errors + 1;
      end else $display ("UNIT OK T5: pipelined reads clean, second = %h", do_a);

      // ---- TEST 6: write then read next cycle on same port (LEGAL:
      //      read sees new data, no flag)
      @(negedge clk); en_a = 1; we_a = 1; addr_a = 9'h40; di_a = 32'h12345678;
      @(negedge clk); we_a = 0; addr_a = 9'h40;             // read @C+1 (write @C)
      @(negedge clk); en_a = 0;
      @(negedge clk);
      if (do_a !== 32'h12345678) begin
         $display ("UNIT FAIL T6: write-then-read got %h", do_a); errors = errors + 1;
      end else $display ("UNIT OK T6: write-then-read clean = %h", do_a);

      if (errors == 0) $display ("UNIT RESULT: PASS (behavioral checks)");
      else             $display ("UNIT RESULT: FAIL (%0d behavioral errors)", errors);
      $finish;
   end
endmodule
