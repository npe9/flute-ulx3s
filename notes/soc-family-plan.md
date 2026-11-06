# The Flute SoC family for the ULX3S

One Flute core (RV32IMAFDC + B/Zk, never varied: see the ISA rule in AGENTS.md), one IP library,
and a set of SoC profiles. Each profile is built for something the ULX3S can do, on-board or
with a PMOD. This file supersedes the four-profile table in `ulx3s-peripherals-plan.md` Phase 5.
The game2d/game3d detail (SNES/PS1 yardsticks, budgets) stays there.

Part numbers and pinouts marked (check) must be confirmed against the board schematic or the
PMOD's datasheet before any RTL is written.

## Ground rules

- **ISA fixed.** Profiles differ only in SoC IP and in privilege/MMU features they don't use
  (TempleOS and the game machines run in M-mode, so S-mode + Sv32 + PLIC are optional for them).
- **Same closure bar for every profile.** All seeds ≥ 50 MHz, from architecture, not seed sweeps.
  lx39 is density-bound at 71-72% LUT, so a profile gets the area it frees by leaving IP out,
  and no more.
- **Software sees one memory map per profile, generated.** `MEMMAP` lines from elaboration →
  `soc-memory-map.json` → DTS, TempleOS `ulx3s_memmap.hc`, C headers. A device keeps its address
  in every profile that has it; absent devices DECERR (the bus-error monitor reports them).
- **Every profile runs TempleOS.** Linux runs on every profile that keeps S-mode.
- **Each profile has a CI job** (build + strict sim of its own devices) and a board-suite variant.
- **Every IP follows the recipe** in `ulx3s-peripherals-plan.md`: contract → BSV/Verilog + unit
  bench → formal harness (register-bus contract + data integrity, as `formal/video/`) → SoC → sim
  model → board.

## Mechanism (work package P0, before any new profile)

1. `SOC=<profile>` in the Makefile selects `profiles/<profile>.mk`: DEFINES, the pin set (LPF
   fragment), floorplan options, the PLL plan. `SOC=linux` is today's build, bit-identical.
2. Build directory per profile (`build/<profile>/`), bitstream named `<profile>.bit`.
3. One `board_pins` superset in the sim harnesses, with tie-offs for absent devices, so every
   sim bench builds for every profile.
