// ================================================================
// board_pins_if.sv — J1 (Track J, option B) board-pins interface.
//
// Virtual interface carried into the SV agent classes (driver/monitor)
// exactly as the J0 vif probe proved under --no-timing.  Pin ownership
// split between the C++ bench (tb_top.cpp) and the SV agents:
//
//   C++ main owns (top-level ports of sv_tb_top, driven/sampled
//   directly):   clk, btn1, jtag_tck/tms/tdi (tied off), and the
//                 observability outputs led, jtag_tdo, wifi_en and the
//                 sdram_* pin taps.
//
//   SV uart_driver DRIVES:   ftdi_txd (host -> FPGA RX pin)
//   SV uart_monitor SAMPLES: ftdi_rxd (FPGA TX pin -> host) and mirrors
//                 completed bytes to the C++ bench through the DPI
//                 bridge (sv_tx_avail / sv_tx_byte), replacing the old
//                 C++ tx_sample() logic bit-for-bit.
//
// ftdi_txd deliberately is NOT a top-level port anymore: the C++ main
// must not drive it (the driver agent does, on the negedge, so the pin
// is stable at every posedge the DUT samples).
// ================================================================

interface board_pins_if;
  logic clk;
  // DECLARATION-INITIALIZED: value is set at model construction, before
  // ANY eval.  An initial-block assignment (or a class write) would only
  // land during the first eval — possibly after the DUT's posedge-#1
  // sampling of this pin.  Under --x-initial unique an uninitialized
  // variable is randomized per seed at construction; a randomized LOW
  // here would be a phantom UART start bit, the boot ROM would skip its
  // banner and block in get_u32 forever (observed as seeds 2..4 hanging
  // with an empty TX tail).  The old C++ bench drove this pin from C++
  // before the first eval and never had the exposure.
  logic ftdi_txd = 1'b1;   // host -> FPGA (agent-driven)
  logic ftdi_rxd;          // FPGA -> host (agent-sampled)
endinterface
