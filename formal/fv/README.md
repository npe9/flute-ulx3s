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
vip/spi/             spi_host_mon (an SPI host's SCK/MOSI/CS against its frame trace)
vip/axi4/            axi4_sb_vip (single-beat AXI4 rules, role parameter), axi4_sb_order (in-order scoreboard)
vip/sdram/           sdram_host_mon (an SDR SDRAM host's pins: JEDEC init, bank timing, refresh, DQ drive)
vip/uart/            uart_tx_mon (an 8N1 TXD pin against its frame trace, C clocks per bit),
                     uart_line_src (a well-formed 8N1 peer driving an RXD)
vip/jtag/            ecp5_jtagg_vip (the ECP5 configuration TAP as JTAGG presents it: IEEE 1149.1, IR 8,
                     ER1 / ER2, TCK phases >= TH / TL clocks; TMS / TDI free)
vip/trng/            ro_trng_free (stands in for src/RO_TRNG.v: the raw bit free on every clock)
vip/bsclib/          sizedfifo_inv (bsc's SizedFIFO against an fv_queue model: for INVARIANTS, by taps),
                     bram2_lowsets.v (stands in for bsc's BRAM2: only the low 2^(AW-FV_BRAM_DROP) entries
                     stored, reads elsewhere free; a sound over-approximation, exact where kept)
vip/common/          fv_queue (in-order model queue; NW: the count's width, for D > 15)
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
| spi | src/AXI4_SPI.bsv (bsc) | register write / read, TX enqueue, frame start (byte as queued) / end, RX push / pop | prove (depth 6, SCKDIV <= 1 while busy: AXI side via `axi4_sb_vip` + in-order `axi4_sb_order`, decode and DECERR, registers and reset values, TX/RX FIFO order, CS (auto / hold / default), IRQ; SCK / MOSI / CS against the traced frame via `spi_host_mon`, MISO loopback into RX), spec (bmc 8 `FV_NO_INV`), cover | 19 (7 also by spec) |
| sdram | src/Sdram_Controller.bsv (bsc, mkSdram_Controller_50) | request taken (the request), read chunk enqueued (the chunk) | prove (k-induction depth 2; power-up pause 2) and prove_real (the SoC's 10000): pins via `sdram_host_mon` (init sequence, ACT/RW/REF/MRS timing per bank, tREFI, DQ drive), first command after the pause, init bound, REF at least every 150 clocks; requests accepted below 4, taken in order after init; the fixed command schedule from each take (ACT, READ/WRITE per burst, auto-precharge on the last, write data and masks per beat); read chunks at their times with the CAS-offset samples, responses in order, never more than 8; spec (bmc 76 `FV_NO_INV`, no request before init: init and the first one or two requests), cover (5 covers by step 100, `FV_SPEC_LATE` as spec) | 18, the old 14 + 4 (16 also by spec; refresh, credit: past spec depth) |
| uart_pins | src/Uart_Pins.bsv (bsc, mkUART_Pins at 4 / 5 clocks per bit; uart_pins_real: 50, 434) | TX load (byte) / done; RX start, glitch, data sample, byte (stop high), framing error, overflow | prove and prove5 (depth 4: TX queue (16) order and put ready, a frame on TXD via `uart_tx_mon` from the clock after the load, back-to-back stop C+1, tx_busy / done; RX from the pin: the 3-clock synchronizer, start H+1 clocks after the edge (H = C/2) or a glitch, 8 data samples and the stop sample C apart, the byte LSB first, queued (16) or dropped with overflow, framing error; sticky flags; both FIFOs by `sizedfifo_inv`), spec / spec5 (bmc 48 / 56 `FV_NO_INV`), cover (6, by step 84); uart_pins_real: prove50 and prove434 (the shipped rates), line (bmc 96, RXD from `uart_line_src`: every byte arrives in order; ~2 h, not in the gate) | 30 (25 also by spec; rxovf, ovfsticky, trovf, rxdepth: 17 frames; ferrsticky: two framing errors; past spec depth) |
| uart_dmi | src/Uart_DMI_Bridge.bsv (bsc, mkUart_DMI_Bridge_P with 24 / 10-clock frame / magic timeouts; uart_dmi_real: the shipped 50 M / 500 k) | feed (byte to the console), drop, response lost, timeout, DMI done | prove (depth 4: the HUNT / MAGIC / FRAME / BUSY host protocol; console bytes, including replayed magic prefixes, in order and exactly when the console has room; drops only with the replay queue (16) full; both timeouts at the exact clock; each request on client.request as sent, one DMI in flight; each response on dbg_tx as DB, status, data big-endian; dbg_tx_pending while a response is in the serializer; progress bounds; the four SizedFIFOs by `sizedfifo_inv`), cover (5, `FV_G1`); uart_dmi_real: prove at the real timeouts.  Host assumptions: bytes >= 5 clocks apart, no byte during a DMI access, and no new frame until the previous response is out | 26, all by prove (`MUT_LIMIT=3600`: the content mutants take 15-60 min to refute; the 0xDB idle reset is an equivalent mutant, left out) |
| jtagg_dtm | src/JtaggDtm.bsv (bsc, mkJtaggDtm: the RISC-V DTM, debug spec 0.13.2, behind the ECP5 JTAGG primitive) | capture (dmi / dtmcs), shift (bit), update (register, dr), update ignored, response taken | prove (depth 4: from the JTAGG pins, free but for timing -- JTCK high >= 5 / low >= 1 clocks, JTDI held a clock past the edge: each rising edge acts 3 clocks later in the TAP state it leaves; Test-Logic-Reset, Capture-DR, Shift-DR (dmi 41 / dtmcs 32 bits), Update-DR; tdo on each falling edge in Shift-DR is bit 0 as the preceding edge left it; dmi capture {last address, last data, op = dmistat or 3 in flight}, busy capture sticky (the scan's update ignored); dtmcs version 1 / abits 7 / idle 1, dmireset / dmihardreset; one request at a time, read 10 / write 11 with arg1 address, arg2 data; the response taken the first clock without an edge, a failure sets dmistat 2), spec (bmc 40 `FV_NO_INV`), cover (5, by step 300), tap (cover 120 `FV_TAP`: an IR scan to ER1 / ER2 from `vip/jtag/ecp5_jtagg_vip`).  A 4-clock high phase fails: the falling edge would come before tdo has the shifted bit | 27, all by prove (16 also by spec) |
| entropy_ro | Flute src_Core/RegFiles/Entropy_Source.bsv (bsc, mkEntropy_Source_RO_P: the Zkr seed CSR's ring-oscillator source; a small instance 2 / 5 / 13 / 16 and the SoC's mkEntropy_Source_RO 8 / 41 / 793 / 1024) | raw bit, sample (tested), health-test failure | prove / real (depth 4, raw bit and consume free: samples are the XOR of aligned groups of 8 raw bits; SP 800-90B RCT and APT with cutoffs computed from H = 0.5, alpha = 2^-20 by ips/entropy_ro/cutoffs.py, not read from the RTL; a failure discards the partial or unread word and restarts BIST until a full clean window; WAIT / ES16 with 16 kept samples; the 4th failure without an ES16 is DEAD, sticky; seed's reserved and non-ES16 data bits 0; a consumed word never returned twice), spec (bmc 140 `FV_NO_INV`), cover (6, by step 99), per / per_real (prove `FV_PER`: raw with a period dividing 8 -- stuck, alternating -- never leaves BIST), deadby (bmc 48, small instance: such a source is DEAD by clock 4 * DEC * RCT + DEC + 1), p16 (cover: samples with period 16 reach ES16, a limit of the 90B tests).  The rings themselves: bin/ro_trng_netlist.py on the shipped netlist (8 inverter cycles 3..17, two-flop sampler, XOR, into the decimator; --selftest). Entropy (H = 0.5) is an assumption, not proved | 27, each with a counterexample (spec or a bmc / base case) |
| mmu_cache | Flute src_Core/Near_Mem_VM_WT_L1/MMU_Cache.bsv (bsc, mkMMU_Cache, D side, the SoC's 8 KB 2-way) | none (deadlock freedom only) | bounded liveness (`mmu_cache_wb.sv`): a CPU keeping the RLD-4 / E8 contract (one boot reset, kill_echo only with Stage2 empty, req the first cycle mv_busy is low, fence / sfence with Stage2 empty; addresses in cache sets 0 and 1, so the RAMs are `bram2_lowsets`) and a fair AXI4 fabric (AR / AW / W taken, R beats in order and B in AW order within L = 2); asserted: AR / AW / W held stable until taken, every request answered within K_RSP, busy below K_BUSY cycles in a row, reset / flush done within K_RST (all 96 by default), busy with no request pending and nothing on the fabric below K_IDLE = 4, a pending request with nothing on the fabric below K_WAIT = 16, R / B taken within 16 (K_R / K_B settable).  live (bmc 110, abc bmc3, 23 min, with every lemma incl. the uDTLB ones): PASS.  Reset ends near step 67 and the first request comes after it, so the 96-cycle bounds cannot trip at this depth: what it checks is K_IDLE, K_WAIT (68 + 16 < 110), the AXI rules, R / B acceptance and the lemmas on the 2-way build.  (bmc 125 no longer finishes in 2 h with the 15-deep write model: no counterexample through step 123.)  Not proved: pdr (before K_IDLE) proved 3 of 9 properties and left the rest open at 2 h; cover (yices) too slow at this size | in mmu_cache_tiny |
| mmu_cache_tiny | the same, bsvdefs = RVFI_TINY_CACHES (1 KB, 1 way, 16 sets: reset ends near step 19, first request at 21; no 2-way victim choice) | none | the same checker; reach (bmc 100 `FV_REACH`): an 8-beat refill completes at step 47; cover: reset, LD / ST / AMO answered, exception, flush by step 38 (yices, 1 h); short (bmc 80, 16 min with every lemma): PASS (K_IDLE, K_WAIT, the lemmas and the AXI rules; the 96 bounds out of reach); bound (bmc 96, K = 72): PASS, so requests launched at steps 21 and 22 are answered within 72 cycles (a bound K trips at launch + K + 1: K = 64 tripped at step 86) (a narrow window: K + 21 must fit the depth).  K = 64 fails, and the counterexample is real latency, not a hang: an AMO missing the uDTLB, walking 2 levels and refilling a line, every fabric channel at its L = 2 limit, reaches AMO_EXEC 64 cycles after req.  safe / safet (abc pdr, latency bounds off; safet with K_R = 11, K_B = 1, the limits bmc 70 finds): **proved for all depths** the AR / AW / W stability rules, K_IDLE, K_B = 1 (a B is taken the cycle it is offered), the lemma aw_n <= ctr_wr_rsps_pending (the fabric holds no more writes than the cache counts, so the 15-deep write model never overflows), and K_R = 11 through a per-state lemma (an R beat waits only in CACHE_SNAPSHOT, at most rg_snap_cnt cycles, or into CACHE_REFILL, at most 10); ar_n < 2 with its lemmas (a read is outstanding only in the 7 states awaiting R, with no AR offered or staged), and the environment's consistency (ops only while booted and not resetting; the cache out of its reset states then).  **k-induction closes the rest** (`kind`: smtbmc yices, depth 16, 3 min; `FV_ASSUME_PROVEN` turns the 15 PDR-proved properties into assumptions, so it is sound only together with them): K_WAIT = 16 (a pending request with nothing on the fabric) and every remaining lemma are **proved for all depths**.  The lemmas, each found as a counterexample to induction: the exact write count (ctr = aw_n + AWVALID + B FIFO entries); every queued AW / AR carries the current epoch; AR offered or staged only in the 7 read states, with the right burst length; R beats buffered only there; the fabric's beat counter within its burst; a working state has its request pending; the refill's words (taken + buffered + owed + an AR not yet taken = 8) and the snapshot before any word is taken; a one-beat read (PTE / IO) has exactly one beat in flight; a pending request is never in PRERESET..READY, never has kill_echo set, and its latched op / f3 / address is one the environment allows; no op staged while one is pending; rg_state <= 26; bsc's FIFO2 never empty and full (`vip/bsclib/fifo2_inv.sv`, bound into all 6); and the uDTLB keeps a request's translation (a ghost bit set at the first hit, with the cache's registered PMP equal to the fixed input, the probe's age counter, and rg_u_any captured from the current address), so a request never fills the uDTLB twice and never refills without a translation.  With the c_wait table (<= 6 before the fill, <= 12 after) this makes K_WAIT inductive.  safet on the final checker (PDR, 30 min cap) proves 65 of the 71 asserts on its own, the 15 that kind assumes among them; the 6 it leaves open (uDTLB stickiness, the probe-age capture, no second fill, the c_wait table, K_WAIT) are kind's.  `bin/pdr_status.py <task dir>` lists PDR's per-assert status.  Not proved: the latency bounds K_RSP / K_BUSY / K_RST (off in safet / kind; K_IDLE and K_WAIT rule out a stall with nothing owed, not a livelock that keeps the fabric busy).  Sanity: kind fails on rereqexit (the age lemma: CACHE_REREQ toggles rg_req_seq outside RUNNING); it passes e8b / e25, which break K_IDLE, an assumed property, and PDR refutes e8b and e25 within a minute (sanity) | 3, all by short (MUT_LIMIT 6000; the baseline is 69 min): e8b, e25 (a response hold state counted as busy, the E8b / E25 hangs) by K_IDLE; rereqexit (CACHE_REREQ never exits, a pending request stuck with nothing owed) by K_WAIT |
| icache | Flute src_Core/Near_Mem_VM_WT_L1/ICache_Pipe.bsv (bsc, mkICache_Pipe, 8 KB 2-way; icache_tiny: RVFI_TINY_CACHES, 1 KB 1-way) | none (deadlock freedom only) | bounded liveness (`icache_wb.sv`): the CPU wants a pc in cache set 0 (free priv / satp / SFENCE.VMA), resets (ndmreset) and FENCE.I at any time once booted; read-only AXI4 within L = 2, and a reset also resets the fabric (accepted bursts dropped); asserted: no writes, AR held stable, a wanted fetch presented within K_F = 96 of the last change, reset / flush within 96, nothing-owed waits below K_IDLE = 16 (a device-page fetch spends 12 cycles inside the cache: PMP replay, halt, the 3-cycle AR staging) / K_IDLE_RST (sets + 8), R taken within 8.  icache live (bmc 100, 7.7 min): PASS, the 96 bounds out of reach (reset ends ~66); tiny: reach (refill at step 37), rstmid (a reset at step 30 drops a PTE read; the fetch is answered at 53), short (bmc 60, 19 min) PASS; bound (K = 64, bmc 88): no counterexample through step 68 at the 3 h limit, so the latency bounds are not yet checked; pdr not run | 5 (tiny, all by short: rstrun = Flute 054d309 reverted, the ndmreset hang, by K_IDLE_RST; flushexit, refillexit, ioexit, needio by K_IDLE) |
| gpio | src/AXI4_GPIO.bsv (bsc) | register write, register read | prove (depth 4: AXI side via `axi4_sb_vip`, window from init, DECERR outside it or at offset >= 8, LED write (strobe 0, lane 0), LED and BTN1 read (BTN in the upper lane, sampled one clock earlier), ids, rlast, reset values; the master port never issues, irq 0), spec (bmc 10 `FV_NO_INV`), cover | 19 (all also by spec) |
| soc_info | src/SoC_Info.bsv (bsc) | register write, read address taken, read data | prove (depth 4: the register map (magic, version, features, clk_hz, memory size, the 16-entry device table), bus-error capture (first error, count saturating, BUSERR_CLEAR wins over a same-clock error), perf counters (select, clear wins, increment from the previous clock, saturation), window and DECERR, ids and lanes; BUILD_DATE as a range), spec (bmc 10 `FV_NO_INV`), cover | 30 (28 also by spec; errsat, perfsat: saturation, by induction only) |

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
                                        #   (several modules: one -g each, the env picks by define)
bsvdefs = RVFI_TINY_CACHES             # optional: extra bsc defines for this IP (make FV_BSV_DEFS)
bsvwrap = ips/uart_pins/Uart_Pins_Fv.bsv   # optional: a formal/fv package of (* synthesize *)
                                        #   instances of a parameterized src/ module (Integer
                                        #   parameters: one module per value); bsc finds the
                                        #   (possibly mutated) src/ package through FV_BSV_PATH
taps    = dut.wb.p=dut.fifo.data1_reg   # checker port driven after flatten and `script`
                                        #   (inside a library submodule, which a bind cannot
                                        #   name; a ring word: dut.f.arr[0]): induction only;
                                        #   fvgen marks each tap port keep and runs opt_clean
                                        #   first (flatten's alias wires merged)
binds   = sdh_wb                        # every checker that must be attached
engine.<check> = abc bmc3              # per-check engine (default smtbmc boolector; abc pdr /
                                        #   bmc3 for deep bmc, not for cover)
script  = memory_map; opt_clean         # extra yosys passes after prep (and flatten, with taps;
                                        #   video: RAMs as bits; sdram: FIFO rings as words)
whitebox = ...                          # internals allowed in properties (lemma checks only)
mutchecks = short                       # the checks `mutate` runs (default: all but cover)

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

Tools: the sv-yosys build (Yosys with `bind`), `FV_YOSYS_DIR`; sby and boolector on PATH.  sby
runs yosys through `bin/yosys_sby.sh`, which drops the `-fast` that sby's AIGER step (abc
engines) passes to an abc pass that no longer has it.

sv-yosys pitfalls seen in checkers: a constant table written as a function with a `case` becomes a
`$mem_v2` ROM (proc_rom) that evaluates wrongly, and nested function calls (a table lookup inside
another function, called twice in one expression) gave wrong values; write tables as a localparam
vector with a part-select, and repeated lookups as submodule instances (soc_info_r32).  `eval` is
unreliable on these netlists; use `sat -set ... -show`.  Guard invariants with `rst_n` only:
bsc's reset method leaves FIFO contents junk for a clock, so `!rst`-style guards let induction
start there.
An `if / else if` chain inside an `if` block, whose first branch holds a nested conditional
assignment to a register that the same `always` block also assigns elsewhere, synthesized wrongly
in sv-yosys (the branch's assignment was lost); stock yosys 0.51 and 0.69 get it right.  Seen in
the jtagg_dtm model (dmireset not clearing dmistat; repro: an equivalence of the nested and the
flattened model blocks).  Write models as flat guarded assignments (`if (ev && cond) r <= v;`).
A cover check whose log reaches no cover statement is reported ERROR (vacuous), not PASS.
