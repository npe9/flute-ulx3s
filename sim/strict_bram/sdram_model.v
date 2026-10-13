// ================================================================
// sdram_model.v — behavioral model of the Winbond W9825G6KH-6
// (32 MB, 16-bit, 4 banks, SDR SDRAM) as wired to
// src/Sdram_Controller.bsv in the ULX3S Flute SoC.
//
// Scope: good enough for the controller's FSM, with EXACT data
// integrity (the loaded program must read back what was written).
// Modeled:
//   - JEDEC command set: NOP, ACT, READ, WRITE, PRE (incl. PRECHARGE
//     ALL via A10), AUTO REFRESH (accepted/counted, no array decay),
//     LOAD MODE REGISTER (parsed, logged; CL/burst reported)
//   - Zero write latency: WRITE beat 0 is sampled with the command
//     beat k on the following k cycles; per-byte DQM write mask.
//   - Read data timing matched to the controller + src/Top.v IOB
//     register pipeline: a READ command presented on the pins during
//     cycle N drives burst beat 0 onto DQ during cycle N+1, one beat
//     per cycle (CL2 as programmed via the mode register, folded with
//     the Top.v pad register; pin-level latency 1 — the same
//     convention the Bluesim SoC_Boot_Tb SDRAM model uses, shifted by
//     the IOB stage that only exists in the Verilog wrapper).
//   - Auto-precharge (A10=1 on READ/WRITE) closes the row after the
//     burst, mirroring the BSV reference model.
//   - Single open row per bank.  24-bit linear halfword address =
//     {bank[1:0], row[12:0], col[8:0]} (== the ModelAddr of
//     test/SoC_Boot_Tb.bsv).  Array is zero-initialized (deterministic;
//     the boot ROM writes before it reads).
//
// NOT modeled: refresh decay, tRCD/tRP/tRFC enforcement, DQM on the
// read path (the controller never masks reads), self-refresh, CKE
// power-down (CKE low simply NOPs the command inputs).
// ================================================================

