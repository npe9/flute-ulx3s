// ================================================================
// tb_vif.sv — probe 2f: virtual interfaces + class-based pin agents
// under --no-timing, with DPI-C bridging to the C++ bench.
//
// Architecture proven here is the J1 architecture:
//   * interface object bound to the sim_board pin names
//   * driver/monitor CLASSES hold virtual interface handles and are
//     ticked once per clock from an always block (no timing controls
//     inside class code)
//   * C++ main drives the clock; SV export "DPI-C" functions give
//     the C++ bench an injection/query API (byte-level), which is
//     how J1 keeps the existing tb_top.cpp scenario FSM while the
//     agents live in SV.
// The "DUT" here is a toy loopback: registered RX -> TX after 4
// cycles, standing in for sim_board.
// ================================================================

interface board_uart_if;
  logic clk;
  logic ftdi_txd;   // host -> DUT   (driver agent drives this)
  logic ftdi_rxd;   // DUT -> host   (monitor agent watches this)
endinterface

module tb_top (input logic clk);
  board_uart_if uart_if();
  assign uart_if.clk = clk;

  // ---- toy DUT: echo registered RX to TX after 4 cycles ----------
  logic [7:0] sh = 0;
  int dly = 0;
  always @(posedge clk) begin
    sh <= {sh[6:0], uart_if.ftdi_txd};
    if (dly < 8) dly <= dly + 1;
  end
  assign uart_if.ftdi_rxd = sh[7];   // something observable toggling

  // ---- agents -----------------------------------------------------
  class uart_driver;
    virtual board_uart_if vif;
    logic bits[$];
    function new(virtual board_uart_if v);
      vif = v;
    endfunction
    function void send_byte(int b);
      bits.push_back(1'b0);                    // start
      for (int i = 0; i < 8; i++) bits.push_back((b >> i) & 1);
      bits.push_back(1'b1);                    // stop
    endfunction
    function int pending();
      return bits.size();
    endfunction
    function void tick();                      // called once per clock
      // blocking assign: NBA to interface signals from class code is
      // rejected under --no-timing (NOTIMING). J1 note: drive-side
      // ordering vs the DUT's posedge sampling must be handled by
      // ticking agents on the negedge (or accept same-edge update).
      if (bits.size() > 0) vif.ftdi_txd = bits.pop_front();
      else vif.ftdi_txd = 1'b1;
    endfunction
  endclass

  class uart_monitor;
    virtual board_uart_if vif;
    logic [7:0] sh = 0;
    int nbits = 0;
    int bytes[$];
    function new(virtual board_uart_if v);
      vif = v;
    endfunction
    function void tick();
      // sample the RX pin every cycle; a byte is declared complete
      // every 8 observed edges of the toy DUT's serial stream is
      // overkill — instead watch the driver side for loop checks.
      // Here we just shift so C++ can see movement.
      sh = {sh[6:0], vif.ftdi_rxd};
      nbits++;
    endfunction
    function int sample();
      return {24'b0, sh};
    endfunction
  endclass

  uart_driver  drv;
  uart_monitor mon;
  int n_injected = 0;
  logic [7:0] injected[$];

  initial begin
    uart_if.ftdi_txd = 1'b1;
    drv = new(uart_if);        // virtual interface handle into class
    mon = new(uart_if);
  end

  always @(posedge clk) begin
    drv.tick();
    mon.tick();
  end

  // ---- DPI bridge: C++ bench <-> SV agents ------------------------
  export "DPI-C" function sv_inject_byte;
  function void sv_inject_byte(input int b);
    drv.send_byte(b);
    injected.push_back(b[7:0]);
    n_injected++;
    $display("[sv] inject byte 0x%02x at time %0t", b[7:0], $time);
  endfunction

  export "DPI-C" function sv_injected_count;
  function int sv_injected_count();
    return n_injected;
  endfunction

  export "DPI-C" function sv_mon_sample;
  function int sv_mon_sample();
    return mon.sample();
  endfunction

  export "DPI-C" function sv_drv_pending;
  function int sv_drv_pending();
    return drv.pending();
  endfunction
endmodule
