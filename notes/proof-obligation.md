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

The bosses are original robed figures with an emblem on the chest (lambda, a graph node, braces,
a clock, K, a triple bar, for-all); they are tributes to the ideas, not likenesses.  Every
attack's name is shown when it starts, with one line saying what the idea is.

## The bosses and their attacks

Each attack is the idea working as a mechanic, and each is the boss's own work (where an idea
has other authors too, the source is named and the attack is credited to the boss's own work on it).

| Boss | Attack | Mechanic | Source |
|---|---|---|---|
| John McCarthy | `(CONS CAR CDR)` | a cons cell is thrown; where it lands the car stays (an atom) and the cdr bounces on, three times, until nil | Lisp: "Recursive Functions of Symbolic Expressions and Their Computation by Machine, Part I", CACM 1960 |
| | Mark and sweep | the heap (four floor segments, three platforms) is marked from the root the boss stands on; unmarked ground blinks, then is freed (a pit) until the collection ends | the same paper's reclamation of free storage (the first garbage collector) |
| | Nested parentheses | pairs of `(` `)` close in on where you stood, an inner pair after the outer | S-expressions, ibid. |
| | `(AMB A B)` | between attacks two ghosts show where the boss may be; the angelic choice puts the boss at the one farther from you | "A Basis for a Mathematical Theory of Computation", 1961/63 |
| Edsger Dijkstra | Shortest path first | seekers walk the shortest path to you through the arena's free tiles, recomputed continuously (a breadth-first search, 150 cells a frame: unit edge weights, where Dijkstra's algorithm reduces to BFS) | "A note on two problems in connexion with graphs", Numer. Math. 1959 |
| | P(S) / V(S) | P takes the semaphore: a gate splits the arena and shields the boss while drops rain on your side; shoot the switch to signal V and open it | "Cooperating Sequential Processes", EWD123, 1965 |
| | GOTO considered harmful | the boss marks a label L; the arrows fly, then jump discontinuously to L and come at you from there | "Go To Statement Considered Harmful", CACM 1968 (the title is Wirth's, as editor) |
| Tony Hoare | Quicksort | eight pillars rise in random order and are sorted in front of you one comparison at a time with Hoare's own partition (middle pivot, gold; i and j close in, out-of-place pairs swap; recurse); the sorted pillars are stairs up to the boss's ledge | Algorithm 64, CACM 1961; "Quicksort", Computer Journal 1962 |
| | `{P} C {Q}` | a zone P appears on the floor; a lemma thrown from inside P is proved to reach Q (it homes on the boss) | "An Axiomatic Basis for Computer Programming", CACM 1969 |
| | Null: a billion-dollar mistake | some floor is a null reference: it looks like floor (a faint dashed edge) and you fall through it | Hoare's 2009 talk "Null References: The Billion Dollar Mistake" |
| Leslie Lamport | Logical clocks | four emitters show their clocks; the least (clock, id) fires next and takes max + 1; your hit is a message, setting its clock to max + 1 (it waits) | "Time, Clocks, and the Ordering of Events in a Distributed System", CACM 1978 |
| | Bakery | four minions take tickets and enter the critical section (chase you) one at a time, in ticket order | "A New Solution of Dijkstra's Concurrent Programming Problem", CACM 1974 |
| | Paxos | three acceptors light one by one; a quorum (two) decides a ballot and a rain falls; shoot two before they accept and the ballot fails (the boss is stunned, double damage) | "The Part-Time Parliament", TOCS 1998 |
| Andrew Appel | Compiling with continuations | every throw records its path, then the continuation is invoked: it returns along the same path to the boss | *Compiling with Continuations*, 1992 (CPS itself is older: Reynolds, Steele) |
| | Proof-carrying code | the boss's checker rejects unproved lemmas ("REJECTED: NO PROOF ATTACHED"); tombstone certificates appear, and each gives your next three lemmas a proof the checker accepts (drawn blue) | "Foundational Proof-Carrying Code", LICS 2001 (PCC: Necula and Lee) |
| | Simple generational GC | a nursery of minions; at the minor collection most die young and the survivors are promoted (bigger, faster, three hits) | "Simple Generational Garbage Collection and Fast Allocation", SP&E 1989 (generational GC: Lieberman and Hewitt; Ungar) |
| Robert Harper | Unityped | six identical orbs; at the run-time tag check each flashes and shows its real behaviour (straight, bouncing, homing) | "Dynamic Languages are Static Languages", 2011 (*Existential Type*) |
| | Computational trinitarianism | orbs L, T, C (logic, types, categories) orbit and shield the boss; hit any one and all three go, because they are the same | "The Holy Trinity", 2011 (ibid.) |
| | Parallelism is not concurrency | the boss forks into three; each copy throws the same share of the volley at the same moment; they join with the same result as one | "Parallelism Is Not Concurrency", 2011 (ibid.) |
| Adam Chlipala | Crush | the boss leaps toward you and slams; shockwaves run along the floor both ways (jump them) | the `crush` tactic of *Certified Programming with Dependent Types*, 2013 |
| | Bedrock | three of eight floor cells are the boss's footprint (they blink), and only they erupt; outside the footprint the frame rule holds and you are safe | Bedrock, PLDI 2011 (separation logic: Reynolds, O'Hearn) |
| | Ur/Web: no broken links | three links of dots sweep from the boss across the arena; your lemmas pass through them: a link cannot be broken | Ur/Web, POPL 2015 |

