# Notes: a Cargo/Go-style workflow manager for Flute/ULX3S

This is a working brain-dump of what a `cargo`/`go`-style tool would look like
for this project.  The goal is to turn the current shell/Make/incantation
workflow into something reproducible, cache-friendly, and pleasant to use.

The ideal normal experience should be:

```bash
$ fpga build
Compiling Flute v0.3
Synthesizing for LFE5U-85F...
Placing...
Routing...
Checking timing...
✓ Build complete
Resources:
  LUT       31,284 / 83,640   37%
  FF        18,912 / 83,640   23%
  BRAM         104 / 208      50%
Clock sys:
  requested    25.000 MHz
  achieved     28.37 MHz
  slack        +4.75 ns
Bitstream:
  build/ulx3s/flute.bit
```

That is the target.  The underlying FPGA process will always be more
complicated than software compilation because it is logical *and* physical,
but most of the current friction is accidental complexity.

## Why this matters now

The project just crossed the UART+SDRAM bring-up finish line.  From here the
work splits into two very different loops:

1. **Software iteration** — change C/assembly, rebuild, load over UART, test on
   hardware.  This should be sub-10 seconds.
2. **Hardware iteration** — change BSV, resynthesize, place-and-route, test on
   hardware.  This is minutes even when everything is cached.

Right now both loops are manual and error-prone.  A workflow manager can make
(1) feel like `go run` and make (2) feel like `cargo build --release`.

## Current pain points

- **Toolchain discovery.** `bsc`, `yosys`, `nextpnr-ecp5`, `ecppack`,
  `openFPGALoader`, and the RISC-V toolchain all have to be on `PATH` or
  configured by hand.  The Makefile uses hard-coded paths to a sibling repo
  (`../bluespec-ulx3s/toolchain/...`).
- **No incremental/cached BSV build.** `make bitstream` always runs BSC from
  scratch even if only one `.bsv` file changed.  BSC *can* do incremental
  compilation (`-bdir` `.bo` files), but the Makefile does not track package
  dependencies, so a clean build is the safe choice.
- **No deterministic P&R output.** nextpnr needs a `--seed`.  The repo already
  has dozens of `nextpnr_seed*.log` files from manual seed sweeping.  There is
  no automatic "find the best seed and record it" step.
- **Bitstream and software builds are separate.** `make all` builds both, but
  there is no single command that programs the board *and* loads the current
  software image.
- **No `test` target.** Bluesim (`test/Sdram_Tb.bsv`) and the host-side loader
  are not wired into the build.  Running a regression requires remembering ad
  hoc `bsc -sim` commands.
- **No dependency manifest.** `Flute/` is a Git submodule.  There is no lockfile
  for its commit, the BSC version, or the toolchain versions.
- **Secret files / env vars.** Serial port selection (`/dev/cu.usbserial-XXXX`)
  is passed manually to both openFPGALoader and the loader script.

## Proposed tool: `fpga`

A single CLI that knows the whole flow, modeled on Cargo:

```bash
fpga new my_soc              # create a project from a template
fpga init                    # turn the current directory into an fpga project

fpga build                   # fast development build
fpga build --release         # timing-optimized build + seed sweep
fpga build --sw              # also build sw/
fpga build --sim             # build Bluesim testbenches

fpga check                   # lint + timing slack check
fpga timing                  # print worst paths
fpga timing --path 1         # full path report
fpga timing --source         # map path back to BSV

fpga test                    # run tests that do not need hardware
fpga test --board            # build, program, and run hardware tests

fpga run                     # build if necessary, program FPGA, open UART
fpga run --bin sw/memtest.bin

fpga load sw/hello.bin       # just load a binary over UART
fpga program                 # just program the bitstream

fpga clean / fpga purge      # remove build artifacts / cache
```

### Example output

```bash
$ fpga build
error: timing constraint not satisfied
  clock `sys`
    required:   25.000 MHz
    achieved:   23.16 MHz
    slack:      -3.18 ns
  critical path:
    dcache.data_ram
        │
        ├─ BRAM        4.2 ns
        ├─ logic      15.7 ns
        └─ routing    23.3 ns
        │
        ▼
    cpu.load_result
  help: run `fpga timing --path 1`
```

```bash
$ fpga test --board
Programming ULX3S...
Resetting SoC...
Running:
 ✓ boot ROM
 ✓ integer ISA
 ✓ CSR
 ✓ UART
 ✓ SDRAM
 ✓ D-cache
 ✓ I-cache
8 passed
```

## Manifest: `Fpga.toml`

