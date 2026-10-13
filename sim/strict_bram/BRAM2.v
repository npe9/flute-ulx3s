// ================================================================
// BRAM2.v — STRICT drop-in replacement for the bsc Verilog library's
// BRAM2.v (dual-port synchronous BRAM, write-first, 1-cycle read).
//
// Interface, parameters and baseline timing are identical to the lib
// module (PIPELINED/ADDR_WIDTH/DATA_WIDTH/MEMSIZE; registered DO;
// write shows DIA/DIB on DO the cycle after the put; DO holds when
// the port is disabled).  On top of that it models the real ECP5
// DP16KD behaviors that Bluesim's idealized BRAM model structurally
// cannot express (see flute-ulx3s/AGENTS.md):
//
//   (a) LOST READ (the pipe2/pipe3 killer): a read is launched on a
//       port at cycle C (its data sits on DO during cycle C+1 and is
//       sampled by the consumer FF at the edge ending C+1).  If a
//       WRITE is launched on the SAME port at cycle C+1, real DP16KD
//       destroys the pending read data (the output register takes the
//       write data instead).  Bluesim/the lib model serialize the two
//       puts and return clean data, hiding the corruption.
//       (A read+write put in the SAME cycle on one port is impossible:
//       BRAM2 has a single WE per port; it is noted here only because
//       the hazard class was specified to include it.)
//
//   (b) CROSS-PORT same address: a write put on one port and a read
//       put on the other port to the same address in the same cycle
//       is undefined per Lattice.  Checked in both orientations, with
//       direction-specific severity (measured on the known-good boot,
//       STRICT_BRAM=warn, 2026-10-10):
//
//       (b1) port A WRITE + port B READ, same addr: only physically
//            possible on the cache RAMs (the BTB has WEA==0); there it
//            is FSM-unreachable in the known-good design (F4 review)
//            and always signals a real scheduling break -> $display +
//            count, FATAL in error mode.
//       (b2) port B WRITE + port A READ, same addr: only physically
//            possible on the BTB (cache RAMs have WEB==0), where it is
//            a NORMAL consequence of the predictor architecture
//            (bp_train writes port B while predict_req reads port A;
//            5611 benign hits on the known-good boot, all self-
//            correcting via redirect per AGENTS.md).  $display + count
//            in ALL modes, never fatal — the count is the regression
//            signal, not an individual hit.
//
// Strictness is selected with the plusarg +STRICT_BRAM=warn|corrupt|
// error (default error):
//   warn   : report only, clean data (baseline timing untouched)
//   corrupt: report AND poison the pending read's DO with a garbage
//            value during the collision cycle, so the consumer FF
//            actually latches corrupted data (like the silicon)
//   error  : report and $fatal on (a) and (b1); (b2) is reported and
//            counted only (see above)
//
// A `final` block prints the per-instance counters at end of sim.
//
// This file is SIM-ONLY.  It never enters the Yosys/nextpnr flow; the
// synthesis file list keeps using the stock lib BRAM2.v.
// ================================================================

`ifdef BSV_ASSIGNMENT_DELAY
`else
 `define BSV_ASSIGNMENT_DELAY
`endif

module BRAM2(CLKA,
             ENA,
             WEA,
             ADDRA,
             DIA,
             DOA,
             CLKB,
             ENB,
             WEB,
             ADDRB,
             DIB,
             DOB
             );

   parameter                      PIPELINED  = 0;
   parameter                      ADDR_WIDTH = 1;
   parameter                      DATA_WIDTH = 1;
   parameter                      MEMSIZE    = 1;

   input                          CLKA;
   input                          ENA;
   input                          WEA;
   input [ADDR_WIDTH-1:0]         ADDRA;
   input [DATA_WIDTH-1:0]         DIA;
   output [DATA_WIDTH-1:0]        DOA;

   input                          CLKB;
   input                          ENB;
   input                          WEB;
   input [ADDR_WIDTH-1:0]         ADDRB;
   input [DATA_WIDTH-1:0]         DIB;
   output [DATA_WIDTH-1:0]        DOB;

   reg [DATA_WIDTH-1:0]           RAM[0:MEMSIZE-1] /* synthesis syn_ramstyle="no_rw_check" */ ;
   reg [DATA_WIDTH-1:0]           DOA_R;
   reg [DATA_WIDTH-1:0]           DOB_R;
   reg [DATA_WIDTH-1:0]           DOA_R2;
   reg [DATA_WIDTH-1:0]           DOB_R2;

