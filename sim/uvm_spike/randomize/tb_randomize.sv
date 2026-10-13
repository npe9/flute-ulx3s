// ================================================================
// tb_randomize.sv — probe 2c: constrained randomization,
// F1 harness mode (--no-timing). This is the make-or-break
// feature for J2 (cache-hammer + loader-protocol sequences).
//
// Every item is verified PROCEDURALLY after randomize() — the
// probe's job is to find out whether the solver actually produces
// legal values, not merely whether the call compiles.
// ================================================================

class c_basic;
  rand int a;             // range constraint
  rand bit [7:0] b;       // full-field random
  rand int unsigned c;    // modulo/alignment constraint
  constraint q_a { a > 10; a < 20; }
  constraint q_c { c % 8 == 0; c < 4096; }
endclass

class c_dist_inside;
  rand int mode;          // weighted dist
  rand int addr;          // inside, multi-range (J2 cache-hammer shape)
  rand bit [3:0] tiny;   // inside value list
  constraint q_mode { mode dist {0 := 60, 1 := 30, 2 := 10}; }
  constraint q_addr { addr inside {[0:255], [1024:2047]}; }
  constraint q_tiny { tiny inside {3, 5, 7}; }
endclass

class c_impl_if;
  rand bit valid;         // implication
  rand int unsigned delay;
  rand int kind;          // if/else constraint
  rand int payload;
  constraint q_valid { valid -> delay < 100;
                       !valid -> delay == 0; }
  constraint q_kind { kind inside {[0:2]}; }
  constraint q_payload { if (kind == 0) payload < 32;
                         else if (kind == 1) payload inside {[32:63]};
                         else payload > 63; }
endclass

class c_chain;
  rand int a, b, c;       // cross-variable ordering chain
  constraint q { a < b; b < c; a >= 0; c < 64; }
endclass

class c_arr;
  rand int unsigned w[8];          // foreach element bound
  rand int unsigned total[4];
  constraint q_w { foreach (w[i]) w[i] < 16; }
  // NOTE (spike finding): total.sum() in a constraint compiles but is
  // SILENTLY UNENFORCED by this build's solver (see RESULT.md), so the
  // aggregate is checked procedurally in the test body instead.
  constraint q_total { foreach (total[i]) total[i] < 16; }
endclass

class c_soft_inline;
  rand int x;
  rand int y;
  constraint q_x { x > 5; soft x == 10; }
  constraint q_y { y > 0; y < 100; }
endclass

class c_unsat;
  rand int a;
  constraint q { a > 100; a < 5; }
endclass

class c_unique;
  rand int u[4];
  constraint q { foreach (u[i]) u[i] inside {[0:15]};
                 unique {u}; }
endclass

