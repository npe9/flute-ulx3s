# Proof Obligation: the formal methods platformer (game2d)

The second game2d title (2026-11-23), next to Lantern Drift: `sw/game2d/proof.c` (engine, title,
stages, player), `proof_boss.c` (the seven bosses), `proof_sound.c` (music and effects),
`proof_int.h`.  Built by `sw/game2d/build.sh` as `proof.bin` (board, runs forever) and
`proof_f<n>.bin` (stops after n frames, for the sim), plus `build/game2d/proof_host` (the host
build against the VDP reference model).  `board.c`, `host.c` and `formal/sw/host_trace.c` choose
the title with `-DTITLE_PROOF`; Lantern Drift's compiled binary is unchanged (md5 db30082c...),
so its tier-3 proof still names it.

## The game

You are a tombstone, the end-of-proof mark.  LEFT / RIGHT run, UP jumps (hold for height), FIRE2
throws a lemma or the selected tactic, DOWN changes tactic (FIRE1 is the SoC reset).  Each stage
is a short scrolling run (pits, ledges, its own gimmick and enemies, below) into a one-screen
arena where a boss attacks with their own ideas.  Five hearts a stage; a pit costs one and puts
you back at the last safe ground you stood on (a checkpoint).  A boss has 32 hit points (a 20-cell bar); a hit is followed by
14 frames in which it cannot be hit again.  Defeat all seven ("proof obligation discharged") for
the ending.  The title screen lists the bosses (UP / DOWN, FIRE2); with no input for 20 s, and
from power-on, the game plays itself (the attract demo: a pilot that runs, jumps and throws,
visiting the bosses in turn), so the sim, the fuzzer and a passer-by reach every boss.

Six bosses are caricatures: 32x32 sprites in a 15-colour bank each, drawn feature by feature
(hair, glasses, beard, clothes) from Wikimedia Commons photographs by `sw/game2d/portraits.py`
(`python3 portraits.py --c proof_portraits.c`; `--png` previews need Pillow).  Each sprite is a
derivative of its photograph and carries that photograph's licence:

| Boss | Photograph (commons.wikimedia.org/wiki/File:...) | Author | Licence |
|---|---|---|---|
| John McCarthy | John_McCarthy_Stanford.jpg | "null0" | CC BY-SA 2.0 |
| Edsger W. Dijkstra | Edsger_Wybe_Dijkstra.jpg | Hamilton Richards | CC BY-SA 3.0 |
| Tony Hoare | Sir_Tony_Hoare_IMG_5125.jpg | Rama | CC BY-SA 2.0 fr |
| Leslie Lamport | Leslie_Lamport.jpg | Leslie Lamport | copyrighted free use |
| Andrew Appel | Andrew_Apple_(FloC_2006).jpg | Dennis Hamilton | CC BY 2.0 |
| Robert Harper | Robert_Harper_in_Tasmania.jpg | RobertWHarper | CC BY-SA 4.0 |

Adam Chlipala has no freely licensed photograph on Commons, so that boss stays the original
robed emblem figure drawn by `proof.c`.  The rest of the game is not derived from the photos.
The tone is respectful: a defeated boss gets "Q.E.D.".  Every attack's name is shown when it
starts, with one line saying what the idea is.

## Tactics (weapons), weaknesses and stages

Defeating boss b gives you their tactic, weapon b+1 (the attract demo owns all eight).  The lemma
(weapon 0) is free; every other tactic has 28 energy, refilled at each stage's start, and each
use costs its weapon's cost.  The HUD shows the selected tactic's icon (sprite 62) and an 8-level
energy gauge (sprite 63) on the hearts' line.  All tactics use the same three shot slots (sprites
12-14) as the lemma, and every shot that reaches the boss goes through the boss's own
`shot_other` and `shot_hits`, so a boss's rules about what counts as a hit (a certificate, a
shield, a phase) apply to every tactic; only the damage differs.

