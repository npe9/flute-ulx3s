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

## Phase 5: an SoC family; the game machines are separate SoCs

One Flute core and one IP library, with several SoC builds (`SOC=` profile in the Makefile), each
optimized for its job:

| SoC | Optimized for | Keeps | Adds |
|---|---|---|---|
| `templeos` | TempleOS (M-mode, flat memory) | full ISA, FPU, caches | HDMI framebuffer console, PS/2/USB keyboard, SD |
| `linux` | Linux (today's linux-isa build) | full ISA, FPU, S-mode + Sv32 MMU, PLIC | SD (done), SPI-flash boot, framebuffer for fbdev |
| `game2d` | best 2D console we can build | full ISA, FPU; **runs TempleOS** | VDP-2D (tiles/sprites/affine), APU, pads, SD |
| `game3d` | best 3D console we can build | full ISA, FPU; **runs TempleOS** | geometry unit, rasterizer + texture cache, APU, pads, SD |

Common rules: the ISA (RV32IMAFDC + B/Zk) never changes between profiles. Profiles differ only in
SoC IP and in privilege/MMU features a profile doesn't need. TempleOS runs on every profile;
the game SoCs boot it from SD like any other title. Each profile must meet the same closure
bar (all seeds ≥50 MHz, one ≥55). Shared low-speed devices sit behind the peripheral bridge, so
adding per-profile IP never widens the main fabric.

### Budget available to a game SoC

Measured on lx33 (Flute + FPU + SPI at 50 MHz): 57.4K / 83.6K logic, 16 / 208 BRAM, 7 / 156
multipliers. A game SoC doesn't need the Linux-only parts, and those return to the video
engine. So **each game SoC gets the whole ~18K usable logic (26K free minus 10% closure
slack), ~190 BRAM (~380 KB) and ~145 multipliers for its own engine**. It does not share that
budget between 2D and 3D, which is the point of splitting them.
Shared limits: SDRAM (32 MB, 16-bit, ~100 MB/s at 50 MHz, ~200-266 MB/s once G0 moves it to its
own clock), HDMI via GPDI, a 4-bit-per-channel audio DAC on the jack, 7 buttons, US2 USB,
ESP32 (Bluetooth pads).

### `game2d`: the 2D showcase (yardstick: SNES, and past it)

| | SNES (yardstick) | `game2d` target |
|---|---|---|
| CPU | 65816 at 3.58 MHz | Flute RV32GC at 50 MHz, roughly 10-20x the throughput, plus FP |
| Resolution | 256x224 | 320x240 native (2x to 640x480 HDMI); 640x480 bitmap mode |
| Colour | 15-bit, 256 on screen | 15/16-bit, multiple 256-entry palettes + direct colour |
| Layers | up to 4 tile BGs | 4-6 tile layers, per-line scroll, line IRQ |
| Sprites | 128, 32 per line | 256+, 64+ per line via BRAM line buffers |
| Affine | one "mode 7" layer | 1-2 affine layers + scaled/rotated sprites (DSP multipliers) |
| Blending | add/sub colour math | alpha + add/sub per layer/sprite |
| VRAM | 64 KB | ~256 KB BRAM pattern/map RAM + SDRAM DMA |
| Audio | 8-voice ADPCM, 32 kHz | 16-24 voice ADPCM/PCM, 48 kHz, HDMI audio + jack |
| Input | pads | 7 buttons, USB HID pads, Bluetooth pads via ESP32 |

Verdict: **comfortably beyond SNES class.** Logic: VDP ~8-12K, APU ~3K, input ~2K, all within budget.

### `game3d`: the 3D showcase (yardsticks: PS1 reachable, N64 not)

| | PS1 (yardstick) | N64 (yardstick) | `game3d` target |
|---|---|---|---|
| CPU | R3000A at 33.8 MHz | VR4300 at 93.75 MHz, 64-bit | Flute at 50 MHz, PS1-class integer + FP |
| Geometry | GTE fixed-point coprocessor | RSP vector unit | GTE-style unit as custom instructions (transform, project, light, clip) on DSPs |
| Raster | affine textured + gouraud, no Z | perspective-correct, bilinear, Z, AA | affine textured + gouraud, ordering tables; per-span perspective correction as a stretch |
| Resolution | 320x240 (up to 640x480) | 320x240 | 320x240, back buffer in BRAM (1 px/clk), 2x scan to HDMI |
| Texture memory | 1 MB VRAM | 4 KB TMEM + RDRAM | ~128 KB BRAM texture cache in front of SDRAM |
| Memory BW | ~130 MB/s VRAM + main | ~500 MB/s | ~200-266 MB/s SDRAM (after G0) + BRAM |
| Throughput | ~90K textured tris/s in practice | ~100K+ | target 20-50K textured tris/s at 30-60 fps |

Verdict: **PS1 class at 320x240, a bit below its peak triangle rate.** The CPU and geometry
unit are not the limit; SDRAM fill rate is. That's why the frame and texture working set live
in BRAM. **N64 class is out of reach:** ~2x short on CPU, ~5x on memory bandwidth, and its
per-pixel Z + perspective + bilinear pipeline would exceed the logic budget. A small
Z-buffered perspective-correct mode at 160x120 is a stretch demo, not a target.

### Shared work packages (each follows the IP recipe: model → BSV + unit Tb → SoC → sim → board)

| # | IP | Used by | Size estimate | Proof |
|---|---|---|---|---|
| B0 | Peripheral bridge (1xN sub-fabric for low-speed slaves) | all | <1K LUT | gates unchanged; fabric off the critical path |
| G0 | SDRAM on its own 100+ MHz clock + burst DMA port | all | 1-2K LUT | gates unchanged; memcpy bandwidth 2x |
| G1 | HDMI scanout: 320x240 → 640x480, palette, framebuffer | all | 2-3K LUT, 2-4 BRAM | test pattern; Linux fbdev; TempleOS console |
| G2 | VDP-2D: tile layers, sprite line buffers, affine, blending, line IRQ | game2d | 8-12K LUT, ~100 BRAM, 4-8 DSP | demo scene; frame-exact Verilator image compare |
| G3 | APU: voice mixer + ADPCM + HDMI audio / sigma-delta jack | game2d, game3d | ~3K LUT, 8-16 BRAM, ~16 DSP | sample tests; captured-audio diff |
| G4 | Input: USB HID host on US2; ESP32 Bluetooth pad bridge | game2d, game3d, templeos | 2-3K LUT | pad register + Linux evdev |
| G5 | Geometry unit (custom insns) | game3d | 2-4K LUT, ~20 DSP | ISA-style tests vs a C reference |
| G6 | Rasterizer: setup, edge walk, gouraud, affine texture, blending, BRAM tex cache | game3d | 8-12K LUT, ~140 BRAM, ~12 DSP | spinning textured mesh; pixel-exact vs a C rasterizer |
| G7 | SDK: C bare-metal libs, asset tools, SD boot menu (FAT), TempleOS bindings for VDP/APU | game2d, game3d | — | an original 2D game and an original 3D demo |

Order: B0 → G0 → G1 (shared by everything, and it unlocks the TempleOS/Linux framebuffer) →
G3/G4 → `game2d` (G2) → `game3d` (G5, G6).

## Status log

- 2026-11-03: `src/AXI4_SPI.bsv` (SiFive SPI register subset, 1 CS, 8-deep FIFOs, modes 0-3,
  LSB-first, TX-only, HOLD/AUTO/OFF CS, watermark interrupts) written; `test/Tb_AXI4_SPI.bsv`
  passes. Next: SoC integration as fabric slave 5 at `0xC000_4000`, IRQ 2 (PLIC source 3), pins
  `sd_clk` H2, `sd_cmd` J1 (MOSI), `sd_d[0]` J3 (MISO), `sd_d[3]` K2 (CS).
- 2026-11-03: integrated (`-D INCLUDE_SPI0`): fabric slave 5 at `0xC000_4000`, PLIC source 3,
  +1.8K LUT4 / +1.2K FF (lx33: 44715 LUT4, 25436 FF). `sim/common/sd_spi_model.v` (SDHC in SPI
  mode, CRC16 data, `+sd_image=` / `+sd_none`) is wired into the strict and Linux harnesses;
  `test/sd_test.c` (`sd_test.bin` read-only, `sd_test_w.bin` adds CMD24/CMD25) passes in the
  strict sim (T at 63.5M, D at 64.9M cycles). Linux: `sifive,spi0` + `mmc-spi-slot` in
  `dts-fp`, SPI/MMC options in `flute-fp.config`, `/init` reads block 0 of `/dev/mmcblk0`.
  CI: `make sim-spi-tb` in the Bluesim gate, `sd` in the strict matrix.
- 2026-11-03: Linux sim showed mmc0 error -110: HOLD ended on any CSID/CSDEF/CSMODE write, but
  spi-sifive rewrites them per message and mmc_spi keeps CS across command/data messages. Fixed
  to FE310 semantics (a *different* value releases HOLD). Linux sim: "mmc0: new SDHC card on
  SPI", "sd: sig 000055aa".
- 2026-11-03: **B0 peripheral bridge done.** The main fabric is down to 4 slaves (boot ROM,
  SDRAM, bridge, accel0); uart0, soc_info and spi0 sit behind a 1x3 sub-fabric
  (`mkPeriph_Fabric_AXI4`). Its write-data dispatch star had limited lx29 s3, lx32 s7 and lx33
  s3/s5. lx35 routes at 54.48 / 55.76 / 55.25 MHz (lx33: 51.33 / 53.71 / 54.17); the remaining
  limiters are core paths (icache S2 page-match on `rg_s2_ppn`, stage1). Each uncached access
  through the bridge costs ~4 cycles more, so the boot ROM's 2M-poll repair window is ~68M cycles
  (was ~60M); the sim deadlines were raised to match.
- 2026-11-03: **board:** lx35 TempleOS suite 71/0/2 at 50 MHz. Linux reads a real 7.5 GiB SDHC
  card (`mmcblk0: mmc0:0000 asdfg 7.50 GiB`, CRC16 on). Bare-metal `sd_test.bin` PASS on
  hardware at 8.3 MHz SCK. That needs CMD59 (CRC on): this card leaves CSD CRC7 / data CRC16
  empty with CRC off. The sim model always sends valid CRCs, so it can't catch that difference.
