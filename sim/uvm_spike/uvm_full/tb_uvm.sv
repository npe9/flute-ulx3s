// ================================================================
// tb_uvm.sv — trivial UVM 1.2 smoke test for the J0 spike.
// A uvm_env + uvm_driver + uvm_test talking through a config_db
// handle to a plain SV interface. This is the canonical "does
// --uvm work" probe from the Verilator docs.
// (adapted: explicit `import uvm_pkg::*;` — 5.052 has no --uvm switch,
//  so the vendored uvm_pkg must be imported like any other package)
// ================================================================

import uvm_pkg::*;

interface dut_if;
  logic clk;
  logic [7:0] data;
  logic valid;
endinterface

class trivial_driver extends uvm_driver #(uvm_sequence_item);
  virtual dut_if vif;
  `uvm_component_utils(trivial_driver)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual dut_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    repeat (4) begin
      @(posedge vif.clk);
      vif.data  <= 8'h5A;
      vif.valid <= 1'b1;
    end
    phase.drop_objection(this);
  endtask
endclass

class trivial_env extends uvm_env;
  `uvm_component_utils(trivial_env)
  trivial_driver drv;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv = trivial_driver::type_id::create("drv", this);
  endfunction
endclass

class trivial_test extends uvm_test;
  `uvm_component_utils(trivial_test)
  trivial_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = trivial_env::type_id::create("env", this);
  endfunction
endclass

module tb_top;
  dut_if the_if();
  logic clk = 0;
  assign the_if.clk = clk;
  always #5 clk = ~clk;   // needs --timing; part of what is being probed

  initial begin
    uvm_config_db #(virtual dut_if)::set(null, "uvm_test_top.env.drv", "vif", the_if);
    run_test("trivial_test");
  end
endmodule
