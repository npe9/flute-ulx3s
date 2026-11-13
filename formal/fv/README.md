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
6. A sub-block's own interface may be used as an observation point and is then declared as such
   in the checker's port list (audio: the S/PDIF instance's sample inputs, the DAC's input word):
   the sub-block is proved on its own ports by its own check.
7. Assumptions on a port are discharged by the check of whatever drives that port: the register
   bus rules a device check assumes (`regbus_vip`, DUT_IS_DEST=1) are asserted of the bridge,
   src/AXI4_RegBus.bsv, by formal/regbus.

**Exception: RVFI.**  riscv-formal checks a core through its RVFI trace port, which the core has
to emit.  Flute's `RISCV_FORMAL` RVFI port is the one formal hook allowed to stay in RTL; it is
an output-only trace and changes nothing when the define is off.

## Layout

```
bin/fvgen.py         run | mutate | regs | lint
bin/strip_formal.py  removes FORMAL/RVFI/... conditionals from RTL (keeps `else` branches)
bin/vcdrows.py       prints chosen signals of a counterexample VCD, one row per step
vip/regbus/          register-bus protocol (role parameter), outputs decoded reads and writes
vip/crc/             CRC7/CRC16 by polynomial long division
vip/sd/              sd_cmd_mon (host CMD frames), sd_rd_card (card side of a read block)
ips/<ip>/            <ip>.cfg, <ip>.regs, <ip>_env.sv, <ip>_wb.sv (the bound checker)
```

| IP | RTL | checks | mutants |
|----|-----|--------|---------|
| sdh | src/Sd_Host.v | safety, frame (CMD frames), rd (read block, 1/4-bit, any CRC), cover, rdcover | 12 (2 by sdh_ut only: nohold, startbit) |
| spdif | src/Spdif_Tx.v | stream (IEC 60958 by k-induction), en, cover | 12 |
| audio | src/Audio.v | prove (bus, registers, FIFO order, sample clock, DAC error bound, mute, pins), cover | 9 |

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
binds   = sdh_wb                        # every checker that must be attached
engine.<check> = smtbmc yices           # per-check engine (default smtbmc boolector)
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
port is complete when it catches every mutant the old harness caught.

## Register spec

One line per field: `offset NAME bits access [reset]` (`-` for an unnamed field), access `rw`
(shadowed; reads must return it), `ro` (constant value), `zero` (reads 0), `vol` (hardware-owned:
not modelled).  Options: `!window <address bits>`,
`!unmapped zero`, `!writes full` (only full-strobe writes take effect).

## Running

```
python3 formal/fv/bin/fvgen.py run sdh               # every check
python3 formal/fv/bin/fvgen.py run sdh rd            # one
python3 formal/fv/bin/fvgen.py mutate sdh            # mutation coverage
FV_RTL_ROOT=build/fv/stage python3 ...               # against a staged RTL tree
```

Tools: the sv-yosys build (Yosys with `bind`), `FV_YOSYS_DIR`; sby and boolector on PATH.
