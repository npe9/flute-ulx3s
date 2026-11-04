# ULX3S peripherals plan: what the board can do and how to build the IP for it

Goal: turn the ULX3S into a standalone computer for Linux and TempleOS (storage, boot without a
host, display, keyboard), then expose the rest of the board. Pin names below are those of the
reference constraints `bluespec-ulx3s/toolchain/prjtrellis/examples/ulx3s/ulx3s_v20.lpf`; copy
LOCATE/IOBUF lines from there into `constraints/ulx3s_85f.lpf`. Part numbers marked (check) must
be confirmed against the schematic of the board revision in hand.

## Board inventory and status

| Feature | Pins | Status / plan |
|---|---|---|
| 32 MB SDRAM | `sdram_*` | done (`src/Sdram_Controller.bsv`) |
| FTDI UART + DTR/RTS | `ftdi_*` | UART done (console, loader, DMI bridge); `ftdi_ndtr`/`nrts` unused |
| 8 LEDs, BTN1 | `led`, `btn[1]` | done (`src/AXI4_GPIO.bsv`) |
| microSD | `sd_clk/cmd/d[0..3]` | **phase 1, in progress**: SPI mode, `src/AXI4_SPI.bsv` |
| Config SPI flash | `flash_*` (clock via `USRMCLK`) | phase 1: boot images from flash |
| HDMI/DVI out (GPDI) | `gpdi_dp/dn[0..3]`, `gpdi_sda/scl` (DDC, shared with the RTC), `gpdi_cec` | phase 2: framebuffer |
| USB (FPGA-direct port US2) | `usb_fpga_dp/dn`, `usb_fpga_bd_dp/dn`, `usb_fpga_pu_dp/dn` | phase 2: keyboard (low-speed HID host) |
| Other 6 buttons, 4 DIP switches | `btn[0,2..6]`, `sw[0..3]` | phase 2: extend GPIO (trivial) |
| ESP32 (Wi-Fi/BT) | `wifi_en/rxd/txd/gpio0/5/16/17`; shares the SD pins | phase 3: second UART; today held in reset (`wifi_en=0`) so the SD pins are free |
| Real-time clock (MCP7940N, check) + battery | I2C on `gpdi_sda/scl` | phase 3: I2C host |
| Audio jack: 4-bit resistor DACs L/R + ring2 | `audio_l/r/v[0..3]` | phase 3: tone generator, then PCM via sigma-delta |
| Composite video / S/PDIF on ring2 | `audio_v` | phase 4 |
| SPI ADC, 8 channels (MAX11125, check) | `adc_*` | phase 3: second SPI instance |
| OLED/LCD header (7-pin SPI) | `oled_*` | phase 3: SPI instance (or the framebuffer mirrored to an ST7789-class LCD) |
| GPIO headers: 28 differential pairs | `gp/gn[0..27]` | phase 3: PMOD GPIO; phase 4: Ethernet PMOD (RMII), LVDS |
| HDMI Ethernet pair, CEC | `gpdi_ethp/ethn`, `gpdi_cec` | phase 4 (experimental) |
| 433 MHz antenna | `ant_433mhz` | phase 4 (OOK/FM transmitter toy; check local radio rules) |
| Power control | `shutdown`, `btn[0]` (power button) | phase 3: `poweroff` (with RTC wake-up) |
| Reconfigure from flash | `user_programn` | phase 3: multiboot (jump to another bitstream) |

Note: the core's JTAG TAP uses `gp[0]/gn[0]/gp[1]/gn[1]` on header J1. If the headers are
needed for PMODs, move the TAP onto the FTDI's JTAG pins through the ECP5 `JTAGG` primitive (the
same cable then programs the FPGA and debugs the core).

## Phases

1. **Storage and standalone boot.** (a) microSD in SPI mode: SiFive-SPI-compatible host so stock
   Linux `spi-sifive` + `mmc_spi` work; TempleOS block driver on the same registers. (b) Second
   SPI instance on the config flash; the boot ROM loads OpenSBI+Linux or the TempleOS blob from
   flash (or SD) when no host answers on the UART, so the board boots on power-up.
