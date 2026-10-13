// ================================================================
// tb_uvm_full.sv — extended UVM probe: factory + config_db +
// sequencer/driver/sequence handshake + objections, on Verilator 5.052
// (vendored UVM, no --uvm switch). Adapted copy for /tmp/uvm_check.
// ================================================================

import uvm_pkg::*;

interface dut_if;
  logic clk;
  logic [7:0] data;
  logic valid;
endinterface

class trivial_item extends uvm_sequence_item;
  `uvm_object_utils(trivial_item)
  rand bit [7:0] data;

  function new(string name = "trivial_item");
    super.new(name);
  endfunction
endclass

class trivial_seq extends uvm_sequence #(trivial_item);
  `uvm_object_utils(trivial_seq)

  function new(string name = "trivial_seq");
    super.new(name);
  endfunction

  task body();
    trivial_item it;
    repeat (4) begin
      it = trivial_item::type_id::create("it");
      start_item(it);
      void'(it.randomize());
      finish_item(it);
      `uvm_info("SEQ", $sformatf("sent item data=%02x", it.data), UVM_LOW)
    end
  endtask
endclass

class trivial_driver extends uvm_driver #(trivial_item);
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
    trivial_item it;
    forever begin
      seq_item_port.get_next_item(it);
      @(posedge vif.clk);
      vif.data  <= it.data;
      vif.valid <= 1'b1;
      `uvm_info("DRV", $sformatf("drove data=%02x", it.data), UVM_LOW)
      seq_item_port.item_done();
    end
  endtask
endclass

class trivial_env extends uvm_env;
  `uvm_component_utils(trivial_env)
  trivial_driver drv;
  uvm_sequencer #(trivial_item) seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv = trivial_driver::type_id::create("drv", this);
    seqr = uvm_sequencer #(trivial_item)::type_id::create("seqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction

  task run_phase(uvm_phase phase);
    trivial_seq seq;
    phase.raise_objection(this);
    seq = trivial_seq::type_id::create("seq");
    seq.start(seqr);
    phase.drop_objection(this);
  endtask
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
