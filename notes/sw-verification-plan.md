# Software verification plan (game2d software)

Goal: the software running on the SoC is correct, by the method of Anthropic's "LLMs are making
formal software verification feasible at a much larger scale" (anthropic.com/research/
formal-verification, 2026-10-22): **an existing test becomes the specification** ("this test
always passes", quantified over every input), and the proof is about the **compiled RISC-V
binary** against a formal ISA semantics, checked by a proof assistant.  Here the ISA semantics
is the RISC-V community's Sail model (`~/src/sail-riscv`, the same model testrig locksteps the
RTL against), and the environment is the SoC's devices as seen through their register specs.

## Scope

In: the game2d title binary `sw/game2d/lantern.bin` and everything linked into it --
`test/bench/bench_rt.c` (start-up, UART, timers), `sw/game2d/board.c` (the hw.h drivers),
`lantern.c`, `sound.c`, libgcc.  Out (stated, not implied): TempleOS, Linux, the boot ROM and
loader (candidates for later), the host build (`host.c`; it is the specification's executable
form, not a verification target).

## The specifications (from the existing tests)

The existing test is `sim/game2d/frame_check.sh`: for one input (no buttons) the SoC's screen and
APU writes equal the host build's.  Generalised over every input -- every button sequence, and
every value a device register read may return where the device spec allows it:

- **S1 no trap.**  Fetches stay in `.text`; every load and store is aligned and hits RAM, the
  stack, or a mapped SoC window (profiles/game2d.mk's map); the stack pointer stays in the stack;
  no store to `.text`; no illegal instruction, no ecall/ebreak.  (The blog's "the fuzz test won't
  crash", with an explicit memory map instead of ASan.)
- **S2 refinement.**  The binary's device-write trace (address, data, in order, with frame
  boundaries) equals the host build's for the same button sequence.  The host build is C
  compiled for the host: so S2 says the compiled RISC-V program refines its C source, as far as
  anything observable is concerned.  UART output is excluded (it prints cycle counts).
- **S3 device contracts.**  What each hardware spec assumes of software, discharged here:
  APU: voice registers written before KEYON (sw/apu/apu.h), writes word-sized; VDP: sprite and
  map indices in range, writes word-sized; Audio: VOLUME set before expecting sound.
- **S4 per-frame bound.**  One `lantern_frame` makes a bounded number of device writes and
  terminates (a bound on loops; later a cycle bound against the 840,000-cycle frame).

## Three tiers (in this order)

1. **Fuzzing on Sail (tested, not proved).**  A patched copy of the Sail emulator
   (`formal/sw/sail/soc-mmio.patch`, applied to a `git clone --shared` under `build/`, as
   testrig does; `~/src/sail-riscv` is not edited): the SoC windows dispatch word accesses to C
   callbacks (`formal/sw/sail/socdev.c`), which model the devices as an environment -- buttons
   from a fuzz script, the frame counter, IDs, UART ready -- and log every device write; a hook
   in the trap handler reports any trap (S1).  `formal/sw/fuzz.sh` runs random button scripts on
   Sail and on the host build and compares traces (S2).  Also validates the environment model
   that tiers 2 and 3 assume.
2. **C-level proof (CBMC, all inputs, source level).**  An inductive harness: assume a
   game-state invariant, run one `lantern_frame` with nondeterministic buttons, assert the
   invariant again, no undefined behaviour (overflow, bounds, shifts), every write address in
   its window, S3, and the write-count bound (S4).  Proves S1-S4 for the C program; the gap to
   the binary is the compiler (closed by tier 3, tested by tier 1).
3. **Binary-level proof on Sail (Rocq).**  Sail generates Rocq definitions of RV32IMAC; the proof
   is about `lantern.bin`'s instructions.  First a time-boxed spike: can the installed `sail`
   regenerate a Rocq model that the installed Rocq (9.0) checks, and step one instruction of
   the binary?  (The 2024 snapshot in `prover_snapshots/coq` targets Coq 8.13 + bbv: regenerate,
   do not port by hand.)  If yes: S1 for leaf routines (the hw.h drivers, `note_pitch`), then
   composed.  If no: tier 3 stays open and is recorded so; tier 1 is never relabelled as proof.

Each tier gets planted software bugs (an out-of-window write, an off-by-one sprite index, a
KEYON before its voice's registers, a host/target divergence) and must catch them.

## Assurance map (the chain from the C source to the pins)

| Link | Status |
|---|---|
| C program satisfies S1, S3, S4, no UB, for every button sequence, forever | **proved** (tier 2, CBMC induction; the hw.h boundary is assumed to be the device spec) |
| RISC-V binary refines the C program (S2) | **tested** (tier 1: 400,000 fuzzed frames, half with random device timing); tier 3 proof open |
| binary on the Sail ISA model is S1 (device side) | **tested** (tier 1); **proved for hw_palette** (tier 3, Rocq; data and return address concrete); the rest open |
| binary: fetch stays in .text, sp in the stack, no store to .text | **not checked** at the binary level (the C-level bounds / pointer proof covers the source; the compiler is trusted here) |
| Flute CPU implements the ISA, per instruction | riscv-formal (proved, bounded per check) against riscv-formal's own ISA spec |
| riscv-formal's ISA spec agrees with Sail | **tested only** (testrig: Sail vs Flute lockstep) |
| devices meet their register specs | formal/fv/ips/{vdp,apu,video,audio} (proved; memories bounded) + sim benches vs C models |
| the device environment model (socdev.c) agrees with the devices | tested: frame_check (one input) |
| whole SoC runs the binary as Sail does | tested: frame_check, the strict sim |

## Status

Tiers 1 and 2 are done; tier 3 has its model, program logic and first theorem (below).

**Tier 1, done (2026-11-23).**  `formal/sw/sail/soc-mmio.patch` (on sail-riscv af5c2f2, testrig's
commit, in a shared clone at `build/sail-soc`): word accesses in 0xC0000000-0xC1FFFFFF go to
`formal/sw/sail/socdev.c`, every trap to `soc_trap`, and a program without an HTIF `tohost`
symbol runs (the port is parked at 0xBFFFFFF0, outside the map).  The binary is unchanged: the
board's own `lantern.elf` (since 2026-11-23; before, the `lantern_f<n>.elf` variant), stopped by
socdev after n frames (`SOC_FRAMES`); fuzz.sh prints its md5, the same file tier 3 proves about.  `formal/sw/fuzz.sh [runs] [frames] [seed]`:
2,000 frames take ~4 s on Sail.  Results:
- 40 frames, no buttons: Sail's trace = the host build's (4,585 writes).
- Campaigns of 200 runs x 2,000 frames: PASS, ~116,750 writes a run (seed 7 on the source before
  tier 2's fixes, seed 11 after; half the runs with random UART / frame-counter timing).  Line
  coverage of the host build over three scripts: lantern.c 100% of 184 lines, 97% of 196 branch
  directions; sound.c 100% / 96%.  Never taken: a game over in attract mode, all 12 logs on at
  once, `if (on)` false (every music step keys a voice).
- Rerun from a clean tree on `lantern.elf` (md5 db30082c..., 2026-11-23): 20 x 2,000 frames
  seed 13 PASS, mutants 8/8, CBMC base / step / vacuity PASS, CBMC mutants 8/8, Rocq all checked.
- `formal/sw/mutants.sh`: 8 planted bugs, all caught -- 5 by S1 (one past the sprite table at
  start-up and, deep, only at a game over; a wrong button register; halfword VDP writes; a write
  to the APU's read-only ENV), 3 by S2 (plain `char` signedness, RISC-V unsigned vs the host's
  signed; a target-only change, what a miscompilation looks like; input depending on the frame
  counter).

**Tier 2, done (2026-11-23).**  `formal/sw/cbmc/run.sh` (CBMC 6.11, ~10 s each; the target's
data model, `--ILP32 --unsigned-char --little-endian`, not the host's): the base case
(`lantern_init` establishes INV) and the inductive step (INV, any buttons, one `lantern_frame`,
INV again) pass with bounds, pointer, signed-overflow, shift and division checks and unwinding
assertions; S1 at the hw.h calls, S3 (KEYON only for voices whose MODE / PITCH / VOL / ADSR, and
for a sample START / END / LOOP, were written; never an unconfigured voice), S4 (at most 75 device
writes a frame).  A vacuity check proves INV satisfiable.  INV: the boat in the river, lives
0-3 with game over exactly at 0, hurt 0-90, idle 0-600, the score a multiple of 10 up to the
cap, each live log / firefly in its spawn range with a firefly's drift bounded by its distance
fallen, the music's state, and which APU registers were written.
**It found three real bugs** (fixed in the same change): `t` (lantern.c) and `frame` (sound.c)
were `int` counters incremented every frame -- undefined behaviour after 2^31 frames (~414 days
at 60 Hz), and on RISC-V they wrap negative, so `sound_frame` would index its note tables with
negative indices (reads outside the arrays); and `score += 10` could overflow.  Now unsigned
counters and a score capped at the six digits shown (999,990); no observable change before
those limits.  `formal/sw/cbmc/mutants.sh`: 8 planted bugs, all caught, three in states the
fuzzer never reached (every log on; a second crash in the hurt time; KEYON before its PITCH).

**Tier 3, started (2026-11-23).**  The spike's question -- can the installed tools turn Sail RV32
into Rocq that Rocq 9 checks, and reason about `lantern.elf`'s instructions? -- is answered yes.
`formal/sw/rocq/build.sh` (opam switch omp-rocq-9.0: rocq 9.0, sail 0.20.2, coq-sail-stdpp
0.20.2, coq-stdpp 1.12; ~1 min model build, 48 s when cached):
- Model: sail-riscv af5c2f2 + `formal/sw/rocq/soc-coq.patch` (a stale termination measure
  fixed; the platform functions bound to `support/riscv_extras.v`'s values from the SoC map;
  the device window in `within_phys_mem`, so device accesses are memory events) +
  `support/` (sail-riscv's hand-written Rocq support rewritten for coq-sail-stdpp: its
  originals target the old bbv prompt monad).  No hand port of the 2024 snapshot.  Each
  instruction is a free-monad tree of interface events (`execute`, `encdec_backwards`,
  `encdec_compressed_backwards`); 78 axioms remain (floating point, LR/SC reservations, the
  unused prompt-monad memory hooks).
- Program logic: `formal/sw/rocq/Run.v` -- `run` interprets an event tree against a register
  file and an arbitrary memory / device environment and logs memory writes (a Sail exception,
  failure or nondeterministic choice is None; a trap is not an event in this model but register
  writes ending in RETIRE_FAIL, which `step` rejects); `step` mirrors riscv_step.sail on the no-trap path
  (fetch, decode, nextPC, execute, RETIRE_SUCCESS, PC); `steps`.  `step` is hand-written: part
  of the trusted base, with the theorem statements, coq-sail, sail's Rocq backend and Rocq.
- `formal/sw/rocq/gen_code.py` writes `Code.v` from the ELF's bytes (with its md5), so the
  theorem is about the binary, not a transcription.
- **`Palette.v`, proved:** for every index 0..255, in any machine state and any environment,
  the compiled `hw_palette` (lui / addi / c.add / c.slli / c.sw / c.jr; it reaches the window
  only modulo 2^32) retires on Sail without a trap, makes exactly one 4-byte write at
  0xC0010400 + 4 * index of a1, and returns to ra.  Fixed in the statement: privilege M with
  mstatus 0x1800 (MPRV clear), the 8 PMP entries off (reset; the title never writes them),
  a1 = 0x00ABCDEF, ra = 0x80001000; the model is configured as Flute (RV32IMAC+F, 8 PMP entries,
  grain 10).  `Mutants.v`: four wrong
  binaries (shift 1, one entry off, no store, an illegal instruction) fail the same check.
- Why the fixed values: the proof is by computation (vm_compute).  With mstatus symbolic the
  MPRV branch normalises the whole address-translation path; with a1 or ra symbolic the store's
  byte packing / the jump's alignment check branch, and with a trap on a branch the whole trap
  handler is normalised over symbolic CSRs (a model trap is register writes, not an event):
  minutes, then a stack overflow.  Next: symbolic execution that prunes with hypotheses
  (stepwise `cbn` + rewriting, or coq-sail's `Hoare.v`), then the other drivers (`hw_vdp_write`,
  `hw_apu_write`, `hw_buttons`, already in Code.v), then `lantern_frame` against tier 2's
  invariant.

Not covered by tiers 1-3: `bench_rt.c`'s start-up and printf (run by tier 1, not proved);
board.c's main loop (tier 1 only); the binary-level memory map (above); time per frame.