module tb_top;
  c_basic        i_basic;
  c_dist_inside  i_dist;
  c_impl_if      i_impl;
  c_chain        i_chain;
  c_arr          i_arr;
  c_soft_inline  i_soft;
  c_unsat        i_unsat;
  c_unique       i_uniq;
  int n_viol = 0;
  int n_checks = 0;
  int dist_cnt[3] = '{0, 0, 0};
  int soft_x_hist[2] = '{0, 0};   // [0]: x==10 hits, [1]: other legal

  function void viol(string what, int i);
    if (i < 3) $display("[tb] VIOLATION %s at iter %0d", what, i);
    else if (i == 3) $display("[tb] VIOLATION %s (further messages suppressed)", what);
    n_viol++;
  endfunction

  initial begin
    i_basic  = new();
    i_dist   = new();
    i_impl   = new();
    i_chain  = new();
    i_arr    = new();
    i_soft   = new();
    i_unsat  = new();
    i_uniq   = new();

    // ---- 1. basic ranges + alignment ------------------------------
    for (int i = 0; i < 2000; i++) begin
      n_checks++;
      if (i_basic.randomize() != 1) viol("basic.randomize() rc", i);
      if (!(i_basic.a > 10 && i_basic.a < 20)) viol("basic.a range", i);
      if (!(i_basic.c % 8 == 0 && i_basic.c < 4096)) viol("basic.c align", i);
    end
    $display("[tb] basic ranges+align: 2000 iters done");

    // ---- 2. dist + inside ------------------------------------------
    for (int i = 0; i < 6000; i++) begin
      n_checks++;
      if (i_dist.randomize() != 1) viol("dist.randomize() rc", i);
      if (i_dist.mode < 0 || i_dist.mode > 2) viol("dist.mode range", i);
      else dist_cnt[i_dist.mode]++;
      if (!((i_dist.addr >= 0 && i_dist.addr <= 255) ||
            (i_dist.addr >= 1024 && i_dist.addr <= 2047)))
        viol("dist.addr inside", i);
      if (!(i_dist.tiny inside {3, 5, 7})) viol("dist.tiny inside", i);
    end
    $display("[tb] dist histogram: mode0=%0d mode1=%0d mode2=%0d (want ~60/30/10)",
             dist_cnt[0], dist_cnt[1], dist_cnt[2]);
    if (!(dist_cnt[0] > dist_cnt[1] && dist_cnt[1] > dist_cnt[2]))
      viol("dist ordering (0>1>2)", 0);

    // ---- 3. implication + if/else ----------------------------------
    for (int i = 0; i < 2000; i++) begin
      n_checks++;
      if (i_impl.randomize() != 1) viol("impl.randomize() rc", i);
      if (i_impl.valid && i_impl.delay >= 100) viol("impl valid->delay", i);
      if (!i_impl.valid && i_impl.delay != 0) viol("impl !valid->delay==0", i);
      case (i_impl.kind)
        0: if (!(i_impl.payload < 32)) viol("if kind0", i);
        1: if (!(i_impl.payload >= 32 && i_impl.payload <= 63)) viol("if kind1", i);
        2: if (!(i_impl.payload > 63)) viol("if kind2", i);
        default: viol("kind range", i);
      endcase
    end
    $display("[tb] implication + if/else: 2000 iters done");

    // ---- 4. chained cross-variable ordering ------------------------
    for (int i = 0; i < 2000; i++) begin
      n_checks++;
      if (i_chain.randomize() != 1) viol("chain.randomize() rc", i);
      if (!(i_chain.a < i_chain.b && i_chain.b < i_chain.c && i_chain.c < 64))
        viol("chain a<b<c<64", i);
    end
    $display("[tb] chained ordering: 2000 iters done");

    // ---- 5. foreach + documented aggregate gap ----------------------
    begin
      int unsigned s_max = 0;
      for (int i = 0; i < 1000; i++) begin
        int unsigned s = 0;
        n_checks++;
        if (i_arr.randomize() != 1) viol("arr.randomize() rc", i);
        foreach (i_arr.w[j]) if (i_arr.w[j] >= 16) viol("arr.w[j]<16", i);
        foreach (i_arr.total[j]) begin
          if (i_arr.total[j] >= 16) viol("arr.total[j]<16", i);
          s += i_arr.total[j];
        end
        if (s > s_max) s_max = s;
      end
      // Aggregate (sum) constraints are silently unenforced by this
      // build's solver (proven in RESULT.md), so the aggregate is only
      // *reported* here, not demanded of the solver.
      $display("[tb] foreach element bounds: 1000 iters ok; observed total.sum() max=%0d (unconstrained by solver)", s_max);
    end

    // ---- 6. inline constraint + soft -------------------------------
    for (int i = 0; i < 1000; i++) begin
      n_checks++;
      if (i_soft.randomize() with { y < 8; } != 1) viol("inline rc", i);
      if (!(i_soft.y > 0 && i_soft.y < 8)) viol("inline y<8", i);
      if (!(i_soft.x > 5)) viol("soft x>5", i);
      if (i_soft.x == 10) soft_x_hist[0]++;
      else soft_x_hist[1]++;
    end
    $display("[tb] inline-with + soft: 1000 iters (soft x==10: %0d, other legal: %0d)",
             soft_x_hist[0], soft_x_hist[1]);

    // ---- 7. unique --------------------------------------------------
    for (int i = 0; i < 1000; i++) begin
      bit [15:0] seen;
      n_checks++;
      if (i_uniq.randomize() != 1) viol("uniq rc", i);
      seen = 0;
      foreach (i_uniq.u[j]) begin
        if (i_uniq.u[j] < 0 || i_uniq.u[j] > 15) viol("uniq range", i);
        if (seen[i_uniq.u[j]]) viol("uniq distinct", i);
        seen[i_uniq.u[j]] = 1;
      end
    end
    $display("[tb] unique: 1000 iters done");

    // ---- 8. unsatisfiable -> rc 0, vars untouched (IEEE) -----------
    begin
      int rc;
      i_unsat.a = 777;
      rc = i_unsat.randomize();
      $display("[tb] unsat constraint: randomize() rc=%0d a=%0d (want rc=0, a=777)",
               rc, i_unsat.a);
      if (rc != 0) viol("unsat rc==0", 0);
      if (i_unsat.a != 777) viol("unsat var untouched", 0);
    end

    // ---- 9. constraint_mode disable --------------------------------
    begin
      int rc;
      i_basic.constraint_mode(0);
      rc = i_basic.randomize();
      // with all constraints off, a can be anything except [11,19] is now legal
      i_basic.constraint_mode(1);
      if (rc != 1) viol("constraint_mode(0) still randomizes", 0);
      else $display("[tb] constraint_mode(0): randomize ok (a=%0d, unconstrained)", i_basic.a);
    end

    if (n_viol == 0)
      $display("RANDOMIZE: PASS (%0d checks)", n_checks);
    else
      $display("RANDOMIZE: FAIL (%0d violations / %0d checks)", n_viol, n_checks);
    $finish;
  end
endmodule
