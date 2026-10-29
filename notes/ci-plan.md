# CI and hardware-free simulation plan

Goal: anyone can clone the repo, build it, and boot the SoC (hello, the TempleOS REPL, Linux on
the `linux-isa` branch) without the board or any machine-local paths. GitHub Actions runs the
same flows on every push so local changes cannot silently break the system or the build.

## 1. Remove local dependencies -- done

- Tools from PATH (`bsc`, `verilator`, `yosys`, `nextpnr-ecp5`, `ecppack`,
  `riscv64-unknown-elf-gcc`); the old `~/src` / `../bluespec-ulx3s` locations are used only
  when present. One resolver for bsc: `scripts/bsc_lib.sh`, `scripts/bsc_bin.sh`.
- Submodules over https: `Flute` (npe9/Flute), `templeos/tos` (npe9/templeos-cursor-riscv,
  public since 2026-10-28; HolyC compiler + bootstrap tree).
- Strict-BRAM Bluesim header vendored (`scripts/bluesim/`).
- Optional external verifiers stay env-configurable: riscv-formal (`RISCV_FORMAL`), Sail
  (`SAIL_DIR`), RISCOF, TestRIG, testfloat, the SVA yosys. Not part of public CI.
- Prebuilt REPL image (`templeos/prebuilt/`) as the fallback when the submodule is absent.

## 2. CI image and workflow -- done

- `ci/Dockerfile`: Ubuntu 24.04, bsc 2025.01.1, Verilator v5.052 (pinned: the strict harness's
  x-initial/seed behaviour is version-sensitive), oss-cad-suite 2026-10-01, RISC-V bare-metal and
  Linux GCC, dtc. Published as `ghcr.io/npe9/flute-ci:<Dockerfile hash>`.
- `.github/workflows/ci.yml` jobs: verilog; bluesim (hello + TempleOS REPL, `ci/bluesim_gate.sh`);
  strict (Verilator J1 + cache/AMO); bitstream (25 MHz constraint, not on PRs); on branches whose
  SoC has S-mode: linux-sw (`linux-sw/build-native.sh fp`, cached), linux (Verilator harness to
  `/init` "tick 2 ... fp ok"), bluesim-linux (Bluesim, same pass string).
- Bluesim testbench fixes found on the way: both TBs assumed a 12.5 MHz clock (the SoC runs 25 MHz
  -- the cause of the revoked REPL-TB verdict in AGENTS.md); `SoC_Boot_Tb`'s chunk XOR was
  accumulated on every cycle of the stop bit (always 0, every chunk NAKed); unconditional
  per-beat model logging (GBs per run) now behind `TB_PROBES`.
- More TB fixes for the `linux-isa` (memlat) controller: `sdram_dq_in` in its own rule with
  `m_dq` a ConfigReg (schedule); the SDRAM model opens a row on the ACTIVATE cycle (beat 0 of a
  WRITE right after ACT went to the previous row and overwrote OpenSBI's relocation table); the
  REPL TB's preload uses the controller's line-in-one-bank mapping; `BSIM_TRNG` swaps the
  imported ring-oscillator Verilog for a BSV LFSR (Bluesim cannot instantiate Verilog).
- Measured (M-series Mac): hello 70M cycles ~8 min; REPL prompt ~89M cycles, gate ~22 min;
  Linux to `/init` "tick 2" 139M cycles ~18 min (16M of them zero-filling the SDRAM model);
  strict J1 38 min (hello banner at 52.19M cycles, coverage on). GitHub's 4-core runner is
  ~5x slower: J1 needs ~3 h, so strict tests run as a j1/cache/amo matrix, cache/AMO without
  coverage (`TB_NOCOV=1`; their verdict is the UART trace, J1's includes the hazard bins).
- Status (2026-10-29): done. All jobs green on GitHub -- `main` at 3aac963 (run 40752521072:
  verilog, Bluesim hello + TempleOS REPL from source, J1, cache, AMO, bitstream 44.63 MHz) and
  `linux-isa` at 33bebdb (run 40775810813: the same plus linux-sw from kernel.org source,
  Verilator Linux to /init in 21 min, Bluesim Linux in 1h49m). Stopgaps: J1's BTB census-alive
  check is waived in CI (census 1 locally, 0 on the runner; seed now pinned), and Bluesim uses
  a BSV LFSR for the ring-oscillator TRNG (`BSIM_TRNG`). Image: `ghcr.io/npe9/flute-ci`
  (public). Pushes cancel a branch's running CI (`cancel-in-progress`), docs-only pushes skip it.

## 3. Virtual ULX3S: a BSV board simulator for users without hardware -- planned

A Bluesim (and optionally Verilator) executable that behaves like the board from the host's point
of view, so the normal tools work against it unchanged: `scripts/loader.py`, `picocom`,
`scripts/dmi.py`, `scripts/hw_test_suite.py` (minus timing checks), the TempleOS REPL, Linux.

- **Top**: `mkULX3S_Sim` wraps `mkULX3S_Top` (the same netlist the FPGA gets) with board models:
  - SDRAM: the W9825G6KH behavioural model already in `test/Repl_Boot_Tb.bsv`, factored into its
    own package, with optional image preload (BDPI) for fast boots.
  - FTDI UART: the TX/RX pins bridged to a host **pty** (or TCP socket) through BDPI, so
    `loader.py -p /dev/pts/N` and terminals connect as if to `/dev/cu.usbserial-*`. Bit-accurate
    8N1 at the configured baud, so the real boot ROM protocol (chunks, ACK/NAK) is exercised.
  - LEDs and buttons: LED changes printed (or a tiny status line); buttons driven from the
    terminal or a control socket.
  - Debug: the UART DMI bridge works over the same pty; optionally a JTAG remote-bitbang socket
    for OpenOCD.
  - Later: GPDI/HDMI framebuffer dumped to PNG/VNC, SD card backed by an image file.
- **Speed**: Bluesim runs the full SoC at about 200K cycles/s (~1/125 of real time at 25 MHz);
  a hello boot takes about a minute and Linux tens of minutes. A Verilator build of the same top
  (from `build/verilog_all.v`, as the strict harnesses do) is several times faster; offer both
  (`make sim-board`, `make sim-board-verilator`).
- **Fidelity notes**: Bluesim's BRAM model is idealized (AGENTS.md); the strict Verilator
  harness remains the functional gate. The board simulator is for running software and teaching,
  and its README must say so.
- **CI**: the existing Bluesim gates become thin scripts over the board simulator (load hello over
  the pty, expect the banner; boot the REPL, send `1+1;`, expect `=2`; boot Linux, expect
  `tick 2`), replacing the special-purpose `SoC_Boot_Tb` / `Repl_Boot_Tb` host logic.
- **Docs**: a "No board? Use the simulator" section in the README with copy-paste commands using
  the CI container.
