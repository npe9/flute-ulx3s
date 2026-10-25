// ================================================================
// scoreboard.sv — J1 golden TX-transcript scoreboard.
//
// Consumes every byte the uart_monitor assembles (mailbox try_get,
// drained once per clock from the negedge tick) and checks the default
// boot scenario's TX protocol shape:
//
//   phase PREFIX   byte-exact match of golden_prefix from transcript
//                  byte 0 (boot ROM SDRAM readback line + start of the
//                  boot banner; ends at "ULX3S Flute SoC" — the exact
//                  point the host reacts to, so everything up to here
//                  is race-free)
//   phase TAIL     opportunistic match of the remaining banner bytes
//                  (": boot loader\r\n"); the banner legitimately
//                  TRUNCATES mid-tail when the loader header arrives,
//                  so completion is not required — but any byte that
//                  is not the next banner-tail byte and not an
//                  ACK/NAK is a protocol violation
//   phase LOAD     only ACK (0x06) / NAK (0x15) may appear; per-byte
//                  accounting with immediate assertions:
//                    - ACK/NAK only after a full framed chunk has been
//                      queued (host-side txns counter, DPI-fed)
//                    - acks never exceed the expected chunk count
//                    - NAKs never exceed the expected NAK budget
//                      (default scenario: 0 -> any NAK fails the gate)
//   phase LF       the load ends with the ROM's "\r\n"
//   phase POSTLOAD everything else (head/tail readback line, repair
//                  window silence, hello banner + tick lines): checked
//                  for ordered markers at final_check, and against the
//                  full golden_postload string when one is baked in
//
// Failures are immediate assertions (compiled in with --assert; a
// failed assertion aborts with a nonzero exit code — that IS the J1
// gate).  final_check() also returns an error count so the C++ main
// can report cleanly if assertions are ever disabled.
//
// GOLDEN DATA IS PARAMETERIZABLE: J2 scenarios subclass or reconfigure
// (golden_prefix/tail/postload, expected_acks/naks, last_chunk_len).
// The defaults baked in here are the F1 known-good boot->load->hello
// transcript for sw/hello.bin (308 bytes, 2 chunks).
// ================================================================

