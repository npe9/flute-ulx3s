# ULX3S Bluespec Flute SoC

This project brings up [Bluespec Flute](https://github.com/Bluespec/Flute) RV32IMAC on the [Radiona ULX3S-85F](https://ulx3s.github.io/) ECP5 board.

Current status (main, 2026-10-28):
- Core: RV32IMAC, M+U privilege, write-through L1 caches, 64-bit AXI4 fabric, RISC-V debug
  module (UART DMI bridge and FTDI JTAG). The current base is **E20**: pipelined I-side
  (`ICache_Pipe.bsv`), CPI 1.05 on straight-line code (was 4.0).
- Clock: the 25 MHz on-board oscillator drives the SoC directly. Post-route fmax is
  48.9-53.1 MHz over 4 seeds (seed 3 = 48.88 MHz ships). `make SYS_PLL=1` builds an optional
  32.142857 MHz PLL clock (`src/Top.v`).
- FTDI UART at 625000 baud; the boot loader in on-chip ROM loads images into SDRAM with a
  chunked, checksummed protocol.
- SDRAM (W9825G6KH-6, 32 MB) runs `hello.bin`, the 28 MB memtest, and the TempleOS HolyC
  REPL, which evaluates HolyC on hardware.
- `ndmreset` (debug-module system reset) works with traffic in flight: epoch-tagged AXI IDs,
  memory-controller drain, a two-pass SoC reset, and a deburster reset.
- Every change ships only after the verification gates below.

Linux: the `linux-isa` branch (outer repo and the Flute submodule, worked in a separate
checkout) adds S-mode, Sv32 (I and D TLBs), PMP, F/D, Zb* and Zkn/Zkr/Zkt, and boots OpenSBI 1.9 +
Linux 6.12 on the board at 32.14 MHz (`make SYS_PLL=1`). It is not merged into main.

Planned peripherals (after UART/SDRAM bring-up):
- HDMI via the GPDI connector.
- Stereo audio via the 3.5 mm jack (I2S / Sigma-Delta).
- USB host/device controller via the USB-A and on-board ESP32/USB options.

## Hardware setup

1. Connect the ULX3S USB port to your Mac.
2. Find the FTDI serial device:
   ```bash
   ls /dev/cu.usbserial-*
   ```
3. Open a terminal at 625000 baud, for example:
   ```bash
   picocom -b 625000 /dev/cu.usbserial-XXXX
   ```
   The bootloader banner is:
   ```
   ULX3S Flute SoC: boot loader
   ```

## Build

```bash
export PATH="$HOME/src/bsc/inst/bin:$PATH"
make bitstream   # BSV -> Verilog -> Yosys -> nextpnr -> bitstream
make sw          # build example RISC-V programs
```

The default `make` target builds both the bitstream and the example software.

`make SYS_PLL=1` builds for the 32.142857 MHz PLL clock. bsc -u does not notice -D changes,
so switch with a clean bsc build (`rm -rf build/bsc build/verilog/mkULX3S_Top.v`).
Promoted bitstreams are kept under `bits/` (`openFPGALoader` needs the `.bit` extension in
the file name).

## Program and run

Load the bitstream into volatile FPGA SRAM and start the UART bootloader:

```bash
make program
python3 scripts/loader.py sw/hello.bin -p /dev/cu.usbserial-XXXX -t 10
```

`scripts/loader.py` waits for the bootloader banner, sends the kernel address and
byte count, streams the file, then relays anything the loaded program prints.

## TempleOS HolyC monitor

The `templeos/` directory builds a tiny bare-metal monitor from HolyC using the
`templeos-cursor-riscv` host compiler (`holyc-riscv --target rv32`). The monitor
is loaded by the same UART bootloader and gives you a simple way to interrogate
the machine:

| Command | Action |
|---------|--------|
| `r <addr>` | Read a 32-bit word and print it in hex |
| `w <addr> <val>` | Write a 32-bit hex word |
| `g <addr>` | Jump to an address |
| `h` | Show help |

Build and run it interactively:

```bash
make templeos-run
# or a short automated smoke test:
make templeos-smoke
```

The bootloader enables the 16550 RX FIFO, but multi-megabyte images still need
to be streamed at line rate to avoid FIFO overrun. `scripts/loader.py` has a
`--pace` option for this; the REPL target uses `--pace 0.00009`.

## Full HolyC REPL

The `templeos/` directory can also build the full `templeos-cursor-riscv` HolyC
REPL (`repl-holyc.elf`) for ULX3S:

```bash
make templeos-repl      # build templeos/build/ulx3s_repl.blob.bin
make templeos-repl-run  # program FPGA and load the REPL over UART
```

The REPL image is ~2.9 MB; the chunked UART load (625000 baud, seq+XOR+pad
framing with per-chunk retry) takes ~90 s. When it finishes you get the boot
banner, a `/proc`-style system report, and a `>` prompt:

```
TempleOS RISC-V — HolyC AOT REPL (repl-holyc.elf)
  Eval     >  ExePutS compile loop; I64 expr / fun defs; Print;
  ...
Try: Dir;  Fault;  MemMap;  Regs;  Sys;  Tty;  VtList;  Man("CrashMon");  DMesg;

>
```

### Current REPL status on RV32

**Hardware-validated end-to-end (2026-10-08):** `python3 scripts/hw_repl_test.py`
reprograms the ULX3S, loads the 2.59 MB `ulx3s_repl.blob.bin` over the FTDI
UART in ~60 s (10k chunks, per-chunk seq+XOR+pad framing, drain+NAK retries),
verifies a head+tail SDRAM readback, boots the REPL to the `> ` prompt, and
**evaluates HolyC**: `1+1;` compiles through the in-image JIT and prints
`ans=0x0000000000000002=2` (the test fails if `ans=` is missing). Interactive
session verified on the board:

```
> 1+2;                        ans=0x0000000000000003=3
> (1+2)*3;                    ans=0x0000000000000009=9
> 100/7;                      ans=0x000000000000000e=14
> 2*3+4*5;                    ans=0x000000000000001a=26
> Print("hello from holyc");  hello from holyc
> I64 x = 40;  x+2;           ans=0x000000000000002a=42
> for (I64 i=0;i<4;i++) Print("%d",i);   4294967296..99 (see I64 note)
> U0 Hi() { Print("hi"); }  Hi();        hi
> Fault;                     *** FAULT: illegal instruction … (full dump)
                            -- eval aborted, back to the REPL --
> 1+5;                       ans=0x0000000000000006=6
```

Newlines: output is CRLF (`g_uart_onlcr` in the ULX3S UART overlay translates
`\n` → `\r\n` in `PutCh`), so a raw serial terminal renders clean lines.
`MemMap;` prints the actual Flute SoC map, and every value in it is DERIVED
rather than hand-maintained (see "Memory map derivation" below).  Exception
faults print the full crash dump (cause, registers, memory
snapshots) and return straight to the `> ` prompt — no interactive `crash>`
stop — via `CrashAutoRecover`, the trap handler the ULX3S build binds with
`SetTrapFn` (`ULX3S_CRASH_AUTO_RECOVER` in `ulx3s_memmap.hc`; upstream
default unchanged). The interactive dig-down remains available via the
`CrashMon;` command.

#### Self-describing SoC (SoC Info block @ 0xC0003000)

The SoC describes itself at runtime. `src/SoC_Info.bsv` is a read-only AXI
slave (4 KB at `0xC0003000`, discoverable as the `soc_info` region in the
manifest) exposing: `SOC_MAGIC` ("FLS1"), `SOC_VERSION` (HW ABI), `SOC_BUILD_DATE`
(from `-D SOC_BUILD_DATE=YYYYMMDD`, wired in the Makefile), `SOC_FEATURES`
(bitmask: uart0/gpio/clint/soc_info today; bits 4-8 reserved for the trace
buffer, bus-error monitor, watchdog, DMA, and perf counters), `CPU_HZ`,
`TIMER_HZ`, `MEMORY_SIZE`, `DEVICE_COUNT`, `DEVICE_TABLE`, and `RESET_REASON`
(0 until the watchdog lands). At offset `0x100` sits a **device descriptor
ROM** — 8 x u32 records {type, version, base, size, irq, flags} generated at
elaboration from the SAME `fn_soc_memmap()` table the AXI fabric decodes, so
the software-visible device list cannot drift from the address decoder.
`MemMap;` reads the block live (guarded by the magic, so old bitstreams
report "not present" instead of faulting).

#### Bus error monitor (FEATURE bit 4)

Unmapped-address accesses have always faulted cleanly (the AXI fabric
synthesizes DECERR); now they are also *observable*. `AXI4_Fabric.bsv`
carries the faulting address through its error-response path and emits a
`BusErrEvent {addr, is_wr, master, resp}` on the `err_events` Get
interface; a capture rule in `SoC_Top` feeds it into `SoC_Info`:

| Offset | Register | Meaning |
|---|---|---|
| 0x028 | `BUSERR_STATUS` | bit0 captured, bit1 is_write, bits[15:8] master, bits[17:16] resp |
| 0x02C | `BUSERR_COUNT` | saturating decode-error count |
| 0x030/0x034 | `BUSERR_ADDR_LO/HI` | first error's address (frozen) |
| 0x03C | `BUSERR_CLEAR` | write anything to clear count + capture |

`MemMap;`'s live probe shows the running count. First error freezes;
count keeps climbing. The event FIFO drops under burst (the count is
saturating, so nothing is lost observably); SLVERR responses from mapped
slaves are not yet captured.

#### Interface conformance suite

`python3 scripts/hw_test_suite.py` programs the FPGA, loads the REPL, and
exercises every interface surface end to end (72 checks, ~8 min):
eval core (arithmetic/Print/globals/functions/asm), observability
(Sys/Uptime/MemRep/IrqRep/DevRep/Cnts/DMesg/Regs/Reg/MemMap/MemMapDrv/
Man/Sections/Dir/Pwd/help/Tty/VtList/LogCount/CRLF discipline),
trap recovery (`Fault;`, bad accesses, eval-after-fault), the
self-describing SoC block and device ROM, the bus error monitor
(clear → fault → captured address/count/rw), and the RISC-V debug module
(system-bus reads/writes, SDRAM poke/readback, GPIO LED write/read via
DMI, halt/resume + dpc), plus performance counters. Last run on E20: **70 PASS, 0 FAIL, 2 WARN** — the WARNs
are the documented I64-pair hi-half limitation (`Print("%d", expr)` and
`for`-loop `%d` print 64-bit pair values with garbage hi halves; the
32-bit lo halves are correct). Notes: `Funs*` are upstream-partial
(picker UI); Flute's abstract command supports GPRs + dpc only, so CSR
discovery goes through the REPL's `Reg("…")`; and the REPL's `$HC_DUMP`
framing is fs/9P-backed — it stalls retrying without a 9P host, so the
suite verifies registers over the DMI system bus instead.
For a PLL bitstream set `EXPECT_HZ=32142857` (SoC Info clock and perf-counter rate checks).

#### Debug/verification roadmap (staged)

The register groundwork is laid for the remaining infrastructure, in the
order they should land:

1. **Debuggability** — DONE: bus error monitor (above). Next: an
   instruction trace buffer in BRAM (FEATURE bit 5, readable over the
   UART DMI bridge independently of the CPU).
2. **Real OS support** — watchdog + reset-reason plumbing (FEATURE bit 6,
   `RESET_REASON` register), SPI/SD storage, interrupt-driven UART.
3. **Hardware assurance** — DMA engine (FEATURE bit 7) with an
   address-permission filter, and fault injection (AXI error/timeout
   injection shim) for the verification hooks.

Perf counters (FEATURE bit 8) can start with `mcycle`/`minstret` and grow
SoC-specific AXI-stall counters on the same fabric taps the error monitor
uses.

#### Memory map derivation

`MemMap;` is generated from the elaborated hardware, not hand-maintained
and not parsed out of Bluespec source. The chain:

1. **`SoC_Map.bsv` holds one declarative table** — `fn_soc_memmap()` returns
   the regions `{name, device, base, size, bus, fabric_decoded}` from the
   package-level address constants. `bus` classifies how each region is
   reached: `"axi"` (decoded by the fabric), `"near_mem"` (CLINT, on the
   core's Near_Mem port by architecture), `"reserved"` (declared but no
   slave and no device — the PLIC range).
2. **The AXI fabric decodes from that same table** (`SoC_Fabric.bsv` folds
   `fn_soc_memmap()` into its address decoder), so declared ranges and
   decoded ranges cannot drift apart.
3. **The elaborated design emits a manifest** via `messageM`:
   `MEMMAP <name> <base> <size> <bus> <decoded|no-slave>`, `MEMMAPIRQ
   <name> <source> core_external`, and (from `mkULX3S_Top`) `BOARD clk
   <hz> baud <baud> chip/fpga/core`. Conditional entries follow the same
   `` `ifdef`` flags as the hardware (`INCLUDE_ACCEL0`), and enabling an
   unsupported config (`Near_Mem_TCM`, `HTIF_MEMORY`) prints a manifest
   WARNING. The bsc output is captured to `build/elaboration.log`;
   `scripts/soc_manifest.py` dedupes it into
   **`build/soc-memory-map.json`** — the map of the actual elaborated
   configuration, same DEFINES as the bitstream.
4. **`gen_board_hc.py` runs in the `repl` build** (cmp-guarded; the JSON is
   a Makefile prerequisite that re-elaborates the FPGA when stale) and
   emits `/bootstrap/seed/ulx3s_board.hc`, which `Ulx3sMemMap` prints.
   It cross-checks the guest map (`ulx3s_repl/ulx3s_memmap.hc`) against
   the manifest and **fails the build on drift**.

| Value | Source of truth |
|---|---|
| all region base/size + bus + decoded | emitted by the elaborated design (`fn_soc_memmap`) |
| UART0/GPIO irq (core ext sources 0/1 — not 10; 10 is QEMU-virt carryover) | `irq_num_*`, emitted from `SoC_Map` |
| sys clock, baud, chip, fpga, ISA | `mkULX3S_Top` BOARD line, sanity-checked against `src/Top.v` |
| guest arenas (heap/FS/trap/JIT) | the `MEM_*` and `JIT_*` macros already compiled into the image |
| image extent | previous build's blob size (advisory; fixed-point converges) |

Delivery uses MemMap's legacy host-slot hook, which needed an upstream
precedence fix first (`*(I64 *)MEM_HOST_SLOTS + 0x128` dereferenced slot 0
before adding the offset; now parenthesized, 5 sites in seed csr.hc).

Getting here required three fixes, each found by the crash monitor's own
fault dump (`mcause/mepc/mtval/registers`):

1. **UART register stride in the trap overlay.** `TrapUartHwDrain` /
   `UartBreakIrqInit` polled/wrote the 16550 with PC-style byte offsets
   (`MEM_UART+5`, `+1`); the SoC UART decodes aligned word registers only, so
   the first eval's break-arm drained into a load access fault at 0xC0000005.
   Fixed to word offsets (+20 / +4). The break-interactive path had never run
   on hardware before (the eval dispatch that reaches it was stubbed).
2. **Host compiler emitted an RV64 `addiw` on `--target rv32`.** `asm { li
   t0, 2048 }` expands GNU-as-style `lui+addiw`; OP-IMM-32 is reserved on
   RV32, so `HcCsrsMieExt` (used by BreakArm) trapped illegal instruction.
   Fixed `RvExpandLiGas32` to select `addi` on rv32 (rv64 unchanged);
   regression test `tests/asm/rv32_li_test.py` (wired into `make asm-stress`).
3. **`mcause` interrupt test used an RV64-ism.** `TrapDispatch` tested
   `cause < 0`, but on RV32 the interrupt bit is bit 31, which zero-extends
   into a positive I64 — the break watchdog timer irq (code 7) fell into the
   crash path. Fixed to `cause & 0x80000000` in the ULX3S trap overlay.

Known limitations (documented, not blocking):

- **JIT I64 arithmetic is 32-bit (P0 subset).** Values fit in 32 bits work
  everywhere; wider values lose the high half (`3000000000+3000000000` wraps,
  and `for (I64 i=0;…)` prints i with a garbage hi half). Pair-propagating
  codegen (`addc`-style hi updates) is upstream P1 work
  (`host/holyc_target.h`).
- **The thin-image mini assembler works; the full `AsmRepl` UI is
  product-kernel-only.** `asm { li a0, 42; }` / `I64 F() { asm { … } }`
  assemble through `EvalAsmRun`/`EvalAsmFunDef` (9 mnemonics) and
  `Reg("a0")` / `Regs;` read back live values — all RV32-ported (`sw` pairs
  into the real `MEM_REGS_SNAP` page, CSR spill included) behind
  `ULX3S_RV32_SNAP` in seed csr.hc. The rich assembly-stepping UI
  (`Kernel/RVAsmReplUi.HC` — VT panes, per-step register diffing) ships in the
  upstream `repl-cmp` product image and needs the kernel doc/VT stack; porting
  it to the thin image (or building the kernel product for ULX3S) is the
  remaining path. Still-RV64 on this port: `RegSnapAsm` (unused export),
  `Bt`, `GdbSnapRegs`, `TrapFrameProbe`, `RegsRestoreDemo` — a fault inside
  them is caught by the `g_in_trap` guard and recovers.
- Bluesim `make sim-repl` boot exceeds the TB's 60M-cycle prompt budget with
  the current image; the hardware test above is the reference gate.

The last eval crash was **not** a compiler bug: the ULX3S heap (`HEAP_BASE`)
was `0x80200000`, inside the AOT image (loaded at `0x80000000`, ~2.6 MB), so
the first `MAlloc` block (brk bump + header ≈ 0x870 bytes) overwrote live code
at `0x80200000–0x80200870` — including the tail of `CmdIs`, which the eval
later jumped into and executed as zeros. `HEAP_BASE`/`MEM_HEAP` are now
`0x80500000` (image ends ~0x802C0000; FS stays at `0x81000000`).

So the ULX3S bring-up currently has:
- Boot loader ✓
- SDRAM ✓
- UART ✓
- REPL AOT image boot + prompt + system report ✓
- Trap vector + dispatch + crash monitor ✓ (exception faults dump correctly)
- **HolyC eval on hardware ✓** — full dispatch restored (`eval.hc`), JIT
  compile-and-run of expressions, Print, typed globals, loops, and fun
  defs/calls (32-bit-range integers; see I64 note above)

Next steps:
1. **RV32 I64-pair JIT arithmetic** (carry-propagating hi half) — upstream
   P1 wide-I64 work in `host/holyc_target.h` terms.
2. **Pair-aware rv32 port of the seed reg-snap/crash-dump asm** (csr.hc /
   crash.hc `sd`/`ld` blocks) so `Regs;`, `Reg("x")`, and crash-monitor `bt`
   work (pattern: the overlay's `sw`-based `TrapCtxSave`).
3. **Port the REPL JIT fully to RV32** — upstream plans host-AOT / guest-Cmp
   rather than growing `jit.hc`.
4. **Rebuild the Flute core as RV64** — fabric is already 64-bit (`FABRIC64`),
   but the CPU datapath/caches roughly double (~49k vs ~39k LUT4s; nextpnr
   did not close timing within 15 min on the ECP5-85F).

### Fixes that unblocked the REPL (2026-10-07)

- `test/Repl_Boot_Tb.bsv` preload swizzle row mask `0x3FE00 → 0x3FFE00`
  (was dropping `idx[23:20]`; the blob tail overwrote its head).
- `Flute/src_Testbench/SoC/Mem_Controller.bsv`: single cached raw word →
  16-entry direct-mapped cache (streaming copies were ~10^5 cycles/byte).
- TB zero-fills the SDRAM model after blob preload (Bluesim `mkRegFile` is
  not zeroed; never-written SDRAM was heap garbage → nondeterministic boots).
- `templeos/Makefile`: two-pass `TRAP_VEC_OFF` (the include resolved to a
  stale upstream `0x5CEFC`; the real TrapVec offset is baked on the 2nd pass).
- `ulx3s_repl/ulx3s_trap.hc`: parenthesized slot macros (`*(I64 *)BASE+off`
  binds as `(*(I64*)BASE)+off` — a C precedence bug) and replaced the
  satp/medeleg/mideleg CSR reads in `TrapSnapPublish` with 0 (no S-mode on
  this core; reading them re-faulted inside the trap handler and looped).
- `ulx3s_start.hc` + upstream `repl.hc`: `SoftDbgHostSlotsClear` moved to
  `main()` before `TrapInit` — it zeroes 4 KiB that includes the trap slots
  and the UART RX-ring pointers, wiping both installations.
- Thin seed build (`GEN_MAX_EMBED=96`): the full ~100 KB memfs seed hashes
  through the I64-emulated FNV multiply at ~2.7k cycles/B — tens of minutes
  of Bluesim per boot (also slow on hardware).
- `ulx3s_mem.hc` + `ulx3s_memmap.hc`: heap base `0x80200000 → 0x80500000`
  (was inside the AOT image; the first MAlloc stomped code the eval needed).

## Verification gates

A change is promoted only when all of these pass (AGENTS.md has the rules; timing closure
comes from architecture, with at least 10% margin before benching):

- **J1 strict sim** — `sim/strict_bram/run.sh --strict=error`: Verilator replay of the boot
  scenario on `build/verilog_all.v` with a strict ECP5 DP16KD BRAM model (lost reads and
  cross-port hazards that Bluesim cannot see), SDRAM model + timing checker, UART scoreboard.
  Compare the hello-banner cycle count against the previous netlist, not just PASS.
- **F2 X-sweep** — `sim/strict_bram/run_sweep.sh 8`: 8 Verilator seeds with randomized
  uninitialized state; output must be byte-identical.
- **Cache / AMO tests** — `test/cache_test.S`, `test/amo_test.S` in the strict sim
  (`TB_TX_TRACE=1`, pass = `T` ... `D`) and on the board (`test/run_cache_test.py`).
- **riscv-formal** — `formal/run.sh`: 10 smoke checks on mkCPU with RVFI (see
  `formal/README.md`); never run two at once against one riscv-formal checkout.
- **ndmreset** — `sim/ndm_bram` in simulation and `test/ndmreset_board.py` on the board,
  idle and busy.
- **Board bench** — `scripts/hw_test_suite.py` (70/0/2 expected).

## Debugging: UART DMI bridge

Flute's on-chip RISC-V Debug Module (External Debug Support v0.13, in
`Flute/src_Core/Debug_Module`) is reachable **over the same FTDI UART** the
console uses — no JTAG header, no external adapter. The
`src/Uart_DMI_Bridge.bsv` module snoops the RX byte stream for the 8-byte
magic `"\xDBSDM\x01\x02\x03\x04"` and then speaks a fixed-frame DMI
protocol, forwarding the requests to `SoC_Top.server_external_control`
(`src/Jtag_Control_Adapter.bsv` does the DMI→`Control_Req` conversion).

- Request:  `[op, dmi_addr, data(4, big-endian)]` — `op` = `'r'` / `'w'` / `'q'` (disarm)
- Response: `[0xDB, status, data(4, big-endian)]` — the marker lets the host
  resynchronize past console output that flushed ahead of a response
- ~1 s RX-idle timeout auto-disarms while armed, restoring console
  pass-through; a *partial* magic match has its own ~10 ms idle timeout
  after which the buffered bytes (including the `0xDB`) are replayed to the
  console in order.

**`0xDB` and binary loads (two fixed bugs, one protocol rule).** The magic
hunt makes `0xDB` a special byte on the console RX path:

1. A bare `0xDB` (not followed by the magic) used to be **dropped** on a
   partial-match mismatch — a one-byte stream shift that corrupted every
   kernel chunk containing `0xDB` (~11k in the REPL image). Fixed: the
   replay now includes the `0xDB` itself (lossless). Regression:
   `make sim-dmi-tb` (`test/Uart_DMI_Tb.bsv`).
2. A **trailing** `0xDB` (last byte on the wire) parks the bridge in its
   partial-match state until the timeout/timeout-replay — in hardware that
   release landed inside the *next* chunk (or past the boot ROM's 48 ms
   receive watchdog), deterministically wedging any chunk whose checksum
   happened to equal `0xDB` (1 in ~256). Rather than tune watchdogs against
   the bridge, the boot protocol makes the rule **"the checksum byte is
   never last"**: every chunk ends with a `0x55` pad byte, so a `0xDB`
   checksum is released by the very next byte's mismatch replay (~16 µs,
   in order) and the timeout path never runs during a load.

This gives you halt / resume / single-hart register access (abstract
commands: `x0..x31`, CSRs incl. `dpc`) and memory peek/poke over the
system bus — enough to catch a hung REPL red-handed:

```bash
# REPL is hung at the prompt after typing a command; from another shell:
python3 scripts/dmi.py -p /dev/cu.usbserial-120001 halt   # halt the hart
python3 scripts/dmi.py -p /dev/cu.usbserial-120001 pc     # dpc + disassembly
python3 scripts/dmi.py -p /dev/cu.usbserial-120001 regs   # full GPR dump
python3 scripts/dmi.py -p /dev/cu.usbserial-120001 resume
```

Only one process may hold the serial port, so close any picocom/screen
session first. `pc` resolves symbols against `templeos/build/ulx3s_repl.map`.

Note: the FT231X handshake (modem) pins are hardwired to the ECP5
**configuration** JTAG (T5/U5/R5/V4), so they cannot carry the RISC-V
debug TAP — the old `openocd/ulx3s_ft231x.ocd` FT232R-bitbang config only
ever talks to the FPGA config TAP. The J1-header soft TAP was removed in
favor of this bridge (J1 pins A10/A11/B11/C11 are free GPIO again).

## Boot loader protocol

The first-stage boot loader lives in the on-chip Boot ROM (reset PC = `0x00001000`).
It speaks a small binary protocol over UART0 (625000 baud on the ULX3S FTDI
port; `Uart_Pins` derives `clk_per_bit` from the system clock, 40 at 25 MHz):

1. Host sends 4-byte destination address (little-endian).
2. Host sends 4-byte byte count (little-endian).
3. The image bytes follow, **chunked** when the transfer is word-aligned
   (the normal case): each 256-byte chunk is framed as
   `[seq, data…, XOR, 0x55]` — `seq = chunk index & 0xFF`, `XOR` over the
   256 data bytes, and a sacrificial `0x55` pad so the checksum byte is
   never last on the wire (see the DMI-bridge `0xDB` notes below).
   Per chunk the ROM either ACKs (`0x06`) or drains the RX pipe for ~0.5 s
   and NAKs (`0x15` + an ASCII `N <seq> <xor> <flags>` diagnostic line);
   the host resends just that chunk. The seq byte anchors each chunk to its
   position in the image; the XOR catches value corruption.
4. Unaligned images fall back to a raw byte stream with a per-burst stall
   watchdog (`LOAD STALL` + drain + restart-from-header).
5. If `count == 0`, the loader jumps to the destination address without loading.
6. After loading, the ROM prints a head+tail readback of the image, waits
   ~24 s in a repair window (send `0xA5` + a fresh header to load another
   segment), then jumps to the destination.

`python3 scripts/hw_repl_test.py` is the reference host implementation
(coalesced single-write chunks, ACK-scan that skips progress dots and
diagnostic NAKs, 8 retries per chunk, reprogram-and-restart as the
bulletproof fallback). `scripts/exp_chunk2.py` is a smaller driver for
protocol experiments.

This lets you iterate on RISC-V software without rebuilding the FPGA bitstream:
a full REPL reload is ~90 s over the UART versus ~7 min for synthesis+P&R.

## Milestone LEDs

The GPIO slave at `0xC0002000` drives the LEDs. The boot loader uses them as
follows (active high):

| LED | Meaning |
|-----|---------|
| 0   | FPGA / clock alive |
| 1   | Executing boot ROM (load protocol reached) |
| 2   | UART initialized |
| 3   | SDRAM readback OK (self-test) |
| 4   | Boot loader waiting / banner printed |
| 5   | Kernel received |
| 6   | Kernel readback OK |
| 7   | Jumped to kernel (also ORed with SDRAM `init_done`) |

The boot ROM also installs a small diagnostic trap handler before jumping to the
loaded kernel. If the kernel crashes, you will see `E<mcause> <mepc> <mtval>`
instead of a silent reset, which is very useful during bring-up.

## SDRAM status

The SDRAM controller targets the on-board Winbond W9825G6KH-6 32 MB SDR SDRAM.
It runs at the system clock (25 MHz, or 32.14 MHz with `SYS_PLL=1`) with BL=8 bursts,
auto-precharge, and periodic refresh.

The controller returns 256-bit words to Flute's raw-memory port as two back-to-back
BL8 bursts. Auto-precharge is asserted only on the second burst, so the active row
stays open across both bursts of one request. Reads now drive `DQM = 2'b00` for the
full burst so read data is not masked.

Verification:
- `hello.bin` loads into SDRAM at `0x80000000` and prints ticks forever.
- `memtest.bin` writes and reads back zeros, ones, alternating, address-xor, and
  per-MB LFSR patterns across 28 MB (`0x80200000`..`0x81e00000`) over the UART
  loader, leaving the first 2 MB for the program and the last 2 MB for the stack.

In simulation the controller is exercised by the strict Verilator harnesses
(`sim/strict_bram`, `sim/ndm_bram`), which pair `sdram_model.v` (data) with
`sdram_timing_check.v`, a pin-level checker of the W9825G6KH-6 timing, init and refresh
rules. The older Bluesim testbench (`test/Sdram_Tb.bsv`) is not maintained.

## Known issues

- **Bulk image loading: SOLVED (2026-10-08).** The 2.58 MB REPL now loads
  over the FTDI UART in ~90 s with per-chunk `[seq, data, XOR, pad]`
  framing, ROM-side drain+NAK retry, and a head+tail readback verify
  (protocol above; reference host `scripts/hw_repl_test.py`). Three failure
  modes had to be fixed along the way, in order of discovery:
  - AppleUSBFTDI byte drops byte-shift all subsequent data. Fixed by
    chunking (a drop costs one 256-byte retry, not the image) plus a
    ROM-side 0.5 s RX drain before each NAK so a retry never reads a stale
    tail.
  - The UART DMI bridge dropped bare `0xDB` bytes (magic-hunt replay
    off-by-one) and parked on a trailing `0xDB`; both fixed in
    `src/Uart_DMI_Bridge.bsv` (lossless replay + partial-match idle
    timeout), and the loader's pad byte keeps a checksum `0xDB` off the
    trailing position entirely.
  - A front-inserted stray byte passes a position-independent XOR by
    construction (`[0xDB, b0..b254]` + `b255`-as-checksum) — the chunk seq
    byte catches it; a stray that lands in the seq slot is consumed there
    and the data that follows is still aligned.
  - The DMI system-bus loader (`scripts/sba_load.py`) remains available but
    is superseded: the Debug Module's AXI master corrupts ~5 ppm of 32-bit
    writes and can wedge the bridge under back-to-back traffic.

- **SDRAM read-capture phase: FIXED (2026-10-05).** Root cause was
  fabric routing skew between DQ[15:8] and DQ[7:0] making the high byte
  sample a cycle late on some placements (read back as byte1<->byte3
  swaps). Fix: pad-registered DQ input (`(* useioff *)` reg in
  `src/Top.v`) + `t_cas_first=3` in `src/Sdram_Controller.bsv`.
  Validated by the boot ROM `SELFTEST` mode (send `0xFFFFFFFF` as the
  load address; prints `DONE 00000000`) and `hello.bin` running from
  SDRAM. Logic independently proven by `test/SoC_Boot_Tb.bsv`
  (full-system Bluesim, passes end-to-end).

## Project layout

- `src/Top.v` — Verilog wrapper, optional system PLL, SDRAM clock output, pin mapping.
- `src/ULX3S_Top.bsv` — BSV FPGA top level: Flute SoC + SDRAM controller + UART + GPIO.
- `src/Sdram_Controller.bsv` — W9825G6KH SDRAM controller (256-bit raw memory port).
- `src/AXI4_GPIO.bsv` — GPIO slave for LEDs and FIRE1 button.
- `src/Uart_Pins.bsv` — 8N1 UART to physical TXD/RXD pins.
- `src/Uart_DMI_Bridge.bsv` — UART-snooping DMI transport to Flute's Debug Module (no JTAG).
- `src/Jtag_Control_Adapter.bsv` — DMI ↔ `Control_Req` conversion (shared by bridge/JTAG).
- `test/Uart_DMI_Tb.bsv` — unit test for the bridge pass-through/`0xDB` handling (`make sim-dmi-tb`).
- `boot/boot_loader.c` — first-stage UART bootloader (chunked seq+XOR+pad protocol).
- `sw/` — example RISC-V programs (`hello`, `memtest`, etc.).
- `templeos/` — HolyC bare-metal monitor and full REPL overlay for ULX3S.
- `templeos/ulx3s_repl/` — ULX3S-specific HolyC overlays for the REPL (memory map, UART, heap, FS, start).
- `scripts/loader.py` — host-side UART loader.
- `scripts/hw_repl_test.py` — end-to-end hardware test: program FPGA, chunked-load the REPL, verify readback, drive `1+1;` / `Sys;`.
- `scripts/exp_chunk2.py` — small protocol-experiment driver (per-attempt ACK/NAK logging, diagnostic-NAK capture).
- `scripts/dmi.py` — host client for the UART DMI debug bridge (halt/resume/regs/pc/mem).
- `scripts/monitor.py` — automated smoke test for the TempleOS monitor.
- `src/SoC_Info.bsv` — self-describing SoC block (device table, build date, clock, bus error monitor).
- `sim/strict_bram/`, `sim/ndm_bram/` — Verilator gate harnesses (J1, F2, ndmreset).
- `formal/` — riscv-formal wrapper and gate runner.
- `test/` — bare-metal gate tests (`cache_test`, `amo_test`, `ipc_bench`) and board scripts.
- `scripts/hw_test_suite.py` — board interface conformance suite.
- `bits/` — promoted bitstreams (rollback points).
- `AGENTS.md`, `HANDOFF.md` — working rules and the campaign history.
- `constraints/ulx3s_85f.lpf` — ULX3S-85F pin constraints.
