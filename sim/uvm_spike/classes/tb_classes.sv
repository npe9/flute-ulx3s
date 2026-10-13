// ================================================================
// tb_classes.sv — probe 2a: SV classes for a UVM-style component
// tree WITHOUT uvm_pkg, under --no-timing (the F1 harness mode).
//
// Probes: class inheritance, virtual method dispatch through base
// handles, static class handles at module scope, parameterized
// classes (scoreboard), $urandom/$urandom_range in class code.
// ================================================================

package agent_pkg;

  virtual class component_base;
    string name;
    component_base children[$];
    function new(string name);
      this.name = name;
    endfunction
    function void add_child(component_base c);
      children.push_back(c);
    endfunction
    virtual function string kind();
      return "component";
    endfunction
    virtual function void do_step(int cycle);
    endfunction
    function void step_all(int cycle);
      do_step(cycle);
      foreach (children[i]) children[i].step_all(cycle);
    endfunction
  endclass

  class driver extends component_base;
    logic [7:0] last_data;
    function new(string name);
      super.new(name);
    endfunction
    virtual function string kind();
      return "driver";
    endfunction
    virtual function void do_step(int cycle);
      last_data = $urandom_range(0, 255);
      if (cycle < 3)
        $display("[drv %s] cycle %0d drove 0x%02x", name, cycle, last_data);
    endfunction
    function logic [7:0] current();
      return last_data;
    endfunction
  endclass

  class monitor extends component_base;
    int n_seen = 0;
    function new(string name);
      super.new(name);
    endfunction
    virtual function string kind();
      return "monitor";
    endfunction
    virtual function void do_step(int cycle);
      n_seen++;
    endfunction
  endclass

  class agent extends component_base;
    driver drv;
    monitor mon;
    function new(string name);
      super.new(name);
      drv = new({name, ".drv"});
      mon = new({name, ".mon"});
      add_child(drv);
      add_child(mon);
    endfunction
    virtual function string kind();
      return "agent";
    endfunction
  endclass

  class scoreboard #(type T = logic [7:0]);
    T expected[$];
    int n_match = 0;
    int n_mismatch = 0;
    function void add_expected(T v);
      expected.push_back(v);
    endfunction
    function void check(T got);
      T exp;
      if (expected.size() == 0) begin
        n_mismatch++;
        return;
      end
      exp = expected.pop_front();
      if (exp === got) n_match++;
      else n_mismatch++;
    endfunction
    function void report();
      $display("[scoreboard] match=%0d mismatch=%0d", n_match, n_mismatch);
    endfunction
  endclass

endpackage

module tb_top;
  import agent_pkg::*;

  agent uart_agent;
  scoreboard #(logic [7:0]) sb;
  component_base root;
  agent downcast_a;
  int n_kind_ok = 0;

  initial begin
    uart_agent = new("uart_agent");
    sb = new();
    root = uart_agent;   // upcast to virtual-base handle

    // virtual dispatch: kind() must resolve to "agent" through the
    // component_base handle
    if (root.kind() == "agent") n_kind_ok++;
    $display("[tb] root.kind() through base handle = %s", root.kind());

    // run the component tree for 5 cycles; driver produces values,
    // scoreboard checks them via the concrete handle
    for (int c = 0; c < 5; c++) begin
      root.step_all(c);
      sb.add_expected(uart_agent.drv.current());
      sb.check(uart_agent.drv.current());
    end
    if (uart_agent.mon.n_seen == 5) n_kind_ok++;
    sb.report();

    // downcast: $cast from base to derived
    if ($cast(downcast_a, root) && downcast_a == uart_agent) n_kind_ok++;
    $display("[tb] $cast base->agent ok");

    if (n_kind_ok == 3 && sb.n_match == 5 && sb.n_mismatch == 0)
      $display("CLASSES: PASS");
    else
      $display("CLASSES: FAIL (kind_ok=%0d)", n_kind_ok);
    $finish;
  end
endmodule
