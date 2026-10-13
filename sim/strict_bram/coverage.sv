// ================================================================
// coverage.sv — J1 functional covergroups, sampled once at end of run
// from the scoreboard/driver counters and the strict BRAM2 model's
// per-instance counters (read hierarchically in sv_tb_top).
//
// Groups:
//   cg_loader     loader-protocol bins: chunks ACKed, NAK count,
//                 last-chunk length, retry count (txns - acks)
//   cg_*_hazard   strict-BRAM census per RAM instance, mirroring
//                 BRAM2.v's final counters: lost-reads port A/B and
//                 cross-port hits per orientation (A-write+B-read,
//                 B-write+A-read).  Bin `hit` MUST stay EMPTY for a
//                 pass, EXCEPT cg_btb.cross_ba which carries the known
//                 benign branch-predictor hits (5611 on the F1
//                 known-good boot).  One covergroup TYPE per RAM:
//                 two instances of one type merge in coverage.dat
//                 (J0-risk probe), so each RAM gets its own type.
//   cg_milestones scenario milestone flags from the scoreboard.
//
// Every covergroup here takes its data through `with function sample`
// arguments and is sampled from sv_final_checks (end of run), keeping
// the sim kernel free of per-cycle covergroup overhead.  Wrapper
// class per covergroup type (the J0 coverage-probe pattern).
// ================================================================