| # | Tactic | From | Cost | What it does |
|---|---|---|---|---|
| 0 | lemma | (start) | 0 | the original shot |
| 1 | CONS | McCarthy | 1 | a pair: the car flies up-diagonal, the cdr straight |
| 2 | PATH | Dijkstra | 2 | homes on the nearest on-screen enemy, else the boss |
| 3 | BRACES | Hoare | 4 | `{P}` and `{Q}` orbit you and erase enemy bullets they touch; FIRE again throws them |
| 4 | TICK | Lamport | 7 | stops the clock: bullets, enemies, the boss and the stage's gimmicks freeze for 40 frames (90 if it is the boss's weakness); the sky turns grey |
| 5 | CPS | Appel | 2 | a boomerang: goes out, slows, and the continuation returns to you; pierces enemies |
| 6 | TRINITY | Harper | 1 | a three-way spread |
| 7 | CRUSH | Chlipala | 3 | shockwaves both ways along the floor |

Braces erase only the bullets the engine moves (kinds 0 and 1); a boss's own objects (Harper's
shields, kinds 51/53, and the other attack props) are never erased, so no attack's rules change.

**Weaknesses** (`weakness[7]` in `proof.c`): a boss hit by their weakness takes 4 damage and is
stunned for 40 frames (the stun is only set after the boss's own `shot_hits` accepted the hit).
TICK never stuns; Lamport's weakness to it is a longer freeze (90 frames).  The cycle, and why:

| Boss | Weak to | Why |
|---|---|---|
| Hoare | PATH (Dijkstra) | *Structured Programming* (1972), the book Dijkstra, Hoare and Dahl wrote together |
| Dijkstra | TICK (Lamport) | Lamport's bakery algorithm (1974) solved Dijkstra's mutual-exclusion problem without atomic reads |
| Lamport | BRACES (Hoare) | Lamport's "The 'Hoare Logic' of Concurrent Programs" (1980) |
| Appel | CONS (McCarthy) | McCarthy invented garbage collection for Lisp; Appel's garbage-collection work builds on it |
| Harper | CPS (Appel) | Appel's SML/NJ compiler (CPS-based) implements *The Definition of Standard ML*, which Harper co-wrote |
| Chlipala | TRINITY (Harper) | Harper's type theory (computational trinitarianism) under Chlipala's dependent types |
| McCarthy | CRUSH (Chlipala) | automation (`crush`) discharges the induction McCarthy's recursion induction asks for |

After the Q.E.D. the screen says NEW TACTIC: <name> and one line on what it does, with a short
jingle; the first win in a real game adds "DOWN: CHANGE TACTIC".

**Stages.**  Each stage is generated deterministically (`build_stage`) and has its own gimmick and
enemies.  The gimmicks change map cells only on a transition (a few cells a frame, well within the
640-word flush).

| Stage | Gimmick | Enemies |
|---|---|---|
| McCarthy | allocation bridges over pits: cells appear in turn, stay, and are collected | hoppers |
| Dijkstra | conveyor belts (chevron floor) that push you | flyers |
| Hoare | null floor: looks like ground with a faint tell, and you fall through | turrets |
| Lamport | clock platforms: solid, blink, gone, on one shared clock | flyers |
| Appel | crumbling bridges: stand on one and it gives way, then is reallocated | hoppers |
| Harper | hot strips that blink and then hurt | turrets, a flyer |
| Chlipala | falling crushers and belts | walkers, chasers |

Enemies: walkers and chasers (as before), flyers (patrol and bob), hoppers (jump toward you),
turrets (fire an orb every 120 frames when near; 96 was tried and killed the pilot too often), crushers (fall, wait, rise; only a tink when
hit).  Enemies killed in a stage sometimes drop a pickup: energy (+10 to the selected tactic, or
the emptiest owned one) or a heart (up to five).  The demo pilot crosses every stage: it treats
null floor, hot strips and vanishing cells as gaps, waits for allocation and clock bridges,
waits out crushers, uses PATH on flyers, and in a fight cycles through the tactics (160 frames
each).

Resources the tactics and stages use: sprite tiles 672-767 (all 96: tactic icons, an 8-level
gauge, the energy capsule, flyer, hopper, turret, crusher, pellet, brace), BG tile 31 (the belt's
chevrons), sprite slots 62 and 63 (the HUD icon and gauge; the HUD line now has 13 of its 16
sprites), bullet kinds 90 and 91 (the energy and heart pickups, harm 0), and three new `minion`
fields (`a`, `b`, `c`) for the new enemies' state.  The checkpoint is new with this change.

## The bosses and their attacks

Each attack is one of the boss's own formal-methods ideas working as a mechanic; where the idea
is an algorithm, the game runs the real algorithm (its state is global in `proof_boss.c` --
`mc_*`, `ss_*`, `fd_*`, `ft_*`, `km_*` -- so a CBMC harness can state its theorem directly; see
Verification for what is proved so far).

| Boss | Attack | Mechanic | Source |
|---|---|---|---|
| John McCarthy | Compiler correctness | a random expression `(o1 a (o2 b c))` or `(o1 (o2 a b) c)` (o in +, *) is compiled to stack code (PUSH n, ADD, MUL) and run one instruction every 40 frames, the stack shown as digits; PUSH fires an aimed orb, an operator a pair; at the end "RUN = EVAL = v" and a fan of v orbs | McCarthy and Painter, "Correctness of a Compiler for Arithmetic Expressions", 1967 |
| | Recursion induction | F and G (two colours, mirrored) are thrown as a 2; each landing node n splits into two n-1, a 0 vanishes; the leaf counts of F and G are shown equal | "A Basis for a Mathematical Theory of Computation", 1961/63 |
| | `(AMB A B)` | two ghosts show where the boss may be; the angelic choice puts the boss at the one farther from you | ibid. |
| Edsger Dijkstra | The weakest precondition | Q (5 floor columns) is marked; wp(S, Q) -- Q moved back by the belt's shift d -- is computed and shown; S runs (the floor is a conveyor carrying you d columns), then the floor outside Q burns | *A Discipline of Programming*, 1976; "Guarded commands, nondeterminacy and formal derivation of programs", CACM 1975 |
| | Guarded commands | `if X<14 -> rain [] X>25 -> roll [] high -> aim fi`: every 70 frames a true guard is chosen nondeterministically and its action runs; if none holds the boss aborts (stunned) | ibid. |
| | A loop variant | shielded while `do ... od` runs: V starts at 9 and each turn (a volley) lowers it; shooting V lowers it too; at 0 the loop terminates and the boss is open | ibid. |
| | Self-stabilization | Dijkstra's K-state token ring (N=5, K=6) from a random state, a central daemon moving one privileged machine every 30 frames; privileged machines glow and fire; the boss is shielded while more than one is privileged; shooting a machine is a fault and the ring stabilizes again | "Self-stabilizing systems in spite of distributed control", CACM 1974 |
| Tony Hoare | `{P} C {Q}` | a zone P appears on the floor; a lemma thrown from inside P is proved to reach Q (it homes on the boss) | "An Axiomatic Basis for Computer Programming", CACM 1969 |
| | FIND | eight pillars rise in random order; Hoare's FIND places the 8th, 7th, 6th and 5th smallest one comparison every 6 frames (the pivot gold), invariant "LEFT <= A(F) <= RIGHT"; the top four become stairs | Algorithm 65, CACM 1961; "Proof of a Program: FIND", CACM 1971 |
| | CSP | P (left) does `c!v`, the boss `c?x`; when both are ready the value passes and the boss fires on it; shoot P and the boss waits for ever: deadlock (it falls, stunned) | "Communicating Sequential Processes", CACM 1978 |
| Leslie Lamport | TLA+ model checking | a breadth-first search of every reachable state from the boss, one depth layer every 5 frames, the visited states dotted; if it reaches you, "INVARIANT VIOLATED" (a hit), else "NO ERROR: n DISTINCT STATES" | TLA+ and TLC, *Specifying Systems*, 2002 |
| | Safety and liveness | safety: segments of floor warn, then burn ("nothing bad happens"); liveness: `!` tokens with a countdown -- reach each in time (the boss is hit) or "LIVENESS VIOLATED" | "Proving the Correctness of Multiprocess Programs", TSE 1977 |
| | Logical clocks | four emitters show their clocks; the least (clock, id) fires next and takes max + 1; your hit is a message, setting its clock to max + 1 | "Time, Clocks, and the Ordering of Events in a Distributed System", CACM 1978 |
| | Paxos | three acceptors light one by one; a quorum (two) decides and a rain falls; shoot two before they accept and the ballot fails (the boss is stunned) | "The Part-Time Parliament", TOCS 1998 |
| Andrew Appel | Proof-carrying code | the boss's checker rejects unproved lemmas; tombstone certificates appear, each giving your next three lemmas a proof the checker accepts | "Foundational Proof-Carrying Code", LICS 2001 (PCC: Necula and Lee) |
| | Step-indexed models | orbs carry an index 4; each bounce (a step) spends one, splitting while the index is 2 or more; at 0 the orb is gone | Appel and McAllester, "An Indexed Model of Recursive Types", TOPLAS 2001 |
| | VST: no use after free | malloc makes blocks (platforms); pointer orbs fly to an allocated block and burst there; a freed block vanishes and every pointer to it fizzles | Verified Software Toolchain, *Program Logics for Certified Compilers*, 2014 |
| Robert Harper | Progress and preservation | a large orb steps every 40 frames: it splits into two smaller ones (the same type) until each is a value (a harmless dot) | *Practical Foundations for Programming Languages*, 2012/16 |
| | LF | a derivation tree (depth 2) shields the boss; shooting a node replaces it with its premises, the leaves vanish; then "CHECKED" and the boss is open | Harper, Honsell and Plotkin, "A Framework for Defining Logics", JACM 1993 |
| | Well-typed programs do not go wrong | six `?` programs; the checker sweeps across, the ill-typed vanish, the typed show T and only they run (fire) | *The Definition of Standard ML*, 1990/97 (the slogan: Milner, 1978) |
| | Computational trinitarianism | orbs L, T, C orbit and shield the boss; hit any one and all three go, because they are the same | "The Holy Trinity", 2011 (*Existential Type*) |
| Adam Chlipala | Crush | the boss leaps toward you and slams; shockwaves run along the floor both ways | the `crush` tactic of *Certified Programming with Dependent Types*, 2013 |
| | Bedrock | three of eight floor cells are the boss's footprint (they blink), and only they erupt; outside the footprint the frame rule holds | Bedrock, PLDI 2011 (separation logic: Reynolds, O'Hearn) |
| | Fiat Cryptography | a number mod 99999 in five decimal limbs; digits are added to limb 0, each carry is a drop, the top carry wraps to limb 0 (10^5 = 1 mod p); "LIMBS = SPEC, MOD 99999" | Erbsen et al., "Simple High-Level Code for Cryptographic Arithmetic", S&P 2019 |
| | Kami | the boss (the spec) fires aimed shots and pushes each velocity into a 3-stage pipeline; the pipeline fires the same shots three stages later from the left | Choi et al., "Kami: A Platform for High-Level Parametric Hardware Specification and its Modular Verification", ICFP 2017 |