package scoreboard_pkg;

  class scoreboard;
    mailbox #(byte) txmbox;

    // ---- golden data (J2 overrides these) --------------------------
    string golden_prefix   = "T12345678 9abcdef0\r\n\r\nULX3S Flute SoC";
    string golden_tail     = ": boot loader\r\n";
    string golden_postload = "[02000117 00010113 00000197 12818193 00000297 12428293 00000317 11c30313 : 33323130 37363534 62613938 66656463 00000000 00000000 00000000 00000000]\r\n\r\nHello from Flute (Bluespec RV32) on the ULX3S!\r\ntick 00000000";  // F1 reference transcript (hello.bin 308B)
    string hello_marker    = "Hello from Flute";
    string tick0_marker    = "tick 00000000";

    // ---- expectations, DPI-configured by the C++ main --------------
    int expected_acks  = 0;
    int expected_naks  = 0;
    int last_chunk_len = 0;
    bit configured     = 0;

    // framed-chunk transmissions queued by the host (DPI note per send)
    int txns = 0;

    // ---- live protocol state ---------------------------------------
    localparam int PH_PREFIX   = 0;
    localparam int PH_TAIL     = 1;
    localparam int PH_LOAD     = 2;
    localparam int PH_LF       = 3;
    localparam int PH_POSTLOAD = 4;

    int   phase    = PH_PREFIX;
    int   pre_idx  = 0;
    int   tail_idx = 0;
    byte  g;
    logic [7:0] b8;

    int acks_seen = 0;
    int naks_seen = 0;
    int n_bytes   = 0;
    int n_prefix_mism = 0;

    string postload = "";
    string full_tx  = "";

    // ---- milestone flags (feed the coverage covergroup) ------------
    bit m_prefix    = 0;
    bit m_first_ack = 0;
    bit m_load_done = 0;
    bit m_readback  = 0;
    bit m_hello     = 0;
    bit m_tick0     = 0;

    function new(mailbox #(byte) m);
      txmbox = m;
    endfunction

    function void set_expected(int n_cks, int last_len);
      expected_acks  = n_cks;
      expected_naks  = 0;              // default scenario must be NAK-free
      last_chunk_len = last_len;
      configured     = 1;
    endfunction

    function void note_chunk_txn();
      txns++;
    endfunction

    // Called once per clock, after the monitor tick.
    function void tick();
      // +SB_OFF (TB_ISA runs): the program prints right after the jump, overlapping the
      // ROM banner tail; drain the mailbox without checking.
      if ($test$plusargs("SB_OFF")) begin
        while (txmbox.try_get(g)) n_bytes++;
        return;
      end
      while (txmbox.try_get(g)) begin
        b8 = 8'(g);
        n_bytes++;
        full_tx = {full_tx, string'(b8)};
        case (phase)
          PH_PREFIX: begin
            if (b8 != 8'(golden_prefix[pre_idx])) begin
               n_prefix_mism++;
               $display("[scoreboard] banner prefix mismatch at byte %0d: got 0x%02x want 0x%02x (received so far: %s)",
                        n_bytes - 1, b8, 8'(golden_prefix[pre_idx]), full_tx);
            end
            pre_idx++;
            if (pre_idx == golden_prefix.len()) begin
              m_prefix = 1;
              phase    = PH_TAIL;
              tail_idx = 0;
            end
          end

          PH_TAIL: begin
            if (b8 == 8'h06 || b8 == 8'h15) begin
              phase = PH_LOAD;
              handle_load_byte(b8);
            end else begin
              assert (tail_idx < golden_tail.len() && b8 == 8'(golden_tail[tail_idx]))
                else $error("[scoreboard] unexpected byte 0x%02x while matching banner tail at index %0d",
                            b8, tail_idx);
              tail_idx++;
            end
          end

          PH_LOAD: begin
            if (b8 == 8'h0d) begin
              phase = PH_LF;
            end else begin
              handle_load_byte(b8);
            end
          end

          PH_LF: begin
            assert (b8 == 8'h0a)
              else $error("[scoreboard] byte 0x%02x after CR at load end (want LF)", b8);
            phase      = PH_POSTLOAD;
            m_readback = 1;
          end

          PH_POSTLOAD: begin
            postload = {postload, string'(b8)};
          end

          default: phase = PH_PREFIX;
        endcase
      end
    endfunction

    function void handle_load_byte(logic [7:0] b);
      // an ACK/NAK may only arrive after a full framed chunk has been
      // queued by the host (framing is host-side in phase 1)
      assert (txns > acks_seen + naks_seen)
        else $error("[scoreboard] %s arrived with no framed chunk in flight (acks=%0d naks=%0d txns=%0d)",
                    b == 8'h06 ? "ACK" : "NAK", acks_seen, naks_seen, txns);
      if (b == 8'h06) begin
        acks_seen++;
        if (acks_seen == 1) m_first_ack = 1;
        assert (configured)
          else $error("[scoreboard] ACK before sv_sb_set_expected configuration");
        assert (acks_seen <= expected_acks)
          else $error("[scoreboard] ACK %0d exceeds expected chunk count %0d", acks_seen, expected_acks);
        if (acks_seen == expected_acks && configured) m_load_done = 1;
      end else begin
        naks_seen++;
        assert (configured)
          else $error("[scoreboard] NAK before sv_sb_set_expected configuration");
        assert (naks_seen <= expected_naks)
          else $error("[scoreboard] NAK %0d exceeds expected NAK budget %0d (retry handling is a J2 scenario)",
                      naks_seen, expected_naks);
      end
    endfunction

    // The simulator's string builtin set has no .find(): substring
    // search by hand (transcripts are short).
    function bit contains_str(string hay, string needle);
      int n, m;
      n = hay.len();
      m = needle.len();
      if (m == 0 || n < m) return 1'b0;
      for (int i = 0; i + m <= n; i++)
        if (hay.substr(i, i + m - 1) == needle) return 1'b1;
      return 1'b0;
    endfunction

    // End-of-run verdict.  framing_errs comes from the monitor.
    // Returns the number of failed checks (0 = pass).
    function int final_check(input int framing_errs);
      int errs = 0;
      if ($test$plusargs("SB_OFF")) return 0;
      assert (n_prefix_mism == 0)
        else begin $error("[scoreboard] %0d banner prefix mismatches", n_prefix_mism); errs++; end
      assert (configured)
        else begin $error("[scoreboard] never configured by the C++ main"); errs++; end
      assert (phase == PH_POSTLOAD)
        else begin $error("[scoreboard] load never completed (phase=%0d, acks=%0d)", phase, acks_seen); errs++; end
      assert (framing_errs == 0)
        else begin $error("[scoreboard] monitor saw %0d TX framing errors", framing_errs); errs++; end
      assert (acks_seen == expected_acks)
        else begin $error("[scoreboard] acks_seen=%0d != expected %0d", acks_seen, expected_acks); errs++; end
      assert (naks_seen == expected_naks)
        else begin $error("[scoreboard] naks_seen=%0d != expected %0d", naks_seen, expected_naks); errs++; end
      assert (postload.len() > 0 && postload.substr(0, 0) == "[")
        else begin $error("[scoreboard] postload does not start with the readback '[' (got 0x%02x)",
                          postload.len() > 0 ? 8'(postload[0]) : 8'hff); errs++; end
      m_hello = contains_str(postload, hello_marker);
      assert (m_hello)
        else begin $error("[scoreboard] hello banner marker \"%s\" missing from postload", hello_marker); errs++; end
      if (postload.len() >= tick0_marker.len())
        m_tick0 = (postload.substr(postload.len() - tick0_marker.len(), postload.len() - 1) == tick0_marker);
      assert (m_tick0)
        else begin $error("[scoreboard] transcript does not end at \"%s\"", tick0_marker); errs++; end
      if (golden_postload != "") begin
        assert (postload == golden_postload)
          else begin
            $error("[scoreboard] golden_postload mismatch (%0d bytes vs %0d expected)",
                   postload.len(), golden_postload.len());
            errs++;
          end
      end
      return errs;
    endfunction

    function void report();
      $display("[scoreboard] TX transcript: %0d bytes | acks=%0d naks=%0d txns=%0d | phase=%0d",
               n_bytes, acks_seen, naks_seen, txns, phase);
      if (golden_postload == "")
        $display("[scoreboard] golden_postload not baked: marker/structural checks only");
    endfunction
  endclass

endpackage
