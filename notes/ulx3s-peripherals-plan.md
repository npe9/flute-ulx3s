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
| SPI ADC, 8 channels (MAX11125, confirmed on the board 2026-11-09; the LPF comment says MAX11123) | `adc_*` | phase 3: second SPI instance |
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
`0xC000_5000` (free; the flash is chip select 1 of spi0), `0xC000_6000` i2c0, `0xC000_7000` uart1 (ESP32), `0xC000_8000`
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

The full profile list (14 SoCs, PMODs, multiboot) is now `soc-family-plan.md`; this section keeps the
game2d/game3d detail.

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
- 2026-11-04: **1b flash boot done (lx38).** A second AXI SPI slave (spi1 at `0xC000_5000`) cost
  +1.4K LUT4 / +1.2K FF, mostly the 64-bit AXI transactor FIFOs, and routed at
  52.39 / 52.11 / 49.71 MHz. Fix: the flash is chip select 1 of spi0 (own CS and MISO pins, SCK
  and MOSI shared; CSDEF has 2 bits so spi-sifive probes `cs=2`; CS 1 ignores CSDEF and is
  always active low). +292 LUT4 over lx35 (45382 LUT4, 26502 FF); lx38 routes at
  54.15 / 55.15 / 55.35 MHz. Flash pins R2/W2/V2 (+ W1/Y2
  held high), clock through `USRMCLK`, `MASTER_SPI_PORT=DISABLE`. Boot ROM: silent probe before
  the banner (reset, release power-down, JEDEC id and directory magic to the DMI forensic slot),
  directory at flash `0x400000` (`scripts/mkflashimg.py`), countdown, Fletcher sum, jump.
  Sim: `sim/common/spi_flash_model.v`, hello from flash at cycle 161.7K; CI Linux job boots it
  and checks the bad-sum fallback. **Board:** TempleOS and Linux autoboot from flash with
  nothing sent on the UART; Linux sees `cs=2` and still reads the SD card. The load runs at
  ~0.58 MB/s at both sckdiv 3 and 1, so the ROM's uncached per-byte loop is the limit
  (~86 cycles/byte); a burst or DMA read path would help. The lesson for the next peripherals
  stands: a full AXI4 slave per small device is too expensive; use the register-bus bridge.

- 2026-11-06: **lx39 = G1 HDMI framebuffer.** `src/Video_DVI.v` (320x240 RGB565 / palette
  modes, 150 KB pixel RAM in five 8 K-word EBR banks, registered on both ports) behind the
  register-bus bridge `src/AXI4_RegBus.bsv` (control 0xC001_0000, pixel RAM 0xC100_0000).
  `constraints/video_floorplan.py` (`--pre-place`) keeps the BTB in EBR row 22 next to fetch and
  puts the framebuffer in rows 70/82. Fixes found on the way: SFENCE.VMA had no urgency against
  debug halt / ndmreset, so bsc folded its decode into every stage1 enable; the ndmreset settle
  (now 64 cycles) was shorter than an I$ refill, which could hang the next fetch (lx38 passed by
  timing luck); fabric bus-error events are staged in per-master toggle registers and merged by
  one rule. Timing is density-bound at 71-72% LUT: 50.11 / 51.34 / 52.77 MHz (s3/s5/s7); the
  user accepted "all seeds >= 50" for this build (55 was margin, PLL stays at 50 MHz).
  Bit: s7, md5 8ac819cb. Sims: ISA 94/94, strict cache/amo/sd/fb_test (PPM byte-identical),
  J1, ndm x6, Linux tick 2 at 229,890,414, Bluesim gate. Board: suite 72/0/2 (bus-error
  monitor catches the unmapped DMI read), fb_test, FP Linux 6 min clean. `hw_test_suite.py`
  and `loader.py --skip-repair` now keep the bytes read after the last ACK: at 50 MHz the
  readback line arrives in that read, and the skip bytes were going to the booted REPL.

## Board audit, 2026-11-09

Pins checked against the official `emard/ulx3s` `doc/constraints/ulx3s_v20.lpf`.

