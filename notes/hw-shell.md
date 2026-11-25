# tools/hw: this repo's areas of the hwsh shell (board, lab, timing, place, fw, perf)

hwsh (`~/src/hwsh`, CONTRACT.md) is a shared command shell for agents: a question about the
hardware is answered by a query returning a few structured lines (or `--json`), not by reading
constraint files, maps or serial logs.  This repo owns six areas: `board` and `lab`
(`tools/hw/board.py`, `tools/hw/lab.py`), and `timing`, `place`, `fw`, `perf` (below);
`~/src/hwsh/hw <area> ...` routes to them.

## hw board (read-only)

| verb | answer | source |
|---|---|---|
| `pins [NAME \| --grep RE]` | site, IO type, pull, drive, frequency (bus `IOBUF PORT "x[*]"` rules applied to each `x[i]`) | `constraints/ulx3s_85f.lpf`, with file:line |
| `clock` | the crystal, every `SYS_PLL` option with its system clock, the default | the .lpf and the Makefile |
| `map [ADDR \| NAME]` | base, limit, size, and the `ifdef`s an entry needs (an SoC profile) | `Flute/src_Testbench/SoC/SoC_Map.bsv` |
| `periph [NAME]` | the device table SoC_Info serves (`fn_soc_memmap`): device, base, size, bus, fabric-decoded or direct, PLIC source (`irq_num_x` + 1), ifdefs | `SoC_Map.bsv`, with file:line |
| `state` | what is in flash, how a restart works, read-only devices and refused images | `tools/hw/data/ulx3s.toml` |

Facts not in the sources live in `tools/hw/data/ulx3s.toml` (public: board facts only).  A missing
fact is an error record (`HW-E-NO-FACTS`), never a guess.

## hw lab (acts on the board)

