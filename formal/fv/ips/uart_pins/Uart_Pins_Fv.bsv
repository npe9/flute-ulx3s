// Uart_Pins_Fv: synthesizable instances of src/Uart_Pins.bsv's mkUART_Pins for formal/fv, one per
// clocks-per-bit value (mkUART_Pins takes Integer parameters, so each value is its own module; a
// runtime parameter would be different hardware).  4 and 5: an even and an odd value (CPB / 2
// truncates), small enough for bmc over whole frames.  50: the 1 Mbaud console at 50 MHz.  434: the
// ESP32's 115200 baud at 50 MHz.  (217 is the 25 MHz CI top's ESP32 port, 25 its console.)
package Uart_Pins_Fv;

import Uart_Pins :: *;

(* synthesize *) module mkUART_Pins_4   (UART_Pins_IFC); let m <- mkUART_Pins (4, 1);   return m; endmodule
(* synthesize *) module mkUART_Pins_5   (UART_Pins_IFC); let m <- mkUART_Pins (5, 1);   return m; endmodule
(* synthesize *) module mkUART_Pins_50  (UART_Pins_IFC); let m <- mkUART_Pins (50, 1);  return m; endmodule
(* synthesize *) module mkUART_Pins_434 (UART_Pins_IFC); let m <- mkUART_Pins (434, 1); return m; endmodule

endpackage
