// ================================================================
// uvm_j2_agent_pkg.sv — J2 agent package: sequencer, driver, env.
//
// The driver pumps framed bytes into the J1 bit-cadence engine
// (uart_agent_pkg::uart_driver — the proven 40-cycle bit timing, kept
// verbatim) and notifies the J1 scoreboard once per framed chunk, which
// is the txns counter behind the scoreboard's "ACK only after a full
// framed chunk" assertion.  Fault knobs live on the item (base pkg).
//
// The sequencer doubles as the handle carrier into sequences: the env
// fills vif/monitor/scoreboard/counter/ctrl handles in build_phase,
// sequences read them from m_sequencer (plain $cast in pre_body).
// ================================================================

package uvm_j2_agent_pkg;

  import uvm_pkg::*;
  import uart_agent_pkg::*;
  import scoreboard_pkg::*;
  import uvm_j2_base_pkg::*;

  class flute_seqr extends uvm_sequencer #(uart_frame_item);
    `uvm_component_utils(flute_seqr)
    virtual board_pins_if vif;
    uart_monitor  mon;
    scoreboard    sb;
    cycle_counter cyc;
    j2_ctrl       ctrl;
    nak_diag_filter filt;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class flute_uart_driver extends uvm_driver #(uart_frame_item);
    `uvm_component_utils(flute_uart_driver)
    virtual board_pins_if vif;
    uart_driver j1_drv;
    scoreboard  sb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      uart_frame_item it;
      forever begin
        seq_item_port.get_next_item(it);
        if (it.delay_cycles > 0)
          repeat (it.delay_cycles) @(posedge vif.clk);
        for (int k = 0; k < it.junk_prefix; k++)
          j1_drv.send_byte(8'ha5);
        for (int i = 0; i < it.frame_q.size(); i++) begin
          byte unsigned b = it.frame_q[i];
          if (it.corrupt_xor && (i == it.frame_q.size() - 2))
            b = b ^ 8'hff;
          j1_drv.send_byte(b);
        end
        if (!it.is_raw) sb.note_chunk_txn();
        seq_item_port.item_done();
      end
    endtask
  endclass

  class flute_env extends uvm_env;
    `uvm_component_utils(flute_env)
    flute_seqr        seqr;
    flute_uart_driver drv;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      seqr = flute_seqr::type_id::create("seqr", this);
      drv  = flute_uart_driver::type_id::create("drv", this);
      if (!uvm_config_db #(virtual board_pins_if)::get(this, "", "vif", seqr.vif))
        `uvm_fatal("NOVIF", "board pins vif missing from config_db")
      if (!uvm_config_db #(virtual board_pins_if)::get(this, "", "vif", drv.vif))
        `uvm_fatal("NOVIF", "board pins vif missing from config_db")
      if (!uvm_config_db #(uart_driver)::get(this, "", "j1_drv", drv.j1_drv))
        `uvm_fatal("NOHND", "j1 driver handle missing from config_db")
      if (!uvm_config_db #(uart_monitor)::get(this, "", "uart_mon", seqr.mon))
        `uvm_fatal("NOHND", "uart monitor handle missing from config_db")
      if (!uvm_config_db #(scoreboard)::get(this, "", "sb", seqr.sb))
        `uvm_fatal("NOHND", "scoreboard handle missing from config_db")
      if (!uvm_config_db #(scoreboard)::get(this, "", "sb", drv.sb))
        `uvm_fatal("NOHND", "scoreboard handle missing from config_db")
      if (!uvm_config_db #(cycle_counter)::get(this, "", "cyc", seqr.cyc))
        `uvm_fatal("NOHND", "cycle counter missing from config_db")
      if (!uvm_config_db #(j2_ctrl)::get(this, "", "ctrl", seqr.ctrl))
        `uvm_fatal("NOHND", "j2_ctrl missing from config_db")
      if (!uvm_config_db #(nak_diag_filter)::get(this, "", "filt", seqr.filt))
        `uvm_fatal("NOHND", "nak_diag_filter missing from config_db")
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction
  endclass

endpackage
