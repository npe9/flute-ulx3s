// tb_j1risk.sv — J1 de-risk probe: (1) hierarchical references from the
// top module into leaf-module integer counters, read inside a function
// called via DPI export; (2) TWO INSTANCES of one covergroup type plus
// a distinct type — how do bin hierarchies render in coverage.dat;
// (3) package class with mailbox #(byte), string golden compare, and an
// immediate assertion that must NOT fire (pass case) — all under
// --no-timing with --assert --coverage --coverage-user.
package j1_pkg;
  class tx_monitor;
    mailbox #(byte) mbx;
    byte log[$];
    string golden = "AB";
    int framing_errs = 0;
    function new(mailbox #(byte) m);
      mbx = m;
    endfunction
    function void push(byte b);
      log.push_back(b);
      void'(mbx.try_put(b));
    endfunction
    function int check_golden();
      string s;
      foreach (log[i]) s = {s, string'(log[i])};
      return s == golden;
    endfunction
  endclass

  class j1_cov;
    // two instances of THIS type will be constructed
    covergroup cg_dup with function sample(int unsigned n_hits);
      coverpoint n_hits { bins none = {0}; bins hit = {[1:$]}; }
    endgroup
    function new();
      cg_dup = new();
    endfunction
  endclass

  class j1_cov_uniq;
    covergroup cg_unique with function sample(int unsigned n_hits);
      coverpoint n_hits { bins none = {0}; bins hit = {[1:$]}; }
    endgroup
    function new();
      cg_unique = new();
    endfunction
  endclass
endpackage

module leaf_module (input wire clk);
  integer n_lost_a = 0;
  integer n_cross_ba = 0;
  always @(posedge clk) begin
    n_lost_a    <= n_lost_a + 1;
    n_cross_ba  <= n_cross_ba + 2;
  end
endmodule

module mid_module (input wire clk);
  leaf_module ram_a (.clk(clk));
  leaf_module ram_b (.clk(clk));
endmodule

module tb_top (input wire clk);
  import j1_pkg::*;
  mid_module board (.clk(clk));
  tx_monitor mon;
  mailbox #(byte) mbx;
  j1_cov c0, c1;
  j1_cov_uniq cu;

  initial begin
    mbx = new();
    mon = new(mbx);
    c0 = new();
    c1 = new();
    cu = new();
    mon.push(byte'("A"));
    mon.push(byte'("B"));
    assert (mon.check_golden() == 1)
      else $error("golden compare failed in class");
  end

  export "DPI-C" function sv_probe_final;
  function int sv_probe_final();
    byte b;
    int n = 0;
    // (1) XMR reads of leaf counters (5 cycles have run)
    if (board.ram_a.n_lost_a != 5) return 101;
    if (board.ram_b.n_cross_ba != 10) return 102;
    // mailbox drain
    while (mbx.try_get(b)) n++;
    if (n != 2) return 103;
    // (2) covergroup sampling: two instances of one type + one unique
    c0.cg_dup.sample(0);
    c1.cg_dup.sample(3);
    cu.cg_unique.sample(7);
    $display("PROBE-XMR+CG: values ok, mailbox drained=%0d", n);
    return 0;
  endfunction
endmodule
