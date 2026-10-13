// ================================================================
// uart_agent.sv — J1 UART agent: driver + monitor classes.
//
// Both lift the PROVEN bit-level logic of the F1 C++ bench
// (tb_top.cpp) without redesigning the timing:
//
//   driver:   byte -> 10-bit frame (start 0, 8 data LSB-first, stop 1)
//             pushed on a bit queue; tick() shifts one bit onto
//             ftdi_txd and then holds it for CYCLES_PER_BIT further
//             ticks — the exact "load bit, timer=40, decrement, reload"
//             cadence of the C++ bench (each bit cell therefore spans
//             41 posedges; the DUT re-syncs on every start bit, which
//             is why the proven timing is kept verbatim).  Blocking
//             assigns only (NBA from class code needs the timing
//             engine, which this harness mode does not enable).
//
//   monitor:  mid-bit sampling of ftdi_rxd, a direct port of the C++
//             tx_sample() state machine: falling edge -> 1.5-bit wait
//             (sample = data bit 0) -> 8 bits at 1-bit spacing -> stop
//             bit check.  Completed bytes are appended to a log queue
//             (C++ polls it through the DPI bridge) and try_put into a
//             mailbox #(byte) for the scoreboard.
//
// Coding-style constraints (J0 verdict): no blocking mailbox calls, no
// NBA to interface signals, avoid reserved words in identifiers.
// ================================================================

package uart_agent_pkg;

  class uart_driver;
    virtual board_pins_if vif;
    localparam int CYCLES_PER_BIT = 40;   // 25 MHz / 625000 baud

    logic bits[$];     // pending wire levels, one per bit cell
    int   timer = 0;

    function new(virtual board_pins_if v);
      vif = v;
    endfunction

    function void send_byte(logic [7:0] b);
      bits.push_back(1'b0);                    // start
      for (int i = 0; i < 8; i++) bits.push_back(b[i]);
      bits.push_back(1'b1);                    // stop
    endfunction

    function int pending();
      return bits.size();
    endfunction

    // Called once per clock from the negedge tick in sv_tb_top.
    function void tick();
      if (timer > 0) begin
        timer--;
      end else if (bits.size() > 0) begin
        vif.ftdi_txd = bits.pop_front();      // blocking assign
        timer = CYCLES_PER_BIT;
      end
      // queue empty and timer expired: hold the line (idle = stop-bit 1)
    endfunction
  endclass

  class uart_monitor;
    virtual board_pins_if vif;
    mailbox #(byte) mbx;
    localparam int CYCLES_PER_BIT = 40;   // must match the driver

    // mid-bit sampling state (ports tb_top.cpp's tx_sample())
    int        st     = 0;   // 0 idle, 1 in start, 2 data, 3 stop
    int        cnt    = 0;
    logic [7:0] sh    = 0;
    int        nbits  = 0;

    // Reset-domain guard: ftdi_rxd is a DUT output and is UNDEFINED
    // until the power-on reset releases (src/Top.v: 256 clocks) and the
    // UART TX path drives the idle level.  --x-initial unique gives it
    // a random per-run startup value; if it starts low, sampling from
    // cycle 0 would assemble a phantom 0xFF "byte" from the idle-high
    // line.  The board's power-on reset releases at ~256 clocks; the
    // first real TX (boot ROM T-line) comes tens of thousands of
    // cycles later, so ignoring the line for 300 ticks loses nothing
    // and makes the monitor deterministic across seeds.
    int        warmup = 0;

    int          framing_errs = 0;
    logic [7:0]  logq[$];    // every completed byte, in order (DPI view)

    function new(virtual board_pins_if v, mailbox #(byte) m);
      vif = v;
      mbx = m;
    endfunction

    function int n_avail();
      return logq.size();
    endfunction

    function int byte_at(int idx);
      if (idx < 0 || idx >= int'(logq.size())) return -1;
      return int'(logq[idx]);
    endfunction

    // Called once per clock from the negedge tick in sv_tb_top.
    function void tick();
      bit b;
      if (warmup < 300) begin
        warmup++;
      end else begin
      b = vif.ftdi_rxd;
      case (st)
        0: if (b == 0) begin st = 1; cnt = 0; nbits = 0; sh = 0; end
        1: begin                                  // center of bit 0
          cnt++;
          if (cnt >= CYCLES_PER_BIT + CYCLES_PER_BIT / 2) begin
            cnt = 0;
            sh[0] = b;                            // this sample IS bit 0
            nbits = 1;
            st = 2;
          end
        end
        2: begin
          cnt++;
          if (cnt >= CYCLES_PER_BIT) begin
            cnt = 0;
            sh[nbits] = b;
            nbits++;
            if (nbits == 8) st = 3;
          end
        end
        3: begin
          cnt++;
          if (cnt >= CYCLES_PER_BIT) begin
            cnt = 0;
            st = 0;
            if (b == 1) begin
              logq.push_back(sh);
              if (!mbx.try_put(byte'(sh))) begin
                // unbounded mailbox: cannot happen; fail loudly if it does
                $error("[uart_monitor] scoreboard mailbox refused a byte");
              end
            end else begin
              framing_errs++;
              $display("[uart_monitor] WARNING: TX framing error (st=3 sample was 0), n_errs=%0d", framing_errs);
            end
          end
        end
        default: st = 0;
      endcase
      end
    endfunction
  endclass

endpackage