4. **Multiboot.** The flash is 16 MB and a compressed bitstream is 1.47 MB. Layout (check
   against D1):

   | Flash range | Contents |
   |---|---|
   | 0x000000 | golden image: `launcher` profile (or the original bitstream, per D1) |
   | 0x200000-0x3FFFFF | slot A bitstream |
   | 0x400000 | payload directory (today's, `mkflashimg.py`) |
   | 0x400000-0x9FFFFF | payloads: OpenSBI+Linux, TempleOS blobs, game data |
   | 0xA00000-0xFFFFFF | slots B, C, D bitstreams (2 MB each) |

   A small register (`power/multiboot` at `0xC000_C000`) writes the next-boot address and pulses
   `user_programn`. `ecppack --bootaddr` sets the jump table. The boot ROM's countdown menu gains
   "boot SoC B/C/D". Recovery: JTAG always works; the golden image never gets overwritten by
   the menu.

## Profiles

### Core profiles (the computers)

| Profile | What it is | Devices beyond the core | Status |
|---|---|---|---|
| `linux` | headless + console Linux | SDRAM, UART, SD, flash boot, 320x240 fbcon (G1), PLIC, CLINT | **exists (lx39)** |
| `templeos` | TempleOS workstation, **full graphics** | 640x480 16-colour framebuffer (mode 1, exists), USB keyboard + mouse, PC-speaker tones and PCM on the jack, SD (RedSea), RTC | new; area freed by dropping S-mode/Sv32/PLIC |
| `linux-desktop` | Linux with a real desktop-ish display | 640x480 RGB565 scanout from SDRAM (needs G0), USB HID keyboard/mouse, audio (ALSA), RTC, ESP32 Wi-Fi | new |
| `launcher` | the golden image at flash 0 | UART, SD, flash, framebuffer menu, buttons, multiboot register | new, small; also the CI timing reference |

### Showcase profiles (each gets the area the computers spend elsewhere)

| Profile | What it is | Devices | Yardstick |
|---|---|---|---|
| `game2d` | 2D console | VDP-2D (tiles, sprites, affine, blending), APU, pads (buttons, USB, SNES/NES/DB9 PMOD), HDMI audio | beyond SNES (Phase 5) |
| `game3d` | 3D console | geometry custom insns, rasterizer + BRAM texture cache, APU, pads | PS1 class at 320x240 (Phase 5) |
| `handheld` | game2d on the OLED/LCD header, no HDMI | ST7789 240x240 SPI LCD or SSD1331 96x64 OLED scanout DMA, 7 buttons, jack audio | a Game Boy-class portable |
| `synth` | music workstation | APU as a synth (oscillators, wavetable, FIR/reverb on DSPs), I2S codec PMOD, MIDI in/out (UART on a header pin), 8-ch ADC for knobs/CV, OLED UI | a hardware polysynth / tracker |
| `lab` | bench instrument | logic analyzer on the header pairs (BRAM capture at 100+ MHz, SUMP protocol for sigrok/PulseView), 8-ch ADC scope, signal generator on the jack DAC, PWM/servo out, HDMI scope display | a pocket logic analyzer + scope |
| `net` | network appliance | Ethernet (RMII PHY PMOD, LiteEth-compatible MAC) and/or ESP32 Wi-Fi, RTC, SD; Linux web/SSH/NTP | a small Linux server |
| `vision` | camera + display | OV7670/OV2640 parallel camera on the headers, frame grabber into BRAM/SDRAM, DSP filters (Sobel, threshold), HDMI preview | a camera with live image processing |
| `radio` | RF toys (check local radio rules) | 433 MHz OOK transmitter on `ant_433mhz`, FM broadcast-band toy via a PLL-clocked output, SDR receive through an ADC PMOD | an RF experimenter's board |
| `retro-tv` | game2d on composite video | composite/S-Video via `audio_v` (ring 2) or a VGA PMOD | CRT-friendly output |

### Teaching profile

| Profile | What it is | Notes |
|---|---|---|
| `student` | minimum SoC: core, SDRAM, UART, GPIO, JTAG/GDB, boot ROM | The fastest-closing build; mirrors the virtual board (`make sim-board`) one-for-one so lab exercises run identically in sim and on hardware. |

## The board's own devices, and which profile uses each

| Device | IP | Profiles | State |
|---|---|---|---|
| 32 MB SDRAM | `Sdram_Controller.bsv`; G0 own clock + burst DMA | all | done; G0 open |
| FTDI UART | uart0 | all | done |
| microSD | spi0 CS0 | all | done |
| Config flash | spi0 CS1 | all | done (boot); multiboot open |
| HDMI/GPDI | `Video_DVI.v` | all but handheld/student | G1 done; SDRAM scanout, HDMI audio data islands open |
| 8 LEDs, 7 buttons, 4 DIP switches | GPIO | all | LEDs + BTN1 done; rest trivial |
| US2 USB (FPGA-direct) | low-speed/full-speed HID host (keyboard, mouse, pads) | templeos, linux-desktop, game*, launcher | open (G4) |
| ESP32 | uart1 (AT/SLIP), or SPI slave for esp-hosted Wi-Fi; also a file/OSD coprocessor | net, linux-desktop, game* (Bluetooth pads) | open; shares SD pins (only one active) |
| RTC (MCP7940N, check) + battery | I2C (opencores i2c-ocores) | templeos, linux*, net, lab | open |
| HDMI DDC | same I2C | linux-desktop (EDID) | open |
| Audio jack, 4-bit DACs L/R | sigma-delta PCM | templeos, game*, synth, lab | open (G3) |
| Ring 2: composite / S/PDIF | video DAC / S/PDIF encoder | retro-tv, synth | open |
| 8-ch ADC (MAX11125, check) | spi instance | synth, lab, radio | open |
| OLED/LCD header | SPI + scanout DMA | handheld, synth, lab | open |
| 28 header pairs (J1/J2) | GPIO, PMOD slots, LVDS | lab, vision, net, game2d pads | open; the JTAG TAP on gp/gn[0..1] moves to `JTAGG` first |
| HDMI Ethernet pair, CEC | experimental | net (stretch) | open |
| 433 MHz antenna | OOK/FM | radio | open |
| Power control | shutdown, power button | all | open |

## PMODs worth supporting

The two 2x20 headers take standard 12-pin PMODs (check the slot pinout against the ULX3S
schematic: each PMOD slot is 8 signals + 2x 3.3 V/GND). Plan for **four PMOD slots** once the
JTAG TAP moves to `JTAGG`. The list below favours parts with an existing Linux driver (only a DT
node is then needed) and parts commonly sold for the ULX3S/iCEBreaker ecosystem.

| PMOD | Interface | Linux driver | Profiles | Why |
|---|---|---|---|---|
| ULX3S OLED header displays: SSD1331 96x64 colour OLED, ST7789 240x240 IPS LCD (check which are in hand) | SPI | `fb_ssd1331`/`fb_st7789v` (staging fbtft), or a DRM tiny driver | handheld, synth, lab | the displays made for this header |
| LAN8720 RMII Ethernet module (via a PMOD adapter) | RMII, 50 MHz ref clock | LiteEth (`litex,liteeth`) if the MAC is LiteEth-compatible | net, linux-desktop | cheapest 100 Mbit Ethernet; LiteEth already runs on ECP5 |
| Digilent PmodNIC100 (ENC424J600) | SPI | `encx24j600` | net | Ethernet without a new MAC: just spi |
| Digilent PmodPS2 | 2x PS/2 | `altr,ps2-1.0` (needs a matching register block) | templeos, launcher | simplest keyboard + mouse; TempleOS reads scancodes directly |
| Digilent PmodI2S2 (CS5343 ADC + CS4344 DAC, check) | I2S | `simple-audio-card` + an I2S controller | synth, linux-desktop, game* | 24-bit audio in and out |
| Digilent PmodAMP2 / PmodMIC3 | PWM out / SPI mic | — | synth, radio | speaker out, voice in |
| Digilent PmodVGA | 12-bit resistor VGA | simple-framebuffer | retro-tv | second display / CRT |
| 1BitSquared DVI PMOD (TFP410, dual-slot, check) | 12-bit parallel | simple-framebuffer | lab, vision | a second HDMI head |
| QSPI PSRAM PMOD (8-16 MB APS6404, check) or HyperRAM PMOD | QSPI / HyperBus | memory | game3d, vision | a second memory channel: texture or frame store without competing with SDRAM |
| PmodSD | SPI/SD | `mmc_spi` | net, lab | a second card that doesn't share pins with the ESP32 |
| Digilent PmodRTCC (MCP79410) | I2C | `rtc-ds1307` (mcp7941x) | boards without the RTC fitted | timekeeping |
| Digilent PmodGPS (UART + 1PPS) | UART | gpsd (user space) | net, radio | stratum-1 NTP with PPS on a GPIO interrupt |
| Digilent PmodNAV / PmodACL2 (IMU, accelerometer) | SPI/I2C | IIO drivers (`lsm9ds1`, `adxl362`) | handheld, game2d | tilt controls |
| Digilent PmodJSTK2 / PmodKYPD / PmodENC | SPI / GPIO | gpio-keys, rotary-encoder | synth, lab, handheld | controls |
| SNES/NES pad PMOD, DB9 Atari/Sega joystick PMOD | shift register / GPIO | gpio (or a pad register) | game2d, game3d, retro-tv | real controllers |
| Digilent PmodAD1 / PmodDA2 / PmodDA4 | SPI ADC/DAC (1 MSPS) | IIO (`ad7476`, `ad5064`) | lab, radio | faster than the on-board ADC: scope, SDR baseband |
| Digilent PmodHB5 / PmodDHB1 (H-bridge), servo header | PWM | pwm-servo | lab | motor control |
| Digilent Pmod8LD / PmodSSD / PmodCLS | GPIO / UART | leds-gpio, auxdisplay | student | lab exercises |
| OV7670 / OV2640 camera (header-wired) | 8-bit parallel + SCCB (I2C) | (frame grabber of our own) | vision | live camera on HDMI |

Excluded, and why: the ECP5-85F (LFE5U) has no SERDES, so no PCIe/SATA/USB 3; MIPI CSI cameras
need a D-PHY front end (only via resistor-network tricks, a stretch at best); Wi-Fi PMODs
duplicate the ESP32.

## Shared IP work packages (new beyond Phase 5's B0/G0-G7)

| # | IP | Used by | Notes |
|---|---|---|---|
| P0 | `SOC=` profiles + multiboot + flash layout | all | first, before any profile |
| P1 | `JTAGG` TAP (frees 4 header pins, one cable for program + debug) | all PMOD users | changes `openocd` config only |
| P2 | I2C host (opencores-compatible) | RTC, DDC, camera SCCB, PMODs | on the register bus |
| P3 | uart1 (16550 subset) | ESP32, MIDI, GPS | on the register bus |
| P4 | PS/2 host (2 ports) | templeos, launcher | quick win for keyboard + mouse before USB |
| P5 | USB HID host on US2 (LS/FS soft PHY, 48 MHz domain) | templeos, linux-desktop, game* | G4 |
| P6 | Audio: sigma-delta PCM FIFO + tone; I2S out; HDMI audio data islands | templeos, game*, synth | G3 |
| P7 | SPI LCD/OLED scanout DMA (framebuffer → ST7789/SSD1331) | handheld, synth, lab | shares `Video_DVI.v` pixel RAM |
| P8 | Ethernet MAC (LiteEth-compatible, RMII) | net, linux-desktop | the largest new IP after the game engines |
| P9 | Logic analyzer / scope capture (BRAM ring, triggers, SUMP) | lab | 100-200 MHz capture domain |
| P10 | Camera frame grabber + DSP filters | vision | DVP input, SCCB via P2 |
| P11 | Composite video encoder on `audio_v` | retro-tv | NTSC/PAL from the 4-bit DAC |
| P12 | QSPI PSRAM / HyperRAM controller | game3d, vision | second memory channel |
| P13 | Power / multiboot register | all | with P0 |

## TempleOS on the `templeos` profile (decision: full graphics, C2)

TempleOS gets its real `gr`/DC layer on the 640x480 16-colour framebuffer (video mode 1, already
in lx39: 4 bpp, the native TempleOS format, so no conversion).
1. Point the gr frame buffer at `0xC100_0000`, load the 16-colour palette at `0xC001_0400`.
2. The window manager's periodic update (`GrUpdateScrn`-style) copies the composed screen into
   the pixel RAM. Measure it: 150 KB per frame over the register bus is ~38K uncached writes; if
   that's too slow, add a write-combining path or a DMA copy from SDRAM (G0) to the pixel RAM.
3. Mouse and keyboard: P4 (PS/2 PMOD) first, P5 (USB) later.
4. `Snd()` → P6 tone generator.
5. Board-suite checks: framebuffer CRC after a known draw, `fb_capture` sim compare.

## Order

1. P0 + P13 (profiles, multiboot), then the `launcher` and `student` profiles (smallest, and the
   timing references).
2. `templeos` (C2 graphics, P4 PS/2, P6 tones, P2 RTC).
3. G0 (SDRAM clock + DMA) → `linux-desktop` (SDRAM scanout, P5 USB, P6 audio, P3 ESP32).
4. `net` (P8 or PmodNIC100 first, since it needs no MAC).
5. `game2d` → `handheld` / `retro-tv` (variants of game2d).
6. `synth`, `lab` (P9), `vision` (P10, P12).
7. `game3d`.
8. `radio` (stretch, after checking local rules).

## Decisions for the user

1. Golden image at flash 0: `launcher`, or keep the original bitstream at 0 and put all Flute
   SoCs in slots (D1 of `lx39-followups-plan.md`)?
2. Which PMODs are in hand (or to buy) first: suggested PmodPS2, LAN8720 RMII module,
   PmodI2S2, an ST7789 240x240 LCD for the OLED header, a QSPI PSRAM PMOD.
3. Whether `templeos` keeps S-mode (lets the same bitstream also boot Linux) or drops it for area.
