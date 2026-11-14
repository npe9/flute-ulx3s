# formal/fv — formal verification kept apart from the RTL

A small framework for specifying and proving IP blocks, modelled on two baselines:

* **riscv-formal**: one config per design (`ips/<ip>/<ip>.cfg`) from which a generator
  (`bin/fvgen.py`) writes one SymbiYosys task per check, like `checks.cfg` → `genchecks.py`.
* **YosysHQ AXI4 FVIP**: protocol checkers are standalone modules on a bus's signals with a
  role parameter that says which side is the DUT (`vip/regbus/regbus_vip.sv`, `DUT_IS_DEST`):
  the same VIP asserts what the DUT owes and assumes what its environment owes.

## The separation rule

The RTL in `src/` is what the FPGA build reads, and nothing else:

1. fvgen reads the RTL **without defines** and **refuses** RTL that contains formal constructs:
   `ifdef FORMAL/RISCV_FORMAL/RVFI/SDH_FAST`, `assert/assume/cover/restrict`,
   `anyconst/anyseq`, `$past/$stable/$rose/$fell/$initstate` (`fvgen.py lint`).
2. The **environment** (`ips/<ip>/<ip>_env.sv`) only instantiates the DUT, leaves its inputs
   free, and applies one reset cycle.
3. Everything that checks is a **bound checker** (`bind <dut_module> <checker> ...`): it sees
   the DUT's ports and, by name, its internals, without the RTL exporting them.  Each bind target
   is counted (`select -assert-count 1 t:<checker>`), so a renamed module is an ERROR and never a
   silent PASS.