One file describes the project, dependencies, target, and toolchain.

```toml
[project]
name = "flute-soc"
version = "0.3.0"
edition = "2024"

[target.ulx3s]
device = "LFE5U-85F-6BG381C"
board = "ulx3s"

[clock.sys]
frequency = "25 MHz"

[sources]
bluespec = ["src/**/*.bsv"]
constraints = ["constraints/ulx3s_85f.lpf"]

[top]
module = "mkSoC"
verilog_wrapper = "src/Top.v"

[dependencies]
flute = { git = "https://github.com/Bluespec/Flute", rev = "abc1234" }

[features]
default = ["rv32", "dcache-8k"]
dcache-4k = []
dcache-8k = []
dcache-1way = []

[toolchain]
bsc = "2024.07"
yosys = "0.42"
nextpnr = "0.7"
```

A generated `Fpga.lock` would pin:

- dependency commits,
- the winning nextpnr seed,
- achieved Fmax and slack,
- toolchain versions actually used.

## Debug vs release builds

`fpga build` optimizes for iteration speed:

```
BSC -> Yosys -> fast placement -> route -> bitstream
```

`fpga build --release` does the expensive work:

```
BSC -> timing-oriented Yosys -> parallel P&R (seed 1..N)
  -> timing analysis -> choose best passing implementation -> bitstream
```

This mirrors `cargo build` vs `cargo build --release` exactly.

## Incremental build graph

The tool should build a DAG and only re-run nodes whose inputs changed.

```
BSV sources + Boot ROM  ->  .bo files  ->  Verilog
Verilog + Top.v + BSC lib ->  Yosys JSON
JSON + LPF + seed       ->  nextpnr config
config                  ->  bitstream
sw/*.c                  ->  .elf -> .bin
bitstream + .bin        ->  board load
```

Key caching rules:

- BSV package compilation: cache per `(source hash, defines, bsc version)`.
- Verilog synthesis: cache per `(verilog hash, yosys version, top)`.
- P&R: cache per `(json hash, lpf hash, seed, nextpnr version)`.
- Bitstream: cache per `(config hash, ecppack version)`.

This turns a no-change rebuild into a near-instant "all artifacts up to date"
message, like `cargo build`.

## Timing as a first-class build property

`fpga build` should fail clearly when timing is not met and explain why.
`fpga timing` should be interactive:

```bash
$ fpga timing
Clock: sys
Worst paths:
  slack       path
  -3.18 ns    dcache → load_result
  -2.71 ns    dcache → load_result
  -1.42 ns    icache → instruction
  +0.83 ns    execute → pc
```

`fpga timing --source` maps the critical path back to BSV modules and rules.
`fpga bench-build --features dcache-4k-1way,dcache-8k-1way` can sweep
architectural configurations and report LUT/BRAM/Fmax:

```
Configuration    LUT    BRAM    Fmax
4K 1-way         ...    ...     31.2 MHz
8K 1-way         ...    ...     30.4 MHz
8K 2-way         ...    ...     26.8 MHz
```

## Seed / timing management

`fpga build --release` (or `fpga place --sweep N`) should:

1. Build the synthesized JSON once.
2. Run nextpnr for seeds `1..N` in parallel where possible.
3. Collect `(seed, fmax, slack, lut, ff, bram, dsp)`.
4. Pick the best seed by a policy (e.g., highest slack at the target frequency).
5. Write the seed and metrics into `Fpga.lock`.
6. Promote the winning config to the active bitstream.

A `fpga check` command would read the lockfile and fail if the current build
has negative slack, so CI can catch timing regressions.

## Dependency / package management

Two well-known tools already solve pieces of this:

- **[Bender](https://github.com/pulp-platform/bender)** is a dependency manager
  for hardware projects.  It fetches HDL packages from Git, resolves versions,
  and generates a file list for the simulator/synthesizer.  It is much smaller
  and simpler than FuseSoC.
- **[FuseSoC](https://github.com/olofk/fusesoc)** is a full package manager and
  build abstraction layer.  It uses **Edalize** to talk to many EDA tools
  (Vivado, Icarus, Verilator, etc.).  It is heavier but is the closest thing
  the FPGA world has to `cargo` today.

For this project a thin wrapper around Bender plus a custom backend for the
Yosys/nextpnr/openFPGALoader flow is probably the sweet spot.  FuseSoC could be
a later migration if we want to support multiple boards or simulators.

An IP package would contain not merely HDL but metadata:

- RTL/BSV sources
- supported devices
- clock interfaces
- constraints
- parameters
- formal tests
- simulation models
- documentation

So using an IP block becomes much closer to using a software library.

## Toolchain pinning

Options, from lightest to heaviest:

1. **Path + version checks.** The tool records expected versions in
   `Fpga.toml` and fails with a helpful message if `bsc --version` does not
   match.
2. **Toolchain directory.** A `toolchain/` subdirectory (like the sibling
   `bluespec-ulx3s/toolchain/`) with scripts that download and build each tool.
3. **Nix flake.** A `flake.nix` that provides exact versions of BSC, Yosys,
   nextpnr, prjtrellis, openFPGALoader, and the RISC-V toolchain.  This is the
   most reproducible but has the steepest learning curve for new contributors.
4. **Containers.** A Dockerfile or devcontainer with everything installed.

For a one-person project, option 1 + a `toolchain/README.md` is enough.  For
open-source sharing, option 3 (Nix) is ideal.

## Boards as first-class targets

You should not need to remember `--85k --package CABGA381 --lpf ulx3s.lpf`.
Instead:

```bash
fpga target add ulx3s-85f
fpga build --target ulx3s-85f
```

The target definition knows:

- FPGA part and package
- oscillator frequency
- PLL capabilities
- pinout
- SDRAM / flash / UART / USB-JTAG
- LEDs / buttons

Much like `rustup target add riscv64gc-unknown-none-elf`.

## Testing integration

```bash
fpga test              # BSV unit tests -> RTL simulation -> Verilator
fpga test --board      # program board and run hello/memtest over UART
```

The `--board` path should:

- program the bitstream,
- discover the serial port (default to the one in `Fpga.toml`, allow override),
- reset the SoC,
- run each test program and check output,
- report pass/fail.

## Serial port / board discovery

Use `ls /dev/cu.usbserial-*` and pick the one matching a pattern in
`Fpga.toml` (e.g., `usbserial-120001`).  If multiple match, list them and let
the user choose, or use a stable symlink created by a udev/devd rule.  Store the
chosen port in a local `.fpga/state.json`.

## Configuration layers (precedence low -> high)

1. Defaults built into the tool.
2. `Fpga.toml` in the project root.
3. `Fpga.lock` for pinned values (seed, dependency commits).
4. `~/.config/fpga/config.toml` for user-wide toolchain paths.
5. Environment variables (`FPGA_BSC`, `FPGA_PORT`, ...).
6. Command-line flags (`--seed`, `--port`).

## Suggested implementation phases

### Phase 0: Makefile cleanup (do this first)

- Add a `test` target that rebuilds and runs `build/sdram_tb`.
- Add a `run-memtest` target that programs and loads memtest.
- Centralize toolchain paths in one `config.mk` or use environment variables.
- Make `SEED` read from a `build/seed.txt` or `Fpga.lock` file.

### Phase 1: A thin Python wrapper

- Write `fpga` as a Python script in `scripts/`.
- Implement `fpga build`, `fpga run`, `fpga load`, `fpga test --sim`.
- Use the existing Makefile under the hood.
- Add a `Fpga.toml` parser (use `tomli`/`tomllib`).

### Phase 2: Incremental build

- Replace the monolithic `make bitstream` with per-stage caching.
- Parse BSC `-info` files to discover package dependencies for BSV.
- Add `fpga build --release` / `fpga place --sweep`.

### Phase 3: Package management

- Add `fpga add <git-url>`.
- Integrate Bender for dependency resolution.
- Generate lockfiles.

### Phase 4: CI / reproducibility

- Nix flake or Dockerfile.
- GitHub Actions job that builds the bitstream and runs `--sim` tests.
- A timing summary artifact produced on every build.

## Random smaller quality-of-life ideas

- `fpga fmt` for Bluespec (if a formatter exists) or at least a style check.
- `fpga size` to print resource usage from the latest nextpnr run.
- `fpga wave` to open a VCD from Bluesim.
- `fpga console` to open picocom on the detected port.
- `fpga reset` to pulse the FPGA reset without reloading the bitstream (use
  the FTDI CBUS or a soft reset register).

## Open questions

- Should the tool be Python (easy, matches loader.py) or Rust (fast, cargo-like
  feel)?  Python is fine until Phase 2/3.
- Should nextpnr seed sweeping happen on every `fpga build --release`, only on
  explicit `fpga place --sweep`, or both?
- How should we handle the FTDI dual-port setup on macOS so the user never has
  to guess which `/dev/cu.usbserial-*` is the ULX3S?
- Should the Bluesim testbench be fixed *before* investing in the wrapper, so
  `fpga test --sim` has something real to run?