| Part | State | Next |
|---|---|---|
| Buttons, switches, RTC, HDMI DDC | `src/Board_IO.v`: IP proved, 8/8 mutants; strict sim passes; lx41 gates running; **not yet run on the board** | board test of `io_test`; Linux `i2c-ocores` and RTC device tree |
| Audio jack L/R | `src/Audio.v`: IP proved, 7/7 mutants; **not on the SoC yet** | integrate after lx41 at `0xC000_9000`; needs someone listening; volume resets to mute |
| 8-channel ADC | lx43 (gating): `spi2`, a second `AXI4_SPI` at `0xC000_A000`, IRQ 3; `test/adc_test` against an echo stand-in; `test/adc_probe.bin` prints the chip's raw replies | work out the protocol on the board; Linux: `spidev`, or a driver if one exists (no kernel tree here to check) |
| USB host (US2) | none | largest remaining item: low-speed HID host |
| ESP32 UART | none | `uart1`; shares SD pins, so needs care with `wifi_en` |
| OLED header | none | SPI instance at `0xC000_B000` |
| 28 header pairs, 433 MHz, CEC | none | later |
| Power-off, multiboot | none | with the SoC profiles |

Verified pins not yet in `constraints/ulx3s_85f.lpf`:

- `audio_l[3:0]` B3 C3 D3 E4, `audio_r[3:0]` C5 D5 B5 A3, `audio_v[3:0]` E5 F5 F2 H5, each listed
  [3] to [0]; `PULLMODE=NONE DRIVE=16`
- `adc_csn` R17 (`PULLMODE=UP`), `adc_mosi` R16, `adc_miso` U16, `adc_sclk` P17
- `oled_clk` P4, `oled_mosi` P3, `oled_dc` P1, `oled_resn` P2, `oled_csn` N2
- `wifi_rxd` K3, `wifi_txd` K4, `wifi_gpio0` L2, `wifi_gpio5` N4, `wifi_gpio16` L1, `wifi_gpio17` N3
- `ant_433mhz` G1, `gpdi_cec` A18, `user_programn` M4
- `usb_fpga_dp` E16, `usb_fpga_dn` F16, `usb_fpga_bd_dp` D15, `usb_fpga_bd_dn` E15,
  `usb_fpga_pu_dp` B12, `usb_fpga_pu_dn` C12
- `shutdown` G16 (`PULLMODE=DOWN`): do not drive it high by accident

### ADC: what is and is not known

- **Datasheet not read.** Analog Devices' PDF timed out from here, and the mirrors gave only page 1.
  Page 1 of Rev 1, 4/12 gives the family as 12/10/8-bit, 4/8/16-channel, 1 Msps, 16 MHz 3-wire SPI;
  it does not map part numbers to those figures.
- **The part is a MAX11125** (the user read the board, 2026-11-09); the official LPF's comment saying
  MAX11123 is wrong for this board.
- The analog inputs share `gp/gn[14..17]` (AIN0 = gn14, AIN1 = gp14, ... AIN7 = gp17), so those
  header pairs must stay high-impedance in a build that uses the ADC. Input range and any series
  resistors are not confirmed.
- Register words in `emard/ulx3s-misc` `examples/adc/max1112x/hdl/max1112x_init_pack.vhd` (labelled
  work in progress) are a lead for software, not a specification.
- **Design consequence:** use the proved `AXI4_SPI` as a generic host and keep the chip's protocol in
  software. Only the SPI mode and SCLK limit then come from the chip, and SCKMODE and SCKDIV are
  software-settable. Do not write a hardware scanner against unread register definitions.

### lx43 on the board (2026-11-11, seed 5: sys_clk 56.36 MHz, `build/lx43/ulx3s_top.bit` 0ddd9815)