module w9825g6 (
    input  wire        clk,      // same 25 MHz the controller runs on
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  ba,
    input  wire [12:0] a,
    input  wire [1:0]  dqm,
    inout  wire [15:0] dq
);

   // JEDEC command encoding {cs_n, ras_n, cas_n, we_n}
   localparam CMD_NOP   = 4'b0111;
   localparam CMD_ACT   = 4'b0011;
   localparam CMD_READ  = 4'b0101;
   localparam CMD_WRITE = 4'b0100;
   localparam CMD_PRE   = 4'b0010;
   localparam CMD_REF   = 4'b0001;
   localparam CMD_MRS   = 4'b0000;

   // 4 banks x 8192 rows x 512 halfword cols = 16M x 16b = 32 MB
   reg [15:0] mem  [0:16777215];
   reg [12:0] open_row   [0:3];
   reg        row_open   [0:3];

   // read burst engine
   reg        rd_busy;
   reg [3:0]  rd_cnt;        // 1..7: beats 1..7 to drive; 8: release
   reg [23:0] rd_base;
   reg [1:0]  rd_bank;
   reg        rd_ap;
   reg [15:0] dq_r;
   reg        dq_oe_r;

   // write burst engine
   reg        wr_busy;
   reg [3:0]  wr_cnt;        // 1..7: beats 1..7 to sample
   reg [23:0] wr_base;
   reg [1:0]  wr_bank;
   reg        wr_ap;

   integer n_ref, n_act;
   integer init_mem; // loop var
   initial begin
      for (init_mem = 0; init_mem < 16777216; init_mem = init_mem + 1)
         mem[init_mem] = 16'h0000;
      open_row[0] = 0; open_row[1] = 0; open_row[2] = 0; open_row[3] = 0;
      row_open[0] = 0; row_open[1] = 0; row_open[2] = 0; row_open[3] = 0;
      rd_busy = 0; rd_cnt = 0; rd_base = 0; rd_bank = 0; rd_ap = 0;
      wr_busy = 0; wr_cnt = 0; wr_base = 0; wr_bank = 0; wr_ap = 0;
      dq_r = 16'h0000; dq_oe_r = 0;
      n_ref = 0; n_act = 0;
   end

   wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};

   assign dq = dq_oe_r ? dq_r : 16'hzzzz;

   // DQM write mask: dqm[1]=1 keeps the old high byte, dqm[0]=1 the low.
   function [15:0] merge_dqm(input [15:0] old_v, input [15:0] new_v, input [1:0] m);
      begin
         merge_dqm[15:8] = m[1] ? old_v[15:8] : new_v[15:8];
         merge_dqm[7:0]  = m[0] ? old_v[7:0]  : new_v[7:0];
      end
   endfunction

   always @(posedge clk) begin
      // -------------------------------------------------------------
      // Command decode (ignored while CKE is low, as during the
      // controller's power-up wait).
      if (cke && (cmd != CMD_NOP)) begin
         case (cmd)
           CMD_ACT: begin
              open_row[ba] <= a;
              row_open[ba] <= 1'b1;
              n_act = n_act + 1;
           end

           CMD_READ: begin
              // beat 0 is driven onto DQ from the next cycle (i.e. the
              // cycle right after the one that presented the command);
              // this matches the controller + Top.v IOB pipeline.
              dq_r    <= mem[{ba, open_row[ba], a[8:0]}];
              dq_oe_r <= 1'b1;
              rd_busy <= 1'b1;
              rd_cnt  <= 4'd1;
              rd_base <= {ba, open_row[ba], a[8:0]};
              rd_bank <= ba;
              rd_ap   <= a[10];
           end

           CMD_WRITE: begin
              // beat 0 rides with the command (zero write latency)
              if (dqm != 2'b11)
                 mem[{ba, open_row[ba], a[8:0]}] <=
                    merge_dqm(mem[{ba, open_row[ba], a[8:0]}], dq, dqm);
              wr_busy <= 1'b1;
              wr_cnt  <= 4'd1;
              wr_base <= {ba, open_row[ba], a[8:0]};
              wr_bank <= ba;
              wr_ap   <= a[10];
           end

           CMD_PRE: begin
              if (a[10]) begin
                 row_open[0] <= 1'b0; row_open[1] <= 1'b0;
                 row_open[2] <= 1'b0; row_open[3] <= 1'b0;
              end
              else
                 row_open[ba] <= 1'b0;
           end

           CMD_REF: begin
              n_ref = n_ref + 1;   // accepted; array does not decay
           end

           CMD_MRS: begin
              $display ("%0t SDRAM MRS: mode=%h (CL=%0d, BL=%0d, %s)",
                        $time, a, a[6:4],
                        (a[2:0] == 3'b000) ? 1 :
                        (a[2:0] == 3'b001) ? 2 :
                        (a[2:0] == 3'b010) ? 4 :
                        (a[2:0] == 3'b011) ? 8 : 1,
                        a[3] ? "interleaved" : "sequential");
           end

           default: ;
         endcase
      end

      // -------------------------------------------------------------
      // Read burst continuation: beat 1..7, one per cycle.  (A new
      // READ command overrides — cannot happen with this controller,
      // which inserts a GAP state between its two bursts, but keeps
      // the model well-defined.)
      if (rd_busy && !(cke && (cmd == CMD_READ))) begin
         if (rd_cnt < 8) begin
            dq_r    <= mem[rd_base + rd_cnt];
            dq_oe_r <= 1'b1;
            rd_cnt  <= rd_cnt + 4'd1;
         end
         else begin
            // beat 7 was on the bus during the previous cycle
            dq_oe_r <= 1'b0;
            rd_busy <= 1'b0;
            rd_cnt  <= 4'd0;
            if (rd_ap)
               row_open[rd_bank] <= 1'b0;
         end
      end

      // Write burst continuation.
      if (wr_busy) begin
         if (wr_cnt < 8) begin
            if (dqm != 2'b11)
               mem[wr_base + wr_cnt] <= merge_dqm(mem[wr_base + wr_cnt], dq, dqm);
            if (wr_cnt == 4'd7) begin
               wr_busy <= 1'b0;
               wr_cnt  <= 4'd0;
               if (wr_ap)
                  row_open[wr_bank] <= 1'b0;
            end
            else
               wr_cnt <= wr_cnt + 4'd1;
         end
      end
   end

endmodule