`ifdef BSV_NO_INITIAL_BLOCKS
`else
   // synopsys translate_off
   integer                        i;
   initial
   begin : init_block
      for (i = 0; i < MEMSIZE; i = i + 1) begin
         RAM[i] = { ((DATA_WIDTH+1)/2) { 2'b10 } };
      end
      DOA_R = { ((DATA_WIDTH+1)/2) { 2'b10 } };
      DOB_R = { ((DATA_WIDTH+1)/2) { 2'b10 } };
      DOA_R2 = { ((DATA_WIDTH+1)/2) { 2'b10 } };
      DOB_R2 = { ((DATA_WIDTH+1)/2) { 2'b10 } };
   end
   // synopsys translate_on
`endif // !`ifdef BSV_NO_INITIAL_BLOCKS

   // ----------------------------------------------------------------
   // Strict-mode selection (+STRICT_BRAM=warn|corrupt|error)

   localparam STRICT_WARN   = 1;
   localparam STRICT_CORRUPT= 2;
   localparam STRICT_ERROR  = 3;

   integer strict_mode;
   integer n_lost_a, n_lost_b, n_cross_ab, n_cross_ba;
   initial begin
      strict_mode = STRICT_ERROR;
      if ($test$plusargs("STRICT_BRAM=warn"))    strict_mode = STRICT_WARN;
      if ($test$plusargs("STRICT_BRAM=corrupt")) strict_mode = STRICT_CORRUPT;
      if ($test$plusargs("STRICT_BRAM=error"))   strict_mode = STRICT_ERROR;
      n_lost_a = 0; n_lost_b = 0; n_cross_ab = 0; n_cross_ba = 0;
   end

`ifdef VERILATOR
   final begin
      if ((n_lost_a + n_lost_b + n_cross_ab + n_cross_ba) != 0)
        $display ("STRICT_BRAM summary %m: lost_read A=%0d B=%0d | crossport Awr+Brd=%0d Bwr+Ard=%0d",
                  n_lost_a, n_lost_b, n_cross_ab, n_cross_ba);
   end
`endif

   // ----------------------------------------------------------------
   // Per-port read pipeline.  A read put at cycle C registers the
   // array value at the edge ending C (old-data semantics, exactly
   // like the lib model's DO_R <= RAM[ADDR]); the data is presented
   // on DO during cycle C+1, where the consumer's FF samples it at
   // the edge ending C+1.

   reg                        a_rd_pipe, b_rd_pipe;
   reg [ADDR_WIDTH-1:0]       a_rd_addr, b_rd_addr;
   reg [DATA_WIDTH-1:0]       a_rd_data, b_rd_data;
   reg [DATA_WIDTH-1:0]       a_garbage, b_garbage;

   // Write-first DO behavior (lib: DO_R <= DI on a write put).
   reg                        a_wr_pipe, b_wr_pipe;
   reg [DATA_WIDTH-1:0]       a_wr_di,   b_wr_di;

   // DO hold value when the port did nothing last cycle.
   reg [DATA_WIDTH-1:0]       a_do_hold, b_do_hold;

   // (a) collision: write launched on the port during the very cycle
   // the pending read's data is on DO (visible combinationally here,
   // which is what lets corrupt mode actually poison the sampled
   // value — the consumer FF latches DO at the end of this cycle).
   // The poison itself is gated on corrupt mode; warn/error keep the
   // data clean (they only report).
   wire a_lost_now = a_rd_pipe && ENA && WEA;
   wire b_lost_now = b_rd_pipe && ENB && WEB;

   // ----------------------------------------------------------------
   // Combinational DO mux (registered-array data => identical timing
   // to the lib model; corruption only in corrupt mode).
`ifdef VERILATOR
   /* verilator lint_off WIDTH */
`endif
   wire [DATA_WIDTH-1:0] a_do_pre =
      a_rd_pipe  ? (a_lost_now ? ((strict_mode == STRICT_CORRUPT) ? (a_rd_data ^ a_garbage)
                                                                  : a_rd_data)
                               : a_rd_data)
    : a_wr_pipe  ? a_wr_di
    :              a_do_hold;
   wire [DATA_WIDTH-1:0] b_do_pre =
      b_rd_pipe  ? (b_lost_now ? ((strict_mode == STRICT_CORRUPT) ? (b_rd_data ^ b_garbage)
                                                                  : b_rd_data)
                               : b_rd_data)
    : b_wr_pipe  ? b_wr_di
    :              b_do_hold;
`ifdef VERILATOR
   /* verilator lint_on WIDTH */
`endif

   // ----------------------------------------------------------------
   // Port A
   always @(posedge CLKA) begin
      // ---- (a) same-port lost read --------------------------------
      if (a_lost_now) begin
         n_lost_a = n_lost_a + 1;
         if (strict_mode == STRICT_WARN)
           $display ("%0t STRICT_BRAM(warn) %m port A LOST READ: write put at cycle C+1 destroys read (addr %h) launched at cycle C",
                     $time, a_rd_addr);
         else if (strict_mode == STRICT_CORRUPT)
           $display ("%0t STRICT_BRAM(corrupt) %m port A LOST READ: pending read data (addr %h) poisoned",
                     $time, a_rd_addr);
         else
           $fatal (1, "%0t STRICT_BRAM(error) %m port A LOST READ: write put while read pending (addr %h) — real DP16KD destroys the pending read data",
                   $time, a_rd_addr);
      end

      // ---- (b1) cross-port same-address: A WRITE + B READ ---------
      // Only physically possible on the cache RAMs (BTB: WEA==0);
      // FSM-unreachable there in the known-good design -> any hit is
      // a real scheduling break -> fatal in error mode.
      if (ENA && WEA && ENB && !WEB && (ADDRA == ADDRB)) begin
         n_cross_ab = n_cross_ab + 1;
         if (strict_mode == STRICT_WARN || strict_mode == STRICT_CORRUPT)
           $display ("%0t STRICT_BRAM %m CROSS-PORT same-address: port A WRITE addr %h same cycle as port B READ (undefined per Lattice)",
                     $time, ADDRA);
         else
           $fatal (1, "%0t STRICT_BRAM(error) %m CROSS-PORT same-address: port A WRITE addr %h same cycle as port B READ",
                   $time, ADDRA);
      end

      // ---- baseline BRAM behavior (lib-identical) ------------------
      a_rd_pipe <= ENA && !WEA;
      a_wr_pipe <= ENA &&  WEA;
      if (ENA) begin
         if (WEA) begin
            RAM[ADDRA] <= `BSV_ASSIGNMENT_DELAY DIA;
            a_wr_di    <= `BSV_ASSIGNMENT_DELAY DIA;
            a_rd_data  <= `BSV_ASSIGNMENT_DELAY DIA; // unused (rd_pipe=0)
         end
         else begin
            a_rd_data  <= `BSV_ASSIGNMENT_DELAY RAM[ADDRA];
            a_rd_addr  <= `BSV_ASSIGNMENT_DELAY ADDRA;
`ifdef VERILATOR
            /* verilator lint_off WIDTH */
`endif
            a_garbage  <= {8{$random}};
`ifdef VERILATOR
            /* verilator lint_on WIDTH */
`endif
         end
      end
      a_do_hold <= a_do_pre;
      DOA_R  <= `BSV_ASSIGNMENT_DELAY a_do_pre;
      DOA_R2 <= `BSV_ASSIGNMENT_DELAY DOA_R;
   end

   // ----------------------------------------------------------------
   // Port B.  Includes the other orientation of (b): port-B write
   // same cycle as port-A read, same address.
   always @(posedge CLKB) begin
      if (b_lost_now) begin
         n_lost_b = n_lost_b + 1;
         if (strict_mode == STRICT_WARN)
           $display ("%0t STRICT_BRAM(warn) %m port B LOST READ: write put at cycle C+1 destroys read (addr %h) launched at cycle C",
                     $time, b_rd_addr);
         else if (strict_mode == STRICT_CORRUPT)
           $display ("%0t STRICT_BRAM(corrupt) %m port B LOST READ: pending read data (addr %h) poisoned",
                     $time, b_rd_addr);
         else
           $fatal (1, "%0t STRICT_BRAM(error) %m port B LOST READ: write put while read pending (addr %h) — real DP16KD destroys the pending read data",
                   $time, b_rd_addr);
      end

      // ---- (b2) cross-port same-address: B WRITE + A READ ---------
      // Only physically possible on the BTB (cache RAMs: WEB==0);
      // a normal, benign event there (predictor self-corrects via
      // redirect) -> reported (throttled) + counted in ALL modes,
      // never fatal; the count is the regression signal.
      if (ENB && WEB && ENA && !WEA && (ADDRB == ADDRA)) begin
         n_cross_ba = n_cross_ba + 1;
         if (n_cross_ba <= 20)
           $display ("%0t STRICT_BRAM %m cross-port(benign) same-address: port B WRITE addr %h same cycle as port A READ",
                     $time, ADDRB);
      end

      b_rd_pipe <= ENB && !WEB;
      b_wr_pipe <= ENB &&  WEB;
      if (ENB) begin
         if (WEB) begin
            RAM[ADDRB] <= `BSV_ASSIGNMENT_DELAY DIB;
            b_wr_di    <= `BSV_ASSIGNMENT_DELAY DIB;
            b_rd_data  <= `BSV_ASSIGNMENT_DELAY DIB;
         end
         else begin
            b_rd_data  <= `BSV_ASSIGNMENT_DELAY RAM[ADDRB];
            b_rd_addr  <= `BSV_ASSIGNMENT_DELAY ADDRB;
`ifdef VERILATOR
            /* verilator lint_off WIDTH */
`endif
            b_garbage  <= {8{$random}};
`ifdef VERILATOR
            /* verilator lint_on WIDTH */
`endif
         end
      end
      b_do_hold <= b_do_pre;
      DOB_R  <= `BSV_ASSIGNMENT_DELAY b_do_pre;
      DOB_R2 <= `BSV_ASSIGNMENT_DELAY DOB_R;
   end

   // Output drivers (PIPELINED=0 everywhere in this design, but keep
   // the lib's second pipeline stage for drop-in fidelity).
   assign DOA = (PIPELINED) ? DOA_R2 : a_do_pre;
   assign DOB = (PIPELINED) ? DOB_R2 : b_do_pre;

endmodule // BRAM2