- **ADC link: up; data not decoded.** `test/adc_probe.bin` (emard's init words): with echo on
  (0x8404) the MODE_CONTROL word 0x4006 comes back exactly on the next frame, so SPI mode 0, SCLK
  and CS framing work. Every conversion frame then reads `0x3ffc`, and so did frames before any
  configuration in a second run, so the reply format (channel id in [15:12]?) is not established.
  Needs the datasheet's register map before an IIO driver.
- **hw suite 73 PASS / 1 FAIL / 2 WARN** (`EXPECT_HZ=50000000 EXPECT_MISA=4014112f`). The FAIL is
  real: the devROM record for spi2 reported IRQ 2, because `SoC_Map.bsv` listed it with
  `irq_num_spi0` (copy-paste). The PLIC wiring in `SoC_Top.bsv` was already `irq_num_spi2`.
  Fixed in source for lx44; the lx43 bitstream keeps the wrong table entry.
- **SoC Info TIMER_HZ was wrong on every SYS_CLK_HZ build:** it repeated CPU_HZ (50 MHz), but
  `Near_Mem_IO_AXI4` ticks mtime at a fixed 25 MHz (measured on the board: about 49.3M ticks in
  about 1.96 s). Fixed in `src/SoC_Info.bsv` for lx44, with a hw-suite check. Linux was unaffected
  (DT timebase 25 MHz).

### TempleOS (HolyC REPL) board drivers: `templeos/ulx3s_repl/ulx3s_drv.hc`

Included from `jit.hc`, registered in `JitInit`; `PowerOff` (ulx3s_trap.hc) now drives the
shutdown pin first. Nothing touches a device at boot: each call finds its base in the live SoC
Info device table (ids 9 i2c0, 10 gpio1, 11 audio), so the same blob still boots on the 25 MHz
main SoC and in Bluesim. `BoardHelp;` lists: RtcShow, RtcSet (24 h; battery backup and oscillator
on, per the datasheet's stop-ST/wait-OSCRUN sequence; weekday 1 = Sunday, as Linux's rtc-ds1307),
RtcAlarmIn/RtcAlarmOff, I2cRd/I2cWr, Btns, Sws, BtnWait, Snd(ona) (TempleOS Ona2Freq, 60 = A440),
SndHz, SndVol (default 2 of 8: it drives headphones), Beep, Sleep, BrdRd/BrdWr, PowerOff,
PowerOffFor(s), Reconf. Notes: `reg` is a HolyC keyword (not a parameter name); the REPL evaluator
takes no casts (`*(U32 *)a` fails), hence BrdRd; rdtime is not used (mtime over the bus).

Board bench `scripts/hw_board_drv.py` (never calls PowerOff/Reconf; tone checked at volume 0):
10/0 on lx43, the RTC set to UTC (`--set-rtc`). Full hw suite with the driver blob
(`HW_BLOB=templeos/build-drv/repl.blob.bin`): 73/1/2, the same as the old blob.

### lx44 (2026-11-12, seed 7: sys_clk 52.95 MHz, `build/lx44/ulx3s_top.bit` 247fd603)

uart1 (ESP32 UART0, 115200) at 0xC000_7000 IRQ 4, ESP32 EN (gpio1 0x0C), POWER (0x10, "POFF")
to `shutdown` G16, RECONF (0x14, "RECF") to `user_programn` M4, RTC alarm 0 in the sim model,
the spi2 device-table IRQ and TIMER_HZ fixes. Board_IO formal: prove PASS, 13/13 mutants.
Gate: ISA 94/94; strict cache amo sd fb io audio adc rtc esp32 PASS; PPM identical; J1 PASS;
Linux F1 strict PASS (out-fp rebuilt: uart1, i2c-ocores + rtc-ds1307, gpio-keys-polled,
syscon-poweroff, the flute-audio ALSA driver); ci/bluesim_gate.sh PASS.

Board: hw suite 76/0/2; hw_board_drv 10/0; rtc_test ok (alarm fired, VBATEN on). Linux:
rtc-ds1307 set the system clock from the RTC, `keys` input0, ALSA card 0 "ULX3S Flute audio",
ttyS1, ran 6 min.

**Power-off, tested 2026-11-12 (user asked), board powered from US1:** TempleOS
`PowerOffFor(20)` wrote POFF (gpio1 0x10 reads back 1, the shutdown pin driven) and the board
stayed on, as expected while the FT231X holds it on through D18; the alarm fired (0x0D ALM0IF
set, ALMPOL 0). Linux: init now takes console commands, `poweroff` (sysfs wakealarm "+20", then
syscon-poweroff: "reboot: Power down", then "Unable to poweroff system" because US1 holds the
power) and `reboot` (syscon-reboot = RECONF, not run: it reloads the user's flash bitstream). The
RTC node needs `wakeup-source` (no IRQ), or rtc-ds1307 drops the alarm feature; its
mcp794xx_set_alarm keeps ALMPOL 0 and matches the full date, and its alarm fired too. A real
power cut needs the board powered from US2 or the battery connector (the user's test).

**lx44 PROMOTED 2026-11-12** (user: "promote the one you recommend"): `build/ulx3s_top.bit` =
lx44 247fd603, lx40 kept as `build/ulx3s_top.lx40.bit`. CI run 43171873099 all green.

**ESP32: no reply.** esp32_probe released EN with GPIO0 low and got 0 bytes: no ROM banner, no
SYNC reply. Likely cause, not confirmed: the strap pins share the SD lines. GPIO2 = `sd_d0`
(J3) is an FPGA input with PULLMODE=UP, so the strap reads GPIO0=0/GPIO2=1, which is not download
mode; GPIO15 = `sd_cmd` (MOSI) idling low silences the ROM's boot log. Fix to try in lx45: drive
`sd_d0` low (and `sd_cmd` high) while EN is held and for a few ms after release, only while the SD
CS is high (the card's DO is then high-impedance). GPIO12 = `sd_d2` must stay low (flash voltage).

### lx45 (in progress, 2026-11-12)

- **JTAG over US1 (JTAGG).** `src/JtaggDtm.bsv`: the debug-spec 0.13 DTM behind the configuration
  TAP's ER1 (IR 0x32, dmi, abits 7) and ER2 (IR 0x38, dtmcs), sampled with sys_clk (no TCK clock
  domain); ULX3S_Top merges it with the UART bridge in front of the debug module (tag FIFO). The J1
  soft TAP is gone (it never reached the debug module, and yosys never even got the JTAG_TAP define,
  so Top.v's TAP block had not been synthesized for a long time: the "placement parity" was moot).
  In Verilator, Top.v keeps the jtag_* ports and drives `src/ecp5_jtag_model.v` instead of JTAGG.
  Unit bench `sim/jtagg/run.sh`: IDCODE, dtmcs, dmi write/read, busy sticky + dmireset, PASS.
  Host side: OpenOCD 0.12's ft232r driver reads all ones on the FT231X (every pin permutation tried;
  openFPGALoader's map TCK=DSR TMS=DCD TDI=RI TDO=CTS is right), so `scripts/ft231x_jtag.py` drives
  it through libftdi (sync bitbang) and serves `remote_bitbang`; `openocd/ulx3s_jtagg.ocd`. Checked
  on lx44: OpenOCD reads IDCODE 0x41113043 through it.
  Board (lx45, lx45b, lx45c): dtmcs reads 0x1071 and dmi reads come back right, but every 41-bit
  dmi write landed one bit up (0x10 -> 0x20; reads turned into writes or no-ops). Two wrong
  guesses first: lx45 shifted on JCE, lx45b on JSHIFT, lx45c added a "last edge hidden" repair
  (count shifts, take the missing bit afterwards); none helped. What fits every session
  (`build/jtagmodel/model.py` replays them against each candidate): **JTDI is TDI registered on
  TCK's rising edge**, so the sample just before an edge holds the previous bit. Evidence: 42-bit
  scans with the value in the low 41 bits work; reads and dtmcs are right (the controls are on
  time); moving TDI before TCK's falling edge (`ft231x_jtag.py --tdi-early`) changes nothing.
  With 42-bit scans on lx45c the whole debug path works: haltreq -> allhalted (dmstatus 0x382),
  abstract reads of ra/sp/misa (0x4014112f)/mstatus/dpc, an a0 write and readback, resumereq ->
  allresumeack (`build/lx45c/dbg42.ocd`). lx45d takes JTDI one system clock after JTCK is first
  seen high (controls still from the sample before). The sim model's JTDI is registered by
  default (`ECP5_JTAG_TDI_COMB` for the plain wire); the lx45c DTM fails it with the board's
  signature, the lx45d DTM passes both. **lx45d board: stock OpenOCD works** (examine: misa
  0x4014112f, datacount 4, progbufsize 0; halt at pc 0x1238 in the boot loader, reg sp/ra/mstatus,
  mdw 0x80000000, mww/mdw 0x80fff000 = 0xcafef00d, resume).
- **ESP32.** The user confirms the module is fitted. With GPIO15 (sd_cmd) left high first, the ROM
  still printed nothing, so the strap theory is out (the ROM prints its rst/boot line in every
  mode). lx45: `wifi_txd` pulled down, gpio1 0x0C bit 1 = its level (1 = driven, as a running ESP32
  does), uart1 RX held idle while EN is low. Board_IO formal: prove PASS, 14/14 mutants (new: etxsync).
  lx45c: STRAP (gpio1 0x0C bit 2) drives GPIO2 (sd_d0) low while the SD card is deselected, so EN
  rising with GPIO0 low selects the ROM's download mode. Board: the ROM answers esptool's SYNC
  (`c0 01 08 04 00 07 12 55 55 00 00 00 00 c0`, five replies) and prints nothing first (GPIO15 low
  silences it). Board_IO formal: prove PASS, 16/16 mutants (new: strapreset, strapbit).
  esptool through the board (`test/esp32_bridge.c` + `scripts/esp32_bridge.py`, lx45c and later):
  chip_id ESP32-D0WDQ6 rev 1.0, 40 MHz crystal, MAC a4:cf:12:17:1b:60; flash_id 0x20/0x4016, 4 MB,
  3.3 V. Long reads failed their MD5; traced (SoC-side capture vs host log: the SoC got 00, the
  host 80) to the console link, not the ESP32 link: **on macOS the FT231X runs at 600015 baud when
  asked for 625000** (measured: host sends 0x55s, the board times 256-byte windows), so it samples
  the FPGA's 625000 bits late and reads a 0 last data bit as 1, about 6% of back-to-back 0x00
  bytes, 0% of 0x00 between 0xFF. Same on the promoted lx44 (old, not an lx45 regression). Host ->
  board is clean (the FPGA receiver tolerates 4%). Pin DRIVE 16 and SLEWRATE FAST (config edits)
  change nothing. Workaround: `esp32_bridge.py --read-flash` (digest-checked reads from 16 KB,
  halved on each failure down to 512 B, then the stub's whole-range MD5). Full 4 MB backup
  2026-11-12 on lx45d: 528 s, 332 retries, md5 fd656393ff7018eeceb71143a761922b matches the
  ESP32's (build/esp32-flash-backup-20261112.bin, not in git); fixed 16 KB reads gave up at 0x8000. Real fix (user's call; touches the loader, dmi.py, sims, CI): a
  console rate every FT231X driver makes exactly, 600000 (3 MHz / 5; 50 MHz / 83.3) or 1000000
  (3 MHz / 3; 50 MHz / 50 exactly).
  The ESP32 ROM's own replies come at ~111 kbaud (auto-baud), the stub's at 115208.
  Drivers (board, lx45d): TempleOS `Esp32Download();` 1 (TX driven), `Esp32Sync();` 1 (answered
  on try 2), `Esp32Off();` (hw_board_drv.py 14/14); Linux DT node `esp32_gpio` (wd,mbl-gpio:
  ESP32_EN / ESP32_TXD / ESP32_GPIO2_LOW) and init's `esp32` command over /dev/ttyS1: "esp32 ok".
- **Linux beep.** flute-audio registers an EV_SND input device ("ULX3S Flute beep", SND_TONE /
  SND_BELL); CTRL is a shadowed read-modify-write so PCM and tone no longer clear each other. init's
  `beep` command: board (lx44) TONE 56817, CTRL 2 at 440 Hz, off CTRL 0, volume 0 (silent): "beep ok".
- **RECONF on the board (user OK'd):** TempleOS `Reconf()` reloaded flash offset 0, which is the
  ULX3S factory self-test (115200 baud: RTC, EDID, ADC, DAC loopback, buttons, flash, OLED, SD).
- **ADC, working (datasheet from the user, max11120-max11128.pdf).** DIN is sampled on the rising
  SCLK edge and DOUT changes on the falling edge: SPI mode 3. In mode 0 the host sampled before the
  first falling edge, so every word read one bit late (0x07ff = the self-test's 0x0fff >> 1), and
  the earlier probes also resent the mode word every frame, which restarts the scan (0x0000
  continues it). Mode control: [15] 0, SCAN [14:11] (0001 Manual, 0100 Standard_Ext, 1000
  Custom_Ext), CHSEL [10:7], RESET [6:5], PM [4:3], CHAN_ID [2], SWCNV [1]; config registers are
  [15:11] = 10000 config, 10001 unipolar, 10010 bipolar, 10011 range, 10100/10101 custom scan.
  Board (lx45b, test/adc_test.c -DSEQ3): Standard_Ext steps channels 0..7; Manual answers the named
  channel in the next frame; the header inputs read near 0.
  Linux: `kernel/drivers/max1112x.c` (IIO, manual mode, SPI mode 3, vref-mv 3300), DTS adc@0 on
  spi2; init `adc` printed `adc: 3 1 0 0 2 3 3 5` on the board. TempleOS: `AdcRd(ch)`, `AdcShow()`
  (ulx3s_drv.hc); board AdcShow lists ain0-7, AdcRd(9) is refused. hw_board_drv checks AdcRd(0/7).