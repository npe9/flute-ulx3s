// Uart_DMI_Bridge_Fv: src/Uart_DMI_Bridge.bsv's mkUart_DMI_Bridge_P for formal/fv.  _Fv: short
// timeouts (armed 24 clocks, partial magic 10), so bmc reaches them; _Real: the SoC's 50M / 500k.
package Uart_DMI_Bridge_Fv;

import Uart_DMI_Bridge :: *;

(* synthesize *) module mkUart_DMI_Bridge_Fv   (Uart_DMI_Bridge_IFC); let m <- mkUart_DMI_Bridge_P (24, 10);             return m; endmodule
(* synthesize *) module mkUart_DMI_Bridge_Real (Uart_DMI_Bridge_IFC); let m <- mkUart_DMI_Bridge_P (50_000_000, 500_000); return m; endmodule

endpackage