## The machine budget

- Each frame first flushes the previous frame's shadow state (palette, sprite table, scroll,
  changed map words, at most 640 a frame), then simulates, so every VDP write lands in the
  vertical blank (42 lines, about 67,000 CPU clocks at 50 MHz).
- Host build, 30,000 demo frames: VDP writes a frame mean 4, worst 414 (a stage's first map);
  APU worst 6 (before the tactics: worst 449 and 9); no frame has a sprite overflow (`HOST_OVERFLOW=1`; `=2` prints the frame and line
  of each).  The 16-sprites-a-line limit shaped the design: bullets buried in the ground are not
  drawn (they would share the HUD's lines, now 13 sprites with the tactic icon and gauge), spawned volleys start above the figures,
  and every move was run with `HOST_OVERFLOW=2` (Verification).
- CPU time a frame on the strict sim (50 MHz SoC, a frame is 840,000 cycles): over the first 120
  frames (the title's init, then the demo's first stage run) mean 17,105 cycles, worst 186,428
  (frame 0, which draws every tile and sprite).  No boss fight has run on the RTL, so the fights'
  costliest frames (Lamport's breadth-first layer, full bullet tables) are not yet measured in
  cycles.

## Verification

The game's rules are written as a specification in `notes/proof-obligation-spec.md` (and
`sw/game2d/proof_spec.c`); that document says, clause by clause, what is proved and what is tested.

What is proved and what is only tested, separately (notes/sw-verification-plan.md has the tiers).

- **Tier 2, proved (CBMC, `formal/sw/cbmc/run_proof.sh`, harness `proof_algos.c`):** theorems
  about the boss algorithms, compiled from `proof_boss.c` itself (the harness `#include`s it), each
  over every input in its domain, with bounds, pointer, overflow and unwinding checks, and a
  vacuity run showing its assumptions are satisfiable:
  - COMPILER (McCarthy-Painter): for every expression of the game's two shapes, operators + and
    *, digit operands 1..9 (the game draws 1..3), the compiled stack code runs five instructions,
    never overflows the 3-deep stack, and leaves exactly one value, equal to the expression's
    meaning.
  - KSTATE_LIVE / CLOSED / CONVERGE (Dijkstra's K-state ring, N = 5, K = 6): every state has a
    privileged machine; a single privilege stays single after its move; from every state, under
    every central-daemon schedule, at most 24 moves reach a single privilege (24 is the exact worst
    case, found by an exhaustive search in `build/swfv/bounds`).  Together: from any state the ring
    stabilizes and stays stable.
  - FIND (Hoare), by exhaustive enumeration (`find_exhaustive.c`, the game's own `fd_step`
    built with ASan/UBSan): for every array of 8 elements and every f, FIND terminates within 75
    steps (the exact worst case), never indexes outside the array, permutes it, and leaves
    A[0..f-1] <= A[f] <= A[f+1..7].  It runs all 8^8 rank arrays (ties allowed) x 8 values of f,
    134,217,728 runs in 24 s.  FIND only compares elements, so its run on any int array is its run
    on the array of the elements' ranks; that step of the argument is by hand.  (CBMC on 8 symbolic
    elements and 75 unrolled steps did not finish in 5 hours.)
  - FIAT: "the limbs equal the spec modulo 99999" is preserved by an addition (1..9) and by a
    carry, for limbs 0..99 and any reduced spec: an inductive step.  It holds initially (the game
    sets the spec from the limbs), so it holds in every reachable state where the limbs stay
    within 0..99 (that bound is assumed, not proved).
  - KAMI: "the pipeline holds the spec's last three inputs" is inductive over `km_step`, so every
    output equals the spec's input three steps earlier, for runs of any length (the empty pipeline
    satisfies it).
  - Planted bugs: `run_proof_mutants.sh` makes five one-line mutants (operator order, the K-state
    copy rule, FIND's scan, the carry, the pipeline shift); each must fail its theorem.
- **Not proved:** the game engine's properties (no undefined behaviour over a whole frame, only
  real device registers, at most 16 sprites a line, the per-frame write bound), the other attacks
  (Paxos here is a vote count, not the protocol, and claims nothing), and anything about the
  binary (tier 3).  These are tested:
- Host: built with `-Wall -Wextra -fsanitize=address,undefined`, 30,000 demo frames clean; and
  every boss move driven directly (`-DPROOF_TEST`, a host-only hook:
  `PROOF_TEST=<boss>,<move>[,<weapon>]` starts the pilot in that arena, invulnerable, the fight
  opening on that move, firing that tactic): every move x all 8 tactics, 200 runs x 2,400 frames
  with `HOST_OVERFLOW=2`, no sanitizer report, no sprite overflow, no text line the font cannot
  draw.  Contact sheets of every move were looked at (frames 80, 200, 320, 500 of each), and of
  each stage and each tactic in use.  `PROOF_STAGE=<boss>` starts the demo at that stage (damage
  on) and `PROOF_TRACE=1` prints state changes: the pilot reaches all seven arenas.  The tactics,
  weaknesses, stage gimmicks and enemies are tested only, not proved.
- Tier 1 (`TITLE=proof formal/sw/fuzz.sh 8 3000 7`): `proof.elf` on the Sail RV32 model with the
  SoC's devices, random buttons, half the runs with random UART / frame timing: S1 (no trap, only
  real device registers, word accesses) and S2 (its device-write trace equals the host build's)
  hold for 8 runs x 3,000 frames.  Tested, not proved.
- The strict-BRAM sim frame check (`TITLE=proof FRAMES=120 sim/game2d/frame_check.sh
  build/game2d`, the game2d+VDP+APU netlist): PASS -- the 640x480 scan-out identical to the
  reference model's frame, the APU samples equal, its 624 writes = the host build's.  120 frames
  cover the init and the opening of the first stage only.
- On the board: not yet run (the game2d SoC's timing is open).

## Status

Playable on the host build and the strict sim; not yet run on the board, because the game2d
SoC's timing is still open (`notes/soc-family-plan.md`, game2d status).  The attract pilot
cannot reach Dijkstra (who hovers level with the high platforms), so in the demo that fight
mostly times out; a player can reach it.  The pilot crosses every stage but loses most fights
(it wins Harper's and Chlipala's, and McCarthy's sometimes, in 40,000 demo frames); a fight it
loses or times out moves the demo on to the next stage, so it still visits every boss.