2. **Display and input.** (a) GPDI framebuffer: 640x480@60, DVI (TMDS via `ODDRX1F` at 126 MHz
   from a PLL output, pixel clock 25.2 MHz). Two scan-out modes: 4-bit palette from block RAM
   (TempleOS's native mode; 150 KB fits in ~68 of the 192 free DP16KD) and RGB565 from SDRAM
   (Linux `simple-framebuffer`, no kernel driver; 600 KB at 37 MB/s, a burst reader with a line
   FIFO). (b) USB keyboard: low-speed HID host on US2 (12 MHz-class soft PHY, its own clock),
   presenting key events through a PS/2-style register so Linux can use an existing serio driver
   (`altr,ps2-1.0`, check) and TempleOS reads scancodes directly. (c) all buttons and switches.
3. **Board services.** I2C host (Linux `opencores,i2c-ocores`, check) for the RTC and HDMI DDC;
   second 16550 UART to the ESP32 (Wi-Fi via an AT/SLIP/esp-hosted firmware, chosen later);
   audio (TempleOS `Snd()` tone first, then a PCM FIFO with sigma-delta output on the 4-bit DAC);
   ADC and OLED as SPI instances; power-off; multiboot.
4. **Extras.** Ethernet over a PMOD RMII PHY (a MAC register-compatible with a driver Linux has,
   e.g. LiteEth, check), composite video, S/PDIF, LVDS experiments, 433 MHz.

## Bus architecture for many small peripherals

Every AXI fabric port costs logic and has sat near the 50 MHz limit (the slave-3 write-data FIFO
is a recurring top path). Phase 1 adds the SPI host as fabric slave 5. From the next small
peripheral on, put the low-speed devices behind **one** fabric port: an AXI4 to 32-bit register
bus bridge (registered address decode, one outstanding access, a ready/wait handshake per
device). SPI x3, I2C, UART1, GPIO, audio and power control all hang off it. The framebuffer
(SDRAM reads) and any DMA engine are AXI masters/slaves of their own.

Address plan (4 KB each, under the peripheral bridge once it exists): `0xC000_4000` spi0 (SD),
`0xC000_5000` spi1 (flash), `0xC000_6000` i2c0, `0xC000_7000` uart1 (ESP32), `0xC000_8000`
gpio1 (buttons, switches, header pins), `0xC000_9000` audio, `0xC000_A000` spi2 (ADC),
`0xC000_B000` spi3 (OLED), `0xC000_C000` power/multiboot; framebuffer control at `0xC001_0000`,
palette-mode pixel RAM at `0xC100_0000`. PLIC sources (16 available): 0 uart0, 1 gpio,
2 spi0, then in the order added; keep `SoC_Map.bsv`, the device trees and the TempleOS headers
generated from one table (`MEMMAP` lines in the bsc log already feed `soc-memory-map.json`).

## How to develop an IP core here (the recipe the SPI host follows)

1. **Fix the software contract first.** Prefer a register interface that already has a Linux
   driver and DT binding (sifive,spi0; ns16550a; simple-framebuffer; opencores i2c), so Linux needs
   only a DT node and a config option. Read the driver source in the build container
   (`docker run --rm -v flute-linux-src:/src flute-rv32-build ...`) and write down exactly which
   registers, bits and orderings it depends on (probe sequences, read-to-pop, watermark meaning).
   Put that contract in the header comment of the BSV file. Check what TempleOS needs too.
2. **Write the block** in `src/` by copying `src/AXI4_SPI.bsv` (or `AXI4_GPIO.bsv`): AXI4 slave
   on the 64-bit fabric (a 32-bit register at +4 lives in lanes [63:32]), DECERR outside the window,
   `reset` drops in-flight transactions (ndmreset). Timing rules from the 50 MHz campaign:
   registered pin outputs and an input flop on every pin; a registered `interrupt_req`; each
   register or pointer written by exactly one rule (FIFO pointers as `ConfigReg`, so readers
   need no ordering); keep decode logic out of anything the CPU pipeline reads combinationally.
   Separate clock domains (TMDS, USB) live in one module with bsc `SyncFIFO`/`SyncBit` crossings.
3. **Unit-test in Bluesim before integration**: `test/Tb_<ip>.bsv` with a behavioral device model
   (SD card, flash, I2C target, USB host traffic, a TMDS decoder that checks a frame), driving
   the registers in the driver's order. Example: `test/Tb_AXI4_SPI.bsv` (driver sequence, mode-0
   device with output delay, mode 3, TX-only, CS polarity, interrupt). Add it to CI.
4. **Integrate**: `SoC_Map.bsv` (base, size, slave or bridge slot, IRQ, `fn_soc_memmap`, MEMMAP
   messages), `SoC_Top.bsv`, `src/ULX3S_Top.bsv`, `src/Top.v`, the LPF. Then **every harness that
   instantiates the top** (`sim/*/tb_board.v`, `board_pins_if.sv`, `test/ULX3S_Sim.bsv`) gets the
   new pins, tied off or connected to a model, before any sim is rebuilt.
5. **Full-system models**: a Verilog model for the strict Verilator bench (e.g. SD card serving
   a disk image) and a BSV/BDPI model for the virtual board (`make sim-board`: SD backed by an
   image file, framebuffer dumped to PNG or served over VNC, keyboard from the control pty), so
   students and CI exercise the device without the board.
6. **Software, smallest first**: a bare-metal test in `test/` (loaded by the boot ROM loader),
   then Linux (DT node in `flute-linux-sw/dts-fp`, kernel options in `kernel/flute-fp.config`,
   a check in `init-fp`), then the TempleOS driver.
7. **Gates** (AGENTS.md): build and route seeds 3/5/7 (one >= 55 MHz, all >= 50); the regression
   set (Linux sim tick 2, ISA 94/94 with `UART_CPB=80 SDRAM_TCK_PS=20000`, strict + J1, Bluesim
   gate); then the board (TempleOS suite 70/0/2, Linux boot, the new device); restore the custody
   bitstream; push, and fast-forward `linux-isa` after the full gate.

## Status log

- 2026-11-03: `src/AXI4_SPI.bsv` (SiFive SPI register subset, 1 CS, 8-deep FIFOs, modes 0-3,
  LSB-first, TX-only, HOLD/AUTO/OFF CS, watermark interrupts) written; `test/Tb_AXI4_SPI.bsv`
  passes. Next: SoC integration as fabric slave 5 at `0xC000_4000`, IRQ 2 (PLIC source 3), pins
  `sd_clk` H2, `sd_cmd` J1 (MOSI), `sd_d[0]` J3 (MISO), `sd_d[3]` K2 (CS).
