// ================================================================
// uvm_j2_base_pkg.sv — J2 (Track J, full-UVM) base package: sequence
// item + non-UVM helpers shared by the agent and test packages.
//
// cycle_counter: posedge counter ticked from the tb top so class code
// can read absolute cycle numbers without hierarchical references.
//
// uart_frame_item: one loader transaction — either the 8-byte header
// (is_raw) or a framed chunk [seq, data.., xor, 0x55] — plus the
// fault-injection knobs:
//   corrupt_xor  flip the checksum byte -> checksum-mismatch NAK+retry
//   junk_prefix  send N garbage bytes first -> seq-mismatch NAK+retry
//   delay_cycles idle before sending (loader pacing tolerance)
//
// nak_diag_filter: sits between the J1 monitor and the J1 scoreboard
// and swallows the 25-byte ASCII diagnostic the boot ROM prints right
// after every NAK:  'N' SP h8 SP h8 SP fff CR LF (f in s/g/x/-).
// Without it every diagnostic byte would count as another NAK in the
// scoreboard's load-phase else-branch, and the CR would flip its phase
// machine early.  The filter also shape-checks the diagnostic, so a
// malformed NAK line is a gate failure, not silent noise.
//
// j2_ctrl: shared control/status between the tb top and the sequences
// (smoke mode flag, observed banner cycle).
// ================================================================

package uvm_j2_base_pkg;

  import uvm_pkg::*;
  import uart_agent_pkg::*;

  class cycle_counter;
    longint unsigned n = 0;
    function void tick();
      n++;
    endfunction
  endclass

  class uart_frame_item extends uvm_sequence_item;
    `uvm_object_utils(uart_frame_item)

    bit is_raw       = 0;    // header path: bytes are not a framed chunk
    byte unsigned frame_q[$];
    bit corrupt_xor  = 0;
    int junk_prefix  = 0;
    int delay_cycles = 0;

    function new(string name = "uart_frame_item");
      super.new(name);
    endfunction
  endclass

  class nak_diag_filter;
    mailbox #(byte) in_mbx;
    mailbox #(byte) out_mbx;
    int swallow = 0;
    int n_diag  = 0;
    // set once the transcript-of-record is complete (tick0 seen): stops
    // forwarding to the scoreboard so trailing wire bytes (the CR/LF
    // after the tick line, any later output) cannot append to the
    // golden postload while UVM phase teardown runs.
    bit freeze = 0;

    function new(mailbox #(byte) i, mailbox #(byte) o);
      in_mbx = i;
      out_mbx = o;
    endfunction

    function automatic bit is_hex(byte g);
      return ((g >= "0") && (g <= "9")) || ((g >= "a") && (g <= "f"));
    endfunction

    function void check_diag_byte(int idx, byte g);
      bit ok;
      ok = 1;
      if (idx == 0)                      ok = (g == "N");
      else if (idx == 1 || idx == 10 || idx == 19)
                                         ok = (g == " ");
      else if (idx >= 2  && idx <= 9)    ok = is_hex(g);
      else if (idx >= 11 && idx <= 18)   ok = is_hex(g);
      else if (idx >= 20 && idx <= 22)
        ok = (g == "s") || (g == "g") || (g == "x") || (g == "-");
      else if (idx == 23)                ok = (g == 8'h0d);
      else if (idx == 24)                ok = (g == 8'h0a);
      assert (ok)
        else $error("[nak_filter] diagnostic byte %0d = 0x%02x out of shape", idx, g);
      n_diag++;
    endfunction

    function void tick();
      byte g;
      while (in_mbx.try_get(g)) begin
        if (freeze) begin
          // transcript-of-record complete: discard, do not forward
        end else if (swallow > 0) begin
          check_diag_byte(25 - swallow, g);
          swallow--;
        end else begin
          void'(out_mbx.try_put(g));
          if (g == 8'h15) swallow = 25;
        end
      end
    endfunction
  endclass

  class j2_ctrl;
    bit smoke_only = 0;
    longint unsigned banner_cyc = 0;
  endclass

endpackage