4. Inside the checker, **properties are stated at the ports**, against
   * a **register model** generated from the IP's register spec (`ips/<ip>/<ip>.regs`), so
     "what software last wrote" is a shadow, not an RTL register, and
   * **bus VIPs** (`vip/`): regbus, SD CMD monitor, SD read-card model, reference CRCs by
     long division (the RTL uses LFSRs, so the reference is independent).
   Software and peer devices are **assumptions at the ports** (for example, "CMD is written only
   after STATUS showed the host idle").
5. Whitebox signals appear only in the checker's **INVARIANTS** section.  They strengthen
   k-induction and claim nothing on their own: a wrong invariant fails the proof, it cannot make
   a false property pass.  fvgen enforces it: the names in a checker's `// internals` port group
   may not appear above its INVARIANTS marker, and nothing below the marker may `assume`.  A
   check that is a deliberate whitebox lemma names the internals it states properties on in the
   cfg's `whitebox =` key.
6. Observation inside an IP goes through its trace port (below), never through internal names.
7. Assumptions on a port are discharged by the check of whatever drives that port: the register
   bus rules a device check assumes (`regbus_vip`, DUT_IS_DEST=1) are asserted of the bridge,
   src/AXI4_RegBus.bsv, by ips/regbus.

## Trace ports

Every IP has a trace port, as a RISC-V core has RVFI for riscv-formal: outputs named `tr_*`,
**always present** (no ifdef; the RTL that is verified is the RTL that is built), unconnected in
the FPGA build so synthesis removes them.  A trace carries spec-level events, not internals:
what the IP says it is doing (sdh: the command accepted and its ARG, buffer words received, the
CRC verdict of a block; spdif: each subframe's sample, frame and channel status bit; audio: FIFO
pushes, pops, the sample entering the player, the words handed to the DAC).  The trace's meaning
is documented in the IP's header and is part of its specification, which is checked in two
halves:

* **the trace against the inputs and the bus**, in the IP's checker (is the claimed event right?);
* **the pins against the trace**, in a reusable VIP where the protocol allows (does the wire
  carry what the trace claims? e.g. `iec60958_mon` takes the subframes from the trace).

Proof-only state still reaches the checker by `bind`, in its INVARIANTS section (rule 5).
Flute's RVFI port predates this and stays as it is (under `RISCV_FORMAL`).

## Layout

```
bin/fvgen.py         run | mutate | regs | lint
bin/strip_formal.py  removes FORMAL/RVFI/... conditionals from RTL (keeps `else` branches)
bin/vcdrows.py       prints chosen signals of a counterexample VCD, one row per step
vip/regbus/          register-bus protocol (role parameter), outputs decoded reads and writes
vip/crc/             CRC7/CRC16 by polynomial long division
vip/sd/              sd_cmd_mon (host CMD frames), sd_rd_card (card side of a read block)
vip/i2c/             i2c_host_mon (an I2C host's wires against its command trace; the bus model)
ips/<ip>/            <ip>.cfg, <ip>.regs, <ip>_env.sv, <ip>_wb.sv (the bound checker)
```

| IP | RTL | trace port | checks | mutants |
|----|-----|------------|--------|---------|
| sdh | src/Sd_Host.v | commands accepted/refused/done, buffer words, data done + verdict | safety, frame (CMD frames = the traced command), rd (read block, 1/4-bit, any CRC), cover, rdcover | 12 (nohold, startbit: sdh_ut only) |
| spdif | src/Spdif_Tx.v | one event per subframe: channel, frame, sample, C bit | stream (trace vs inputs; OUT vs trace as IEC 60958), en, cover | 12 |
| audio | src/Audio.v | push/drop, sample time + pop/underrun, play, PCM out, DAC words | prove (registers, STATUS, FIFO order, sample clock, player, DAC, mute, pins), cover | 9 |
| board_io | src/Board_IO.v | I2C command start (flags, byte), START, STOP, read byte, write ack, done/AL, abandon | prove (registers, GPIO pins through 2 flops, magic words, SR/RXR, command acceptance, I2C wires vs trace via `i2c_host_mon`, time bounds), spec (bmc 24 with `FV_NO_INV`: the spec alone), cover | 26 (ackstuck, rxackrd: need a full read, past spec depth; prove only, ackstuck also bio_ut) |
| video | src/Video_DVI.v | RAM write lands (word, data, lanes), palette write, frame; pixel-side de/x/y/rgb (not yet specified) | prove (depth 6, RAMs as bits: registers, RAM lanes and range, palette reset and writes, FRAME vs trace, read latency 5), spec (bmc 16 with `FV_NO_INV`), cover | 6 (all also by spec) |
| regbus | src/AXI4_RegBus.bsv (bsc) | request start / zero-strobe skip (with we), done, timeout, watchdog count | prove (watchdog 7) and prove255 (the SoC's 255): AXI side via `axi4_sb_vip`, bus side via `regbus_vip` as source, requests in AXI order with lane and strobes, completion at ack or watchdog, responses in order with id, lane and SLVERR; spec (bmc 10 `FV_NO_INV`), cover | 13 (slverr, rdzero: past spec depth; prove only) |

Work trees go in `build/fv/<ip>/<check>/`.

## The config

```
[ip]
rtl     = src/Sd_Host.v                 # read with no defines, linted
top     = sdh_env
env     = ips/sdh/sdh_env.sv
fv      = vip/... ips/sdh/sdh_wb.sv     # read with the check's defines
include = vip/crc
regs    = ips/sdh/sdh.regs sdh_regs     # register spec -> generated shadow module
bsv     = src/AXI4_RegBus.bsv mkAXI4_RegBus_W   # a BSV module: bsc (make fv-bsv, SoC flags, no
bsvlib  = FIFO1.v FIFO2.v               #   formal defines) per run, mutants too; + bsc's library
taps    = dut.wb.p=dut.fifo.data1_reg   # checker port driven after flatten (inside a library
                                        #   submodule, which a bind cannot name): induction only
binds   = sdh_wb                        # every checker that must be attached
engine.<check> = smtbmc yices           # per-check engine (default smtbmc boolector)
script  = memory_map; opt_clean         # extra yosys passes after prep (video: RAMs as bits)
whitebox = ...                          # internals allowed in properties (lemma checks only)

[checks]                                # name = mode depth DEFINES...
safety  = prove 6
frame   = prove 6 CHK_FRAME

[mutants]                               # name = file :: s#regex#repl#[g] [;; ...]
[catchers]                              # simulation commands that also count as catching
```

`fvgen.py mutate <ip>` first requires every check and catcher to pass on the unmutated RTL, then
applies each mutant and requires at least one check to FAIL or end UNKNOWN, or a catcher to
fail.  A TIMEOUT or ERROR never counts as a catch.  An IP
port is complete when it catches every mutant the old harness caught.  A `bmc` check built
with `FV_NO_INV` (the checker's INVARIANTS section compiled out) shows each mutant is caught by
the specification itself and not only by a failed induction strengthening.

## Register spec

One line per field: `offset NAME bits access [reset]` (`-` for an unnamed field), access `rw`
(shadowed; reads must return it), `wo` (shadowed, write-only: `s_NAME` is what software last
wrote), `ro` (constant value), `zero` (reads 0), `vol` (hardware-owned: checked in the checker,
not modelled).  Options: `!window <address bits>`, `!decode <mask>` (the address bits the device
decodes, so offsets alias; board_io: two windows on [15:12] and registers on [4:2]),
`!unmapped zero`, `!writes full|any|lanes` (a field takes a write with all four strobes / any
strobe / the strobes of the byte lanes it occupies).  An offset `A-B` (step 4) is a range of
identical words, for `ro`, `zero` and `vol` fields only (video: the palette, the pixel RAM); the
range is excluded from `!unmapped`.

The bus VIP's latencies are parameters, `RD_LAT` and `WR_LAT` (cycles from the take to the ack,
default 1); its outputs `tk`, `pend`, `we_q`, `w` (cycles since the take) and `a_q` describe the
transfer in flight, for a checker's invariants.

## Running

```
python3 formal/fv/bin/fvgen.py run sdh               # every check
python3 formal/fv/bin/fvgen.py run sdh rd            # one
python3 formal/fv/bin/fvgen.py mutate sdh            # mutation coverage
FV_RTL_ROOT=build/fv/stage python3 ...               # against a staged RTL tree
```

Tools: the sv-yosys build (Yosys with `bind`), `FV_YOSYS_DIR`; sby and boolector on PATH.