## The machine budget

- Each frame first flushes the previous frame's shadow state (palette, sprite table, scroll,
  changed map words, at most 640 a frame), then simulates, so every VDP write lands in the
  vertical blank (42 lines, about 67,000 CPU clocks at 50 MHz).
- Host build, 30,000 demo frames: VDP writes a frame mean 4, worst 419 (a stage's first map);
  APU worst 7; no frame has a sprite overflow (`HOST_OVERFLOW=1`; `=2` prints the frame and line
  of each).  The 16-sprites-a-line limit shaped two things: bullets buried in the ground are not
  drawn (they would share the HUD's lines, 11 sprites), and Harper's fork volley starts above the
  three figures (at their height it made 17 on one line).
- CPU time a frame on the strict sim (50 MHz SoC, a frame is 840,000 cycles): over the first 120
  frames (the title's init, then the demo's first stage run) mean 17,744 cycles, worst 263,975
  (frame 0, which draws every tile and sprite).  No boss fight has run on the RTL, so the fights'
  costliest frames (Dijkstra's 150-cell BFS slice, full bullet tables) are not yet measured in
  cycles.

## Verification

- Host: built with `-Wall -Wextra -fsanitize=address,undefined`, 30,000 demo frames clean; and
  every boss move driven directly (`-DPROOF_TEST`, a host-only hook: `PROOF_TEST=<boss>,<move>`
  starts the pilot in that arena, invulnerable, the fight opening on that move): 21 runs x 2,400
  frames, no sanitizer report, no sprite overflow.  The contact sheets of those runs were looked
  at for every rewritten attack (certificates picked up and proved lemmas landing; the fork's
  copies and volleys; the Bedrock footprint blinking, then only it erupting).
- Tier 1 (`TITLE=proof formal/sw/fuzz.sh`): `proof.elf` on the Sail RV32 model with the SoC's
  devices, random buttons, half the runs with random UART / frame timing: S1 (no trap, only real
  device registers, word accesses) and S2 (its device-write trace equals the host build's) hold
  for 8 runs x 3,000 frames (seed 7).  Tested, not proved.
- The strict-BRAM sim frame check (`TITLE=proof FRAMES=120 sim/game2d/frame_check.sh
  build/game2d`, the game2d+VDP+APU netlist): PASS -- the 640x480 scan-out identical to the
  reference model's frame, 49,919 APU samples equal, its 624 writes = the host build's.  120
  frames cover the init and the opening of the first stage only.
- Not yet: tier 2 (CBMC induction over one frame: the title's state is larger and its frame has
  data-dependent loops -- the BFS slice, the quicksort step -- which need their bounds stated)
  and tier 3.  On the board: not yet run (the game2d SoC's timing is open).

## Status

Playable on the host build and the strict sim; not yet run on the board, because the game2d
SoC's timing is still open (`notes/soc-family-plan.md`, game2d status).  The attract pilot
cannot reach Dijkstra (who hovers level with the high platforms) or easily Hoare (on a ledge
above the stairs), so in the demo those fights mostly time out; a player can reach both.