| verb | does |
|---|---|
| `restart` | JTAG refresh (`openFPGALoader -r`, ~0.3 s): the FPGA reloads flash slot 0 |
| `load BIT` | `openFPGALoader -b ulx3s -m BIT`: SRAM only; prints the md5 |
| `serial [--until RE] [--timeout S] [--send TEXT] [--restart]` | the console at `HW_BAUD` (default 1,000,000); returns the matching line and a few before it, and stores the whole capture (`raw_ref` `serial:<time>`, under `build/hw/`).  `--restart` does the JTAG refresh and opens the console right after it under one lock: the FTDI cannot hold JTAG and the tty at once, so the console opens ~0.3 s after the refresh starts and the first boot bytes (the banner) are still lost; the answer says how many ms |
| `test SUITE BIT [--pnr LOG] [--force] [--env EXPECT_X=V] [--quick]` | loads BIT to SRAM and runs `suite` (scripts/hw_test_suite.py), `cache`, `amo` or `blob --blob FILE` (T/M/D images through scripts/loader.py --no-banner right after the load); one check per test (name, expected, observed, raw_ref) recorded in `.hw/state.db` with the bit's md5/sha256.  Refuses (before the lock) a bitstream whose post-route log (`pnr-s<N>.log` beside it, or `--pnr`) shows < 10% margin on any clock or cannot be found (rule 7; `--force` overrides), and images on the `[readonly]` list (`HW-E-DENIED`).  A loader/harness failure is `HW-E-LAB-HARNESS`, not a test verdict |
| `raw serial:<time> [--from N] [--lines N]` | a bounded slice of a stored capture |
| `lock` | the shared lock's holder, and who has the console open |
| `flash`, `power-cycle` | refused: `HW-E-FLASH-DENIED` (flash and promotion are the user's decision; use `load`), `HW-E-UNSUPPORTED` (the hub port does not cut power; use `restart`) |

Every acting verb takes the machine's shared ULX3S lease lock (`~/.claude/skills/ulx3s-board`)
as `HW_HOLDER` (the session's name), refuses with `HW-E-BUSY` and the holder if it is held or if
the console is open (it never kills anything), and releases with a note of what it left on the
board.  `HW_SERIAL` names the console device; both come from the environment or
`tools/hw/local.toml` (untracked).

Status and exit codes follow the contract: `ok` 0, `fail` 1, `HW-E-BADREQ` 2, `HW-E-TIMEOUT`
and `HW-E-INTERNAL` 4, other errors 3; every answer carries `cached` (false: nothing is cached).

With `HW_PROJECT` set, every `hw lab` answer (refusals and errors included) is recorded in that
project's hw state DB (`<project>/.hw/state.db`, untracked; `~/src/hwsh/STATE.md`) through
`hwstate.record()`: area lab runs are never cached, a load records the bitstream's sha256 as its
input (so lineage reaches the run that built it) and a pass/fail check.  A recording failure is
reported on stderr and never changes the answer.

## Tests and measurement

`python3 -I tools/hw/tests/run_tests.py`: 37 checks; the board answers each have a negative
control (the same query on a copy with a moved pin or device must change), and the lab checks
are its refusals and error records (no board needed).  On the board, `restart` and `serial`
were run by hand (2026-11-25: restart 0.3 s; the flash image's SD-load progress dots captured).

One real question ("the console RX pin and its IO standard, and UART0's address"): reading the
.lpf and SoC_Map.bsv is 41,209 bytes (~10,300 tokens); two `hw board` queries are 160 bytes (~40).

`lab test` refusals (thin margin vs its +15% control, unknown margin vs `--force`, read-only image
vs a safe one) and the T/M/D and suite output parsers have negative controls there.  On the board
(2026-11-25, promoted lx49c s3, +12.7%): `test cache` PASS, `serial --restart` 275 ms.

Not done yet: other boards; a console capture that includes the boot banner (needs a second
UART path, since the FTDI serves JTAG and the console).

## hw timing / place / fw / perf (the FPGA flow and firmware)

`tools/hw/timing.py`, `place.py`, `fw.py`, `perf.py` (shared parser `pnr.py`, CSR tables `csrs.py`);
hwsh skills `fpga-timing`, `fw-query`, `perf-history`.

| area | verbs | reads |
|---|---|---|
| `timing` | `summary FILE...` (Fmax per clock vs target, margin, LUT/FF/EBR %, band over seeds), `worst`, `path tpath:ID`, `expand`, `raw pnrlog:...`, `compare A B` | nextpnr logs (`build/*/pnr-s*.log`) and `--report` JSON |
| `place` | `summary`, `modules [--depth N --under P]`, `location NAME`, `compare A B`; `congestion`/`route` refused (HW-E-UNSUPPORTED) | nextpnr `--write` JSON (`build/placediag/`) |
| `fw` | `build -- CMD` / `diags LOG` (typed gcc/as/ld/make diagnostics), `sections`, `symbols`, `disasm FUNC`, `addr PC`, `csr NAME [VALUE]` | RISC-V binutils (`HW_RISCV_PREFIX`) |
| `perf` | `record FILE...`, `seed`, `show`, `compare A B`, `history METRIC` | pnr logs + `build/bench/<build>-<bench>.log`, into `.hw/state.db` |

Rules built in: only the post-route block of a log is an Fmax (AGENTS rule 7); a log that never
routed answers `complete: false`, exit 5; a routed clock below target is `fail`, exit 1; a PASS
under 5% margin is marked `THIN`.  Parsed logs and placement tables are cached by content under
`~/.cache/hwsh/pnr/`.  Provenance stops at the generated Verilog (no bsc Verilog->BSV map yet);
`rules:` lists only `WILL_FIRE_RL_`/`CAN_FIRE_RL_` names actually on a path.
`hw perf seed` (2026-11-25) recorded every pnr and bench log on disk: 203 runs, 58 builds; seeded
runs carry the artifact's sha256 and mtime and no commit (git_rev NULL).

Every bounded answer's `next` is `--from N` on the same verb.  `fw csr` values are hex (0x optional).
`fw addr` handles inlined frames (innermost first, `inlined_into` the callers).  `perf record`
answers `ok` for a successful import; each clock's PASS/FAIL is a check on that run.

Tests: `python3 -I tools/hw/tests/run_fpga_tests.py`: 59 checks on fixtures in `tests/data`
(a tiny design routed by this nextpnr, its report JSON and placement, two bench logs), each area
with planted input changes as negative controls (incl. following every kind of `next` cursor),
plus 6 code mutants (placement estimate taken as Fmax, ld warnings as errors, perf dedupe by
content only, misa letters off by one, `--from` ignored, bare CSR values read as decimal), all caught.

One real question ("lx49c: routed sys_clk Fmax per seed, and the worst seed's critical path"):
reading the three logs is 358,190 bytes (~90,000 tokens); a careful grep + sed of the fmax lines and
the path section is 8,962 bytes (~2,200 tokens) and still shows the placement estimates beside the
routed lines; `hw timing summary build/lx49c/pnr-s*.log` + `hw timing worst build/lx49c/pnr-s7.log
--clock sys_clk` is 1,169 bytes (~300 tokens).
