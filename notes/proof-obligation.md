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
throws a lemma (FIRE1 is the SoC reset).  Each stage is a short scrolling run (pits, ledges,
walking counterexamples) into a one-screen arena where a boss attacks with their own ideas.  Five
hearts a stage; a pit costs one.  A boss has 32 hit points (a 20-cell bar); a hit is followed by
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

## The fight structure

A fight borrows its shape from bullet-hell and run-and-gun boss design: mechanics only, with no
characters, art, music or attack patterns taken from any game.  Every mechanic is tied to the
boss's idea, and the arena says which idea it is.

- **Intro:** for 60 frames the boss bar fills from empty, with a tick sound, before the first move.
- **Moves:** each boss has 3 or 4 regular moves, which they cycle through, plus one last move.  A
  move's name is shown on arena row 3 when it starts, with a one-line explanation on row 5.
- **Pinch:** at half HP (16 or less), the boss's update runs 5 times every 4 frames.  Every
  timer value is still visited, so no attack is skipped.  A cue line on row 2 names the pinch in
  the boss's terms, e.g. "PINCH: THE LOGICAL CLOCKS RUN FAST".
- **The last lemma:** at a quarter HP (8 or less), "THE LAST LEMMA" is announced and the boss
  plays one new signature move built from their idea.  From then on it alternates with the
  regular moves.
- **Telegraphs:** the big attacks are announced 20-40 frames ahead by a blinking `!` ring, blinking
  tiles or a note.
- **Clean proof:** a move survived without a hit gives +500 and "CLEAN PROOF +500" on row 7,
  followed by 50 frames of rest.  It is scored by `boss_move_end()`, which `next_move` calls.
- **Bullet modes** (palette banks 14 and 15):
  - **BLUE** hurts only if you moved this frame: a safety property is kept by doing nothing.
  - **ORANGE** hurts only if you stood still: a liveness property needs progress.
  - **PINK** is a proved shot.  Touch it in the air with UP newly pressed (an 8-frame window) to
    parry it.  It breaks, you bounce up and you gain a proof certificate, the same certificate as
    Appel's tombstones (proof-carrying code: the proof travels with the shot).  Otherwise it hurts.
  - A certificate also lets a lemma pierce a shield.

The last lemmas:

| Boss | The last lemma | Mechanic | Source |
|---|---|---|---|
| John McCarthy | EVAL AND APPLY | `(FACT 3)` is traced through the interpreter's two mutually recursive halves, EVAL (left) and APPLY (right).  Each pass between them is a ball labelled with its argument or value, flying on a lane one level lower for each deeper call.  Each ball is telegraphed at its station (a paren) 24 frames ahead, with notes such as "DEPTH 2: APPLY FACT TO 1".  The returns carry the values back up; the last one, the answer, is pink; "(FACT 3) = 6: EVAL AND APPLY AGREE" | McCarthy, "Recursive Functions of Symbolic Expressions and Their Computation by Machine, Part I", CACM 1960 (the eval/apply of the LISP 1.5 manual) |
| Edsger Dijkstra | The dining philosophers | five philosophers and five forks; every 24 frames each in turn (random order) may get hungry, take the left fork, then the right, eat (a telegraphed volley) and put both down.  If all hold their left fork, the deadlock stuns the boss.  Shooting a philosopher schedules them (THINK becomes HUNGRY) or pre-empts them (a waiting LEFT holder is delayed) | Dijkstra, "Hierarchical Ordering of Sequential Processes", Acta Informatica 1971 (EWD310) |
| Tony Hoare | Monitors | a bounded buffer of 4 slots guarded by a monitor.  The producer (the boss) appends: an aimed shot.  When the buffer is full, it waits on NONFULL (the boss stalls).  The consumer (a turret) removes: a 3-shot volley.  When it is empty, it waits on NONEMPTY.  One process at a time is inside (shown); the other queues at the entry.  Shooting the turret makes the consumer busy, so the buffer fills | Hoare, "Monitors: An Operating System Structuring Concept", CACM 1974 |
| Leslie Lamport | The Byzantine generals, OM(1) | the commander (the boss) sends LEFT or RIGHT to three lieutenants.  Each relays what it heard to the other two, one of them a traitor who relays the opposite, and each decides by majority.  Then all attack along the floor: arrows hover 30 frames (the telegraph), then fly.  The traitor's arrows point the loyal way and fly the other.  Shoot the traitor: damage and stun | Lamport, Shostak and Pease, "The Byzantine Generals Problem", TOPLAS 1982 |
| Andrew Appel | Tail calls on a trampoline | `EVEN?(n)` calls `ODD?(n-1)` calls `EVEN?(n-2)`.  Each call is a bounce of the ball on a trampoline at the floor's centre, and the stack stays one frame deep.  At 0 the answer bursts into a fan, pink if TRUE.  The trampoline throws you too | Appel, *Compiling with Continuations*, 1992; Tarditi, Lee and Acharya, "No Assembly Required: Compiling Standard ML to C", LOPLAS 1992 (the trampoline) |
| Robert Harper | Focusing: a shift flips polarity | positive (+) orbs fall, negative (-) orbs rise.  Every 150 frames a shift flips every polarity on the screen, telegraphed by 30 frames of the tiles blinking | Andreoli, "Logic Programming with Focusing Proofs in Linear Logic", 1992; Zeilberger, "On the Unity of Duality", APAL 2008 (polarity, as taught in Harper's course) |
| Adam Chlipala | Proof by reflection | a mirror in front of the boss.  An unproved lemma that hits it comes back pink (parry it for a certificate).  A lemma that carries a proof is checked and passes.  The mirror blinks, then drops for 70 of every 270 frames ("THE TACTIC RUNS") | Boutin, "Using Reflection to Build Efficient and Certified Decision Procedures", TACS 1997; *Certified Programming with Dependent Types*, ch. "Proof by Reflection" |

## The bosses and their attacks

Each attack is one of the boss's own formal-methods ideas working as a mechanic.  Where the idea
is an algorithm, the game runs the real algorithm.  Its state is global in `proof_boss.c`
(`mc_*`, `ss_*`, `fd_*`, `ft_*`, `km_*`, `px_*`), so a CBMC harness can state its theorem
directly.  See Verification for what is proved so far.

| Boss | Attack | Mechanic | Source |
|---|---|---|---|
| John McCarthy | Compiler correctness | a random expression `(o1 a (o2 b c))` or `(o1 (o2 a b) c)` (o in +, *) is compiled to stack code (PUSH n, ADD, MUL) and run one instruction every 40 frames, the stack shown as digits; PUSH fires an aimed orb, an operator a pair; at the end "RUN = EVAL = v" and a fan of v orbs (telegraphed; its middle orb is pink) | McCarthy and Painter, "Correctness of a Compiler for Arithmetic Expressions", 1967 |
| | Recursion induction | F and G (two colours, mirrored) are thrown as a 2; each landing node n splits into two n-1, a 0 vanishes; the leaf counts of F and G are shown equal | "A Basis for a Mathematical Theory of Computation", 1961/63 |
| | `(AMB A B)` | two ghosts show where the boss may be; the angelic choice puts the boss at the one farther from you | ibid. |
| Edsger Dijkstra | The weakest precondition | Q (5 floor columns) is marked; wp(S, Q) -- Q moved back by the belt's shift d -- is computed and shown; S runs (the floor is a conveyor carrying you d columns), then the floor outside Q burns | *A Discipline of Programming*, 1976; "Guarded commands, nondeterminacy and formal derivation of programs", CACM 1975 |
| | Guarded commands | `if X<14 -> rain [] X>25 -> roll [] high -> aim fi`: every 70 frames a true guard is chosen nondeterministically and its action runs; if none holds the boss aborts (stunned) | ibid. |
| | A loop variant | shielded while `do ... od` runs: V starts at 9 and each turn (a volley) lowers it; shooting V lowers it too; at 0 the loop terminates and the boss is open | ibid. |
| | Self-stabilization | Dijkstra's K-state token ring (N=5, K=6) from a random state, a central daemon moving one privileged machine every 30 frames; privileged machines glow and fire; the boss is shielded while more than one is privileged; shooting a machine is a fault and the ring stabilizes again | "Self-stabilizing systems in spite of distributed control", CACM 1974 |
| Tony Hoare | `{P} C {Q}` | a zone P appears on the floor; a lemma thrown from inside P is proved to reach Q (it homes on the boss); every third aimed shot is pink (a proved shot: parry it) | "An Axiomatic Basis for Computer Programming", CACM 1969 |
| | FIND | eight pillars rise in random order; Hoare's FIND places the 8th, 7th, 6th and 5th smallest one comparison every 6 frames (the pivot gold), invariant "LEFT <= A(F) <= RIGHT"; the top four become stairs | Algorithm 65, CACM 1961; "Proof of a Program: FIND", CACM 1971 |
| | CSP | P (left) does `c!v`, the boss `c?x`; when both are ready the value passes and the boss fires on it; shoot P and the boss waits for ever: deadlock (it falls, stunned) | "Communicating Sequential Processes", CACM 1978 |
| Leslie Lamport | TLA+ model checking | a breadth-first search of every reachable state from the boss, one depth layer every 5 frames, the visited states dotted; if it reaches you, "INVARIANT VIOLATED" (a hit), else "NO ERROR: n DISTINCT STATES" | TLA+ and TLC, *Specifying Systems*, 2002 |
| | Safety and liveness | safety ("nothing bad happens"): three BLUE walls sweep the arena, telegraphed 30 frames ahead; standing still is always safe.  Liveness ("something good happens"): ORANGE sweeps, which hurt whoever stands still, and `!` tokens with a countdown.  Reach each token in time (the boss is hit) or "LIVENESS VIOLATED" | "Proving the Correctness of Multiprocess Programs", TSE 1977 |
| | Logical clocks | four emitters show their clocks; the least (clock, id) fires next and takes max + 1; your hit is a message, setting its clock to max + 1 | "Time, Clocks, and the Ordering of Events in a Distributed System", CACM 1978 |
| | Paxos | real single-decree Paxos (`px_*`).  Two proposers: the boss, whose value 1 is a rain, and a ghost on the left platform, whose value 2 is a fan.  Three acceptors; a quorum is any two.  Every message (Prepare, Promise, Accept, Accepted) is a bullet that homes on its receiver, labelled with its ballot or value.  Each acceptor shows its promised ballot above and its accepted value below.  A proposer with a quorum of promises adopts the highest voted value reported.  A stuck proposer retries with a higher ballot.  When the learner (the boss) sees a quorum, "CHOSEN: VALUE v" and that value is the telegraphed attack.  Your lemmas drop messages or crash acceptors, which keep their state; with nothing chosen by the timeout, the boss is stunned ("SAFE, BUT NOT LIVE") | "The Part-Time Parliament", TOCS 1998; "Paxos Made Simple", 2001 |
| Andrew Appel | Proof-carrying code | the boss's checker rejects unproved lemmas; tombstone certificates appear, each giving your next three lemmas a proof the checker accepts; some of the boss's shots are pink, and a parry is a certificate too | "Foundational Proof-Carrying Code", LICS 2001 (PCC: Necula and Lee) |
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
- Host build, 30,000 demo frames: VDP writes a frame mean 5, worst 451 (a stage's first map);
  APU worst 9; no frame has a sprite overflow (`HOST_OVERFLOW=1`; `=2` prints the frame and line
  of each).  The 16-sprites-a-line limit shaped the design: bullets buried in the ground are not
  drawn (they would share the HUD's lines, 11 sprites), spawned volleys start above the figures,
  and every move was run with `HOST_OVERFLOW=2` (Verification).  Over all the PROOF_TEST fight runs,
  the worst frame is 409 map writes.
- CPU time a frame on the strict sim (50 MHz SoC, a frame is 840,000 cycles): over the first 120
  frames (the title's init, then the demo's first stage run) mean 17,105 cycles, worst 186,428
  (frame 0, which draws every tile and sprite).  No boss fight has run on the RTL, so the fights'
  costliest frames (Lamport's breadth-first layer, full bullet tables) are not yet measured in
  cycles.

## Verification

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
- **Paxos (`px_*`), tested, not yet proved.**
  - The property expected is agreement: never `px_chosen (1)` and `px_chosen (2)` together, and
    `px_learned != 0` implies `px_chosen (px_learned)`.  It should hold for any order, loss or
    duplication of messages.
  - The steps are pure functions of their message's fields (`px_start`, `px_prepare`,
    `px_promise`, `px_accept`, `px_accepted`, `px_chosen`), ready for a CBMC harness.
  - `sw/game2d/proof_paxos_test.sh` extracts them from `proof_boss.c` and runs 1,000,000 random
    schedules of 120 steps each, covering any order, loss and duplication.  Agreement held in all
    of them; a value was learned in 978,921.
  - Its planted bug, phase 2 ignoring the reported votes, breaks agreement in run 2.
- **Not proved:**
  - the game engine's properties: no undefined behaviour over a whole frame, only real device
    registers, at most 16 sprites a line, and the per-frame write bound;
  - the other attacks, including the last lemmas (the dining philosophers, the monitor and
    OM(1) are game simulations of the algorithms, and they claim nothing);
  - anything about the binary (tier 3).

  These are tested:
- Host:
  - Built with `-Wall -Wextra -fsanitize=address,undefined`; 30,000 demo frames run clean.
  - Every boss move is driven directly with `-DPROOF_TEST`, a host-only hook.
    `PROOF_TEST=<boss>,<move>` starts the pilot in that arena, invulnerable, with the fight opening
    on that move.  `PROOF_HP=<n>` pins the boss's HP, which tests the pinch (16) and the last lemma
    (8).  `PROOF_CLEAN=1` and `PROOF_PARRY=1` exercise the clean-proof bonus and the parry.
  - Results: 32 moves (the last lemmas included) plus 14 pinch and last-lemma runs, each 2,400
    frames with `HOST_OVERFLOW=2`.  None had a sanitizer report or a sprite overflow.
  - Contact sheets of every new move were looked at.
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
mostly times out; a player can reach it.