package coverage_pkg;

  class loader_cov;
    covergroup cg with function sample(int unsigned chunks_acked,
                                       int unsigned naks,
                                       int unsigned last_len,
                                       int unsigned retries);
      coverpoint chunks_acked {
        bins one  = {1};
        bins two  = {2};
        bins few  = {[3:8]};
        bins lots = {[9:$]};
      }
      coverpoint naks {
        bins none = {0};
        bins some = {[1:$]};
      }
      coverpoint last_len {
        bins full    = {256};
        bins partial = {[1:255]};
      }
      coverpoint retries {
        bins none = {0};
        bins some = {[1:$]};
      }
    endgroup
    function new();
      cg = new();
    endfunction
  endclass

  // one hazard covergroup type per RAM instance (bins merge across
  // instances of a single type, so instances cannot share one)
  class icache_cword_cov;
    covergroup cg with function sample(int unsigned icw_lost_a, int unsigned icw_lost_b,
                                       int unsigned icw_cross_ab, int unsigned icw_cross_ba);
      coverpoint icw_lost_a   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint icw_lost_b   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint icw_cross_ab { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint icw_cross_ba { bins none = {0}; bins hit = {[1:$]}; }
    endgroup
    function new();
      cg = new();
    endfunction
  endclass

  class icache_tag_cov;
    covergroup cg with function sample(int unsigned ict_lost_a, int unsigned ict_lost_b,
                                       int unsigned ict_cross_ab, int unsigned ict_cross_ba);
      coverpoint ict_lost_a   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint ict_lost_b   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint ict_cross_ab { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint ict_cross_ba { bins none = {0}; bins hit = {[1:$]}; }
    endgroup
    function new();
      cg = new();
    endfunction
  endclass

  class dcache_cword_cov;
    covergroup cg with function sample(int unsigned dcw_lost_a, int unsigned dcw_lost_b,
                                       int unsigned dcw_cross_ab, int unsigned dcw_cross_ba);
      coverpoint dcw_lost_a   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint dcw_lost_b   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint dcw_cross_ab { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint dcw_cross_ba { bins none = {0}; bins hit = {[1:$]}; }
    endgroup
    function new();
      cg = new();
    endfunction
  endclass

  class dcache_tag_cov;
    covergroup cg with function sample(int unsigned dct_lost_a, int unsigned dct_lost_b,
                                       int unsigned dct_cross_ab, int unsigned dct_cross_ba);
      coverpoint dct_lost_a   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint dct_lost_b   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint dct_cross_ab { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint dct_cross_ba { bins none = {0}; bins hit = {[1:$]}; }
    endgroup
    function new();
      cg = new();
    endfunction
  endclass

  class btb_cov;
    covergroup cg with function sample(int unsigned btb_lost_a, int unsigned btb_lost_b,
                                       int unsigned btb_cross_ab, int unsigned btb_cross_ba);
      coverpoint btb_lost_a   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint btb_lost_b   { bins none = {0}; bins hit = {[1:$]}; }
      coverpoint btb_cross_ab { bins none = {0}; bins hit = {[1:$]}; }
      // benign predictor churn: `hit` is EXPECTED here (never fatal)
      coverpoint btb_cross_ba { bins none = {0}; bins hit = {[1:$]}; }
    endgroup
    function new();
      cg = new();
    endfunction
  endclass

  class milestones_cov;
    covergroup cg with function sample(bit m_prefix, bit m_first_ack, bit m_load_done,
                                       bit m_readback, bit m_hello, bit m_tick0);
      coverpoint m_prefix    { bins reached = {1}; bins missed = {0}; }
      coverpoint m_first_ack { bins reached = {1}; bins missed = {0}; }
      coverpoint m_load_done { bins reached = {1}; bins missed = {0}; }
      coverpoint m_readback  { bins reached = {1}; bins missed = {0}; }
      coverpoint m_hello     { bins reached = {1}; bins missed = {0}; }
      coverpoint m_tick0     { bins reached = {1}; bins missed = {0}; }
    endgroup
    function new();
      cg = new();
    endfunction
  endclass

  // ---- container owned by sv_tb_top ---------------------------------
  class tb_coverage;
    loader_cov       loader;
    icache_cword_cov icache_cword;
    icache_tag_cov   icache_tag;
    dcache_cword_cov dcache_cword;
    dcache_tag_cov   dcache_tag;
    btb_cov          btb;
    milestones_cov   milestones;

    // sampled-value shadow copies for print_summary (all deterministic)
    int s_acks = 0, s_naks = 0, s_last_len = 0, s_retries = 0;
    bit s_m_prefix = 0, s_m_first_ack = 0, s_m_load_done = 0,
        s_m_readback = 0, s_m_hello = 0, s_m_tick0 = 0;
    int haz_la[5], haz_lb[5], haz_cab[5], haz_cba[5];

    function new();
      loader       = new();
      icache_cword = new();
      icache_tag   = new();
      dcache_cword = new();
      dcache_tag   = new();
      btb          = new();
      milestones   = new();
    endfunction

    function void sample_loader(int acks, int naks, int last_len, int txns);
      s_acks     = acks;
      s_naks     = naks;
      s_last_len = last_len;
      s_retries  = txns - acks;
      loader.cg.sample(acks, naks, last_len, s_retries);
    endfunction

    // one call per RAM (idx 0..4):
    //   0 icache ram_cword_set   1 icache ram_state_and_ctag_cset
    //   2 dcache ram_cword_set   3 dcache ram_state_and_ctag_cset
    //   4 btb  btb_bramcore2
    function void sample_hazard(int idx,
                                int lost_a, int lost_b,
                                int cross_ab, int cross_ba);
      haz_la[idx]  = lost_a;
      haz_lb[idx]  = lost_b;
      haz_cab[idx] = cross_ab;
      haz_cba[idx] = cross_ba;
      case (idx)
        0: icache_cword.cg.sample(lost_a, lost_b, cross_ab, cross_ba);
        1: icache_tag.cg.sample(lost_a, lost_b, cross_ab, cross_ba);
        2: dcache_cword.cg.sample(lost_a, lost_b, cross_ab, cross_ba);
        3: dcache_tag.cg.sample(lost_a, lost_b, cross_ab, cross_ba);
        4: btb.cg.sample(lost_a, lost_b, cross_ab, cross_ba);
        default: ;
      endcase
    endfunction

    function void sample_milestones(bit m_prefix, bit m_first_ack, bit m_load_done,
                                    bit m_readback, bit m_hello, bit m_tick0);
      s_m_prefix    = m_prefix;
      s_m_first_ack = m_first_ack;
      s_m_load_done = m_load_done;
      s_m_readback  = m_readback;
      s_m_hello     = m_hello;
      s_m_tick0     = m_tick0;
      milestones.cg.sample(m_prefix, m_first_ack, m_load_done,
                             m_readback, m_hello, m_tick0);
    endfunction

    function void print_summary();
      $display("[sv-cov] loader: acks=%0d naks=%0d last_len=%0d retries=%0d",
               s_acks, s_naks, s_last_len, s_retries);
      $display("[sv-cov] milestones: prefix=%0d first_ack=%0d load_done=%0d readback=%0d hello=%0d tick0=%0d",
               s_m_prefix, s_m_first_ack, s_m_load_done, s_m_readback, s_m_hello, s_m_tick0);
      $display("[sv-cov] hazards icache_cword: la=%0d lb=%0d cab=%0d cba=%0d",
               haz_la[0], haz_lb[0], haz_cab[0], haz_cba[0]);
      $display("[sv-cov] hazards icache_tag:   la=%0d lb=%0d cab=%0d cba=%0d",
               haz_la[1], haz_lb[1], haz_cab[1], haz_cba[1]);
      $display("[sv-cov] hazards dcache_cword: la=%0d lb=%0d cab=%0d cba=%0d",
               haz_la[2], haz_lb[2], haz_cab[2], haz_cba[2]);
      $display("[sv-cov] hazards dcache_tag:   la=%0d lb=%0d cab=%0d cba=%0d",
               haz_la[3], haz_lb[3], haz_cab[3], haz_cba[3]);
      $display("[sv-cov] hazards btb:          la=%0d lb=%0d cab=%0d cba=%0d",
               haz_la[4], haz_lb[4], haz_cab[4], haz_cba[4]);
    endfunction
  endclass

endpackage
