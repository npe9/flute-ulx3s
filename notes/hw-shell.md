# tools/hw: the `board` and `lab` areas of the hwsh shell

hwsh (`~/src/hwsh`, CONTRACT.md) is a shared command shell for agents: a question about the
hardware is answered by a query returning a few structured lines (or `--json`), not by reading
constraint files, maps or serial logs.  This repo owns two areas, `board` and `lab`
(`tools/hw/board.py`, `tools/hw/lab.py`); `~/src/hwsh/hw board ...` routes to them.

## hw board (read-only)

| verb | answer | source |
|---|---|---|
| `pins [NAME \| --grep RE]` | site, IO type, pull, drive, frequency (bus `IOBUF PORT "x[*]"` rules applied to each `x[i]`) | `constraints/ulx3s_85f.lpf`, with file:line |
| `clock` | the crystal, every `SYS_PLL` option with its system clock, the default | the .lpf and the Makefile |
| `map [ADDR \| NAME]` | base, limit, size, and the `ifdef`s an entry needs (an SoC profile) | `Flute/src_Testbench/SoC/SoC_Map.bsv` |
| `state` | what is in flash, how a restart works, read-only devices and refused images | `tools/hw/data/ulx3s.toml` |

Facts not in the sources live in `tools/hw/data/ulx3s.toml` (public: board facts only).  A missing
fact is an error record (`HW-E-NO-FACTS`), never a guess.

## hw lab (acts on the board)

| verb | does |
|---|---|
| `restart` | JTAG refresh (`openFPGALoader -r`, ~0.3 s): the FPGA reloads flash slot 0 |
| `load BIT` | `openFPGALoader -b ulx3s -m BIT`: SRAM only; prints the md5 |
| `serial [--until RE] [--timeout S] [--send TEXT]` | the console at `HW_BAUD` (default 1,000,000); returns the matching line and a few before it, and stores the whole capture (`raw_ref` `serial:<time>`, under `build/hw/`) |
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

## Tests and measurement

`python3 -I tools/hw/tests/run_tests.py`: 19 checks; the board answers each have a negative
control (the same query on a copy with a moved pin or device must change), and the lab checks
are its refusals and error records (no board needed).  On the board, `restart` and `serial`
were run by hand (2026-11-25: restart 0.3 s; the flash image's SD-load progress dots captured).

One real question ("the console RX pin and its IO standard, and UART0's address"): reading the
.lpf and SoC_Map.bsv is 41,209 bytes (~10,300 tokens); two `hw board` queries are 160 bytes (~40).

Not done yet: `lab test` (the hardware suite as records), `serial --restart` (a capture that
starts before the restart, so the first output is not missed), `board periph`, other boards.
