// ================================================================
// tb_coverage.sv — probe 2d: SV functional coverage (covergroup /
// coverpoint / bins / cross) under --no-timing, in J3's exact shape:
//
//   * loader_cov: UART loader protocol bins (chunk position, NAK
//     count) with a cross — the J3 "loader retry paths" model.
//   * hazard_cov: strict-BRAM violation bins that MUST STAY EMPTY —
//     the J3 rule "a non-empty bin IS the failure".
//
// Sampled from classes via explicit cg.sample(). coverage.dat is
// written by the --binary main; run.sh greps bin hit counts and
// enforces the empty-bin rule exactly as the J3 gate would.
// ================================================================

class loader_cov;
  covergroup cg with function sample(int unsigned chunk_idx,
                                     int unsigned n_chunks,
                                     int unsigned naks);
    coverpoint chunk_idx {
      bins first  = {0};
      bins middle = {[1:5]};
      bins last   = {[6:$]};
    }
    coverpoint naks {
      bins none  = {0};
      bins one   = {1};
      bins many  = {[2:5]};
      bins flood = {[6:$]};
    }
    cross chunk_idx, naks;   // NOTE: explicit cross bins via binsof()
                             // are unsupported (COVERIGN) — auto cross only
  endgroup
  function new();
    cg = new();
  endfunction
endclass

class hazard_cov;
  // strict-BRAM hazard observation bins: EMPTY is the pass criterion
  covergroup cg with function sample(bit lost_read, bit cross_port_cache);
    coverpoint lost_read {
      bins clean    = {0};
      bins violated = {1};
    }
    coverpoint cross_port_cache {
      bins clean    = {0};
      bins violated = {1};
    }
  endgroup
  function new();
    cg = new();
  endfunction
endclass

module tb_top;
  loader_cov lc;
  hazard_cov hc;

  initial begin
    int unsigned n_chunks;
    int unsigned naks;
    lc = new();
    hc = new();

    // fake a 7-chunk load with a couple of NAK retries
    for (int lap = 0; lap < 3; lap++) begin
      n_chunks = 7;
      for (int c = 0; c < 7; c++) begin
        naks = 0;
        if (c == 2 && lap == 1) naks = 1;
        if (c == 5 && lap == 2) naks = 2;
        lc.cg.sample(c, n_chunks, naks);
        // known-good DUT: hazards never fire (samples all clean)
        hc.cg.sample(1'b0, 1'b0);
      end
    end

    // inject one clean observation of each non-violation side is
    // already done; we deliberately do NOT sample a violation.
    $display("[tb] sampled 21 loader points, 21 clean hazard points");
    $finish;
  end
endmodule
