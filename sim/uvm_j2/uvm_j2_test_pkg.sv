// ================================================================
// uvm_j2_test_pkg.sv — J2 sequences and tests.
//
// flute_boot_base_seq carries the whole boot->load->hello scenario as
// reusable tasks (banner wait, loader header, ACK/NAK-paced framed
// chunks with retry, readback, hello/tick markers), driven through the
// UVM sequencer/driver handshake.  Derived sequences only set knobs in
// pre_body; the J1 scoreboard stays the verdict gate (reconfigured per
// scenario: expected_naks budget, chunk expectations).
//
// Milestone cycles are printed for parity against the J1 goldens.
//
// Scenario knob summary (all default to the golden boot_hello path):
//   corrupt_chunk    which chunk index gets faulted on early attempts
//   corrupt_tries    how many attempts of that chunk are faulted
//   use_junk_prefix  fault mode: seq-byte corruption (else xor byte)
//   delay_per_chunk  idle cycles before each first-attempt chunk
//   max_naks         NAK budget handed to the scoreboard
// ================================================================

package uvm_j2_test_pkg;

  import uvm_pkg::*;
  import uart_agent_pkg::*;
  import scoreboard_pkg::*;
  import uvm_j2_base_pkg::*;
  import uvm_j2_agent_pkg::*;

  class flute_boot_base_seq extends uvm_sequence #(uart_frame_item);
    `uvm_object_utils(flute_boot_base_seq)

    // scenario knobs
    int corrupt_chunk   = -1;
    int corrupt_tries   = 1;
    bit use_junk_prefix = 0;
    int delay_per_chunk = 0;
    int max_naks        = 0;

    // handles (filled in pre_body from the sequencer)
    virtual board_pins_if vif;
    uart_monitor  mon;
    scoreboard    sb;
    cycle_counter cyc;
    j2_ctrl       ctrl;
    nak_diag_filter filt;

    // image
    byte unsigned img_mem [0:65535];
    int img_len  = 0;
    int n_chunks = 0;
    int last_len = 0;

    // deadlines (cycles) — same values as the J1 bench
    longint unsigned banner_deadline   = 50000000;
    longint unsigned chunk_deadline    = 200000000;
    longint unsigned readback_deadline = 200000000;
    longint unsigned hello_deadline    = 600000000;

    // milestones (parity printout)
    longint unsigned m_banner = 0, m_first_ack = 0, m_load_done = 0,
                     m_readback = 0, m_hello = 0, m_tick0 = 0;
    int tx_scan = 0;

    function new(string name = "flute_boot_base_seq");
      super.new(name);
    endfunction

    task pre_body();
      flute_seqr s;
      super.pre_body();
      if (!$cast(s, m_sequencer))
        $fatal(1, "[j2] m_sequencer is not a flute_seqr");
      vif = s.vif; mon = s.mon; sb = s.sb; cyc = s.cyc; ctrl = s.ctrl;
      filt = s.filt;
      load_image();
      sb.set_expected(n_chunks, last_len);
    endtask

    task load_image();
      string path;
      if (!$value$plusargs("IMAGE_HEX=%s", path))
        $fatal(1, "[j2] +IMAGE_HEX plusarg missing");
      if (!$value$plusargs("IMAGE_LEN=%d", img_len))
        $fatal(1, "[j2] +IMAGE_LEN plusarg missing");
      if (img_len < 4 || img_len > 65536)
        $fatal(1, "[j2] IMAGE_LEN %0d out of range", img_len);
      $readmemh(path, img_mem);
      n_chunks = (img_len + 255) / 256;
      last_len = img_len - 256 * (n_chunks - 1);
      `uvm_info("J2", $sformatf("image %0d bytes -> %0d chunks (last %0d)",
                                img_len, n_chunks, last_len), UVM_LOW)
    endtask

    // next TX byte from the monitor log (deadline-bounded)
    task next_tx(output byte b, input longint unsigned dln);
      longint unsigned start = cyc.n;
      forever begin
        if (tx_scan < mon.n_avail()) begin
          b = byte'(mon.byte_at(tx_scan));
          tx_scan++;
          return;
        end
        if (cyc.n - start > dln)
          $fatal(1, "[j2] TX idle timeout at cyc %0d", cyc.n);
        @(posedge vif.clk);
      end
    endtask

    // wait for a marker string anywhere in the fresh TX stream
    task wait_marker(string m, input longint unsigned dln,
                     output longint unsigned at_cyc);
      byte b;
      int idx = 0;
      longint unsigned start = cyc.n;
      at_cyc = 0;
      forever begin
        while (tx_scan < mon.n_avail()) begin
          b = byte'(mon.byte_at(tx_scan));
          tx_scan++;
          if (b == m[idx]) begin
            idx++;
            if (idx == m.len()) begin
              at_cyc = cyc.n;
              return;
            end
          end else begin
            idx = (b == m[0]) ? 1 : 0;
          end
        end
        if (cyc.n - start > dln)
          $fatal(1, "[j2] marker \"%s\" never arrived (cyc %0d)", m, cyc.n);
        @(posedge vif.clk);
      end
    endtask

    function void build_frame(int ci, ref byte unsigned fq[$]);
      int off = ci * 256;
      int m = (img_len - off < 256) ? img_len - off : 256;
      byte unsigned x = 0;
      fq.delete();
      fq.push_back(byte'(ci & 255));
      for (int i = 0; i < m; i++) begin
        fq.push_back(img_mem[off + i]);
        x ^= img_mem[off + i];
      end
      fq.push_back(x);
      fq.push_back(8'h55);
    endfunction

    task send_frame(ref byte unsigned fq[$], input bit is_raw,
                    input bit corrupt, input int junk, input int dly);
      uart_frame_item it;
      it = uart_frame_item::type_id::create("frame");
      it.is_raw       = is_raw;
      it.frame_q      = fq;
      it.corrupt_xor  = corrupt;
      it.junk_prefix  = junk;
      it.delay_cycles = dly;
      start_item(it);
      finish_item(it);
    endtask

    task send_chunk(int ci);
      bit done = 0;
      byte unsigned fq[$];
      build_frame(ci, fq);
      for (int attempt = 0; attempt < 8 && !done; attempt++) begin
        bit do_corrupt = (attempt < corrupt_tries) && (ci == corrupt_chunk)
                         && !use_junk_prefix;
        bit do_junk    = (attempt < corrupt_tries) && (ci == corrupt_chunk)
                         && use_junk_prefix;
        int dly        = (attempt == 0) ? delay_per_chunk : 0;
        send_frame(fq, 1'b0, do_corrupt, int'(do_junk), dly);
        forever begin
          byte b;
          next_tx(b, chunk_deadline);
          if (b == 8'h06) begin
            if (m_first_ack == 0) m_first_ack = cyc.n;
            done = 1;
            break;
          end else if (b == 8'h15) begin
            `uvm_info("J2", $sformatf("chunk %0d attempt %0d NAKed at cyc %0d",
                                      ci, attempt, cyc.n), UVM_LOW)
            break;
          end
        end
      end
      if (!done) $fatal(1, "[j2] chunk %0d never ACKed (8 attempts)", ci);
    endtask

    // per-scenario extra checks after the full transcript (the J1
    // scoreboard's final_check remains the verdict gate, run by the
    // tb top after run_test returns)
    virtual function void post_checks();
    endfunction

    task body();
      byte unsigned hdr[$];
      // apply the NAK budget here, after every derived pre_body override
      // has run (pre_body order is base-first, so applying it there
      // would see the base-class knob values)
      sb.expected_naks = max_naks;
      wait_marker("ULX3S Flute SoC", banner_deadline, m_banner);
      ctrl.banner_cyc = m_banner;
      `uvm_info("J2", $sformatf("MILESTONE banner %0d", m_banner), UVM_LOW)
      if (ctrl.smoke_only) begin
        repeat (200) @(posedge vif.clk);
        return;
      end

      // loader header: u32le dst, u32le len
      hdr.delete();
      for (int i = 0; i < 4; i++)
        hdr.push_back(byte'((32'h80000000 >> (8 * i)) & 8'hff));
      for (int i = 0; i < 4; i++)
        hdr.push_back(byte'((img_len >> (8 * i)) & 8'hff));
      send_frame(hdr, 1'b1, 1'b0, int'(0), int'(0));

      for (int ci = 0; ci < n_chunks; ci++) send_chunk(ci);
      m_load_done = cyc.n;
      `uvm_info("J2", $sformatf("MILESTONE load_done %0d (acks complete)",
                                m_load_done), UVM_LOW)

      wait_marker("[", readback_deadline, m_readback);
      wait_marker("]", readback_deadline, m_readback);
      `uvm_info("J2", $sformatf("MILESTONE readback %0d", m_readback), UVM_LOW)
      wait_marker("Hello from Flute", hello_deadline, m_hello);
      `uvm_info("J2", $sformatf("MILESTONE hello %0d", m_hello), UVM_LOW)
      wait_marker("tick 00000000", hello_deadline, m_tick0);
      `uvm_info("J2", $sformatf("MILESTONE tick0 %0d", m_tick0), UVM_LOW)

      // freeze the scoreboard stream at exactly the golden end: the ROM
      // sends CR/LF right after the tick line, and any UVM-phase sim
      // time before final_check would let them append to postload.
      filt.freeze = 1;
      repeat (10) @(posedge vif.clk);
      post_checks();
    endtask
  endclass

  class boot_hello_seq extends flute_boot_base_seq;
    `uvm_object_utils(boot_hello_seq)
    function new(string name = "boot_hello_seq");
      super.new(name);
    endfunction
  endclass

  class corrupt_xor_seq extends flute_boot_base_seq;
    `uvm_object_utils(corrupt_xor_seq)
    function new(string name = "corrupt_xor_seq");
      super.new(name);
    endfunction
    task pre_body();
      super.pre_body();
      corrupt_chunk = 0;
      corrupt_tries = 1;
      max_naks      = 1;
    endtask
  endclass

  class double_corrupt_seq extends flute_boot_base_seq;
    `uvm_object_utils(double_corrupt_seq)
    function new(string name = "double_corrupt_seq");
      super.new(name);
    endfunction
    task pre_body();
      super.pre_body();
      corrupt_chunk = 0;
      corrupt_tries = 2;
      max_naks      = 2;
    endtask
  endclass

  class garbage_seq_seq extends flute_boot_base_seq;
    `uvm_object_utils(garbage_seq_seq)
    function new(string name = "garbage_seq_seq");
      super.new(name);
    endfunction
    task pre_body();
      super.pre_body();
      corrupt_chunk   = 0;
      corrupt_tries   = 1;
      max_naks        = 1;
      use_junk_prefix = 1;
    endtask
  endclass

  class chunk_delay_seq extends flute_boot_base_seq;
    `uvm_object_utils(chunk_delay_seq)
    function new(string name = "chunk_delay_seq");
      super.new(name);
    endfunction
    task pre_body();
      super.pre_body();
      delay_per_chunk = 500000;   // ~20 ms: under the ROM byte watchdog
      max_naks        = 0;
    endtask
  endclass

  // ---- tests -------------------------------------------------------
  class flute_base_test extends uvm_test;
    `uvm_component_utils(flute_base_test)
    flute_env env;
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = flute_env::type_id::create("env", this);
    endfunction
    virtual function flute_boot_base_seq make_seq();
      return null;
    endfunction
    task run_phase(uvm_phase phase);
      flute_boot_base_seq seq = make_seq();
      if (seq == null) $fatal(1, "[j2] make_seq returned null");
      phase.raise_objection(this);
      seq.start(env.seqr);
      phase.drop_objection(this);
    endtask
  endclass

  class boot_hello_test extends flute_base_test;
    `uvm_component_utils(boot_hello_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    virtual function flute_boot_base_seq make_seq();
      boot_hello_seq s;
      s = boot_hello_seq::type_id::create("seq");
      return s;
    endfunction
  endclass

  class corrupt_xor_test extends flute_base_test;
    `uvm_component_utils(corrupt_xor_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    virtual function flute_boot_base_seq make_seq();
      corrupt_xor_seq s;
      s = corrupt_xor_seq::type_id::create("seq");
      return s;
    endfunction
  endclass

  class double_corrupt_test extends flute_base_test;
    `uvm_component_utils(double_corrupt_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    virtual function flute_boot_base_seq make_seq();
      double_corrupt_seq s;
      s = double_corrupt_seq::type_id::create("seq");
      return s;
    endfunction
  endclass

  class garbage_seq_test extends flute_base_test;
    `uvm_component_utils(garbage_seq_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    virtual function flute_boot_base_seq make_seq();
      garbage_seq_seq s;
      s = garbage_seq_seq::type_id::create("seq");
      return s;
    endfunction
  endclass

  class chunk_delay_test extends flute_base_test;
    `uvm_component_utils(chunk_delay_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    virtual function flute_boot_base_seq make_seq();
      chunk_delay_seq s;
      s = chunk_delay_seq::type_id::create("seq");
      return s;
    endfunction
  endclass

endpackage
