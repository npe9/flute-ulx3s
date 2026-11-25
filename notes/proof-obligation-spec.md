# Proof Obligation: the specification

The game is defined by this document; `sw/game2d/proof.c` and `proof_boss.c` are an
implementation of it.  Each clause has a name (N1, I4, S3, ...), a statement, and the way it is
checked; `sw/game2d/proof_spec.c` states the same clauses as C predicates over what can be
observed of the game, so the text and the checked statement are the same thing.  Where they
differ, this document is right and the code (both the game and `proof_spec.c`) is fixed.

## How the game is observed

After every frame the engine reports a `spec_state` (`proof_spec.h`, filled by
`proof_observe` in proof.c): the phase (title, stage, arena scroll, fight, win, game over,
ending), whether the attract demo is playing, the stage's boss and the discharged bosses,
hearts, game over, invulnerable frames, proof certificates, the player's position, the camera,
the arena and world size, the score, the frame count, the boss (alive, hit points, hit flash,
stun, shield, current move, its number of moves), the counts of live shots, bullets and props,
the tactics (selected, owned, energy), the pickups taken, the frame's VDP writes, whether Paxos
agrees, and whether the host-only test hook is driving the fight (it forces a move or pins hit
points, which the clauses that it legitimately breaks allow; it is always off on the board).  Three predicates over observations define the game:

- `spec_init (s)`: the state at power-on (clauses N).
- `spec_inv (s)`: true after every frame (clauses I, V2, A6, W1-W3).
- `spec_step (s, buttons, s')`: relates the states before and after one frame (clauses S, W4-W5).

## Clauses

### Power-on (N)
- **N1** The game starts in a stage with the attract demo playing.
- **N2** with five hearts, not dead, not invulnerable;
- **N3** with score 0, no boss discharged, frame count 0.

### Invariants (I), after every frame
- **I0** The phase is one of the seven.
- **I1** Hearts are 0..5, and there are no hearts exactly when the game is over.
- **I2** Invulnerability is 0..90 frames.
- **I3** The stage's boss is one of seven; only those seven can be discharged.
- **I4** In a fight: the boss is alive with 1..32 hit points, runs one of its own moves, and the
  screen is the arena.
- **I5** The boss's hit flash is under 14 frames; its stun is not negative.
- **I6** In a stage, the arena scroll or a fight: the camera stays inside the world, and the
  player is on screen and inside the world.
- **I7** Certificates are not negative; at most 3 shots, 24 bullets, 10 props are live.
- **I8** The score is not negative.
- **I9** A boss's last lemma (its last move) runs only at a quarter of its hit points (8) or less.

### One frame (S)
- **S0** Exactly one frame passes.
- **S1** The phase changes only along title -> stage -> arena -> fight -> win -> title or ending,
  with game over reachable from the stage, the arena and the fight, and game over and the ending
  returning to the title; the ending only after a real win that discharges the seventh boss.  The
  attract demo may return to the title at any time, and any button ends it.
- **S2** A stage starts with five hearts, no certificates, not invulnerable.  Otherwise a heart is
  gained only from a heart pickup (at most one a frame; at five hearts it is points only), at most
  one is lost a frame, only when not invulnerable (at most one frame of it left), and a lost heart
  starts 90 frames of invulnerability, which then count down one a frame.  Falling into a pit costs
  a heart like any hit and puts the player back at the last checkpoint.
- **S3** A fight starts with the boss at 32 hit points, not flashing (the host test hook may pin it
  lower).  In the fight the boss never
  heals; it loses hit points only when not flashing, 1..4 at a time (4 is a weakness hit), and a
  hit starts its 14-frame flash.  The fight is won exactly when the boss has no hit points left.
- **S4** Only a real win (not the demo's) discharges a boss, and a real win discharges its boss;
  restarting from the ending clears all.
- **S5** The score never falls.
- **S6** In a stage the camera keeps the player 140 pixels from its left edge, clamped to the
  world; in a fight the screen does not scroll.

### Tactics (W): the weapons won from bosses
Tactic 0 is the lemma; tactic b+1 is boss b's (CONS, PATH, BRACES, TICK, CPS, TRINITY, CRUSH for
McCarthy .. Chlipala), with energy costs 0, 1, 2, 4, 7, 2, 1, 3.
- **W1** The selected tactic is owned; the lemma is always owned.
- **W2** Each tactic's energy is 0..28.
- **W3** Outside the attract demo a tactic is owned exactly when its boss is discharged (the
  lemma always); the demo owns all.  With S4, a tactic is gained only by a real win.
- **W4** A stage starts with every tactic full.  Otherwise a tactic's energy falls only by firing
  it: by exactly its cost, and only if that much was left.
- **W5** Energy rises only from an energy pickup: at most one a frame, refilling one tactic by at
  most 10.
- Not stated yet: only the boss's weakness does 4 damage (the observation does not say which
  tactic's shot hit).

### The screen and the bus (V)
- **V1** No line shows more than 16 sprites.
- **V2** Every VDP write happens in the frame's flush, at the start of the vertical blank: at most
  256 palette entries, 640 map words, 128 sprite words and 2 registers a frame.

### The bosses' algorithms (A): the attacks are the real algorithms
- **A1** McCarthy's compiled stack code leaves exactly the expression's value.
- **A2** Dijkstra's K-state ring always has a privilege, keeps a single one once it has one, and
  reaches a single one within 24 moves under any daemon.
- **A3** Hoare's FIND terminates within 75 steps and places A[f] with nothing larger to its left and
  nothing smaller to its right, permuting the array.
- **A4** Chlipala's limbs equal the spec number modulo 99999 (inductive step).
- **A5** Chlipala's pipeline fires the spec's shots three steps later (inductive).
- **A6** Lamport's Paxos never chooses two values, and the learner learns only a chosen value.

### The program (B): the binary is the C program
- **B1** The RISC-V binary never traps and touches only real device registers, with word accesses.
- **B2** The binary's device writes are exactly the host build's, for the same buttons.

## How each clause is checked

| Clauses | Checked by | Status |
|---|---|---|
| N, I, S, W1-W5 | the host oracle: every frame of every host run with `HOST_SPEC=1` (30,000 demo frames; every boss, move (the last lemmas included) and tactic via `PROOF_TEST`, plus the pinch and last-lemma HP pins and the poke, parry and clean-proof hooks: 334 runs of 2,400 frames; random button scripts), and every frame of every fuzz script (`formal/sw/host_trace.c`, fuzz.sh reports `SPEC`) | **tested**: all inputs tried pass; eleven planted engine bugs (one or more per clause family) are each caught (`formal/sw/spec_mutants.sh`) |
| V1 | `HOST_OVERFLOW=2` on the same runs (the VDP reference model's per-line count) | **tested** |
| V2 | the host oracle: the flush counts its writes by kind, and host.c checks that every VDP write of the frame is one of them | **tested**; a planted write outside the flush is caught |
| A6 | `run_proof.sh` PAXOS_INIT, PAXOS_STEP, PAXOS_AGREE: an inductive invariant of the `px_*` code, over every schedule (any order, loss, duplication); five planted protocol bugs fail it.  Also the host oracle on every frame of the game, and 1,000,000 random schedules (`proof_paxos_test.sh`) | **proved** for the protocol steps, assuming the game sends only the messages the steps produce; **tested** for the game around them |
| A1-A5 | `formal/sw/cbmc/run_proof.sh` (CBMC; FIND by exhaustive enumeration), 5 planted mutants | **proved** over the stated domains (A4 and A5 as inductive steps; A4 assumes limbs stay under 100) |
| B1, B2 | `TITLE=proof formal/sw/fuzz.sh` on the Sail RV32 model | **tested** |

Coverage gaps the oracle cannot close by itself: the demo takes about ten energy pickups in
30,000 frames, all within 4 of full, so W5's refill bound is checked but barely exercised (a planted
wrong refill is hidden by the cap and survives); and a real game that owns some tactics but not
all is reached only by human play, not by the demo or the random scripts.

What the oracle has found: the host-only `PROOF_TEST` hook applied the tested move to every
later fight in the demo, so Appel's fight could run a fourth move that does not exist (I4);
fixed to apply it to the tested fight only.  With the tactics: ownership was refreshed only at the
start of a frame, so it trailed a win by one frame; the engine now refreshes it at the end too,
and W3 holds after every frame.

## Next: from tested to proved

1. **The engine, modularly.**  A whole-frame induction as for Lantern Drift is out of reach here
   (`proof_frame` reaches 3,400 lines and 32 moves; CBMC already needs minutes for 60 lines of
   Paxos).  The plan is per clause family:
   - `formal/sw/census.py` lists, from clang's AST of the board build, every function that writes
     each rule variable (or takes its address, or passes an array of it as a pointer: none do),
     which functions may reach those writers through the call graph (indirect calls resolved by
     the boss table's fields), and the argument values `boss_damage` receives (1..4, all
     constants).  `--check formal/sw/census.allow` fails when any of it changes.  A planted
     write, address escape and array decay are each reported.
   - `spec_step` is the conjunction of one function per clause (`spec_S0` .. `spec_S6`,
     `spec_W45`), so a proof can assert a single clause in the spec's own words.
   - Each family is then proved on the real `proof_frame`, with every callee that the census says
     cannot reach the family's variables replaced by a stub that havocs the rest of the state,
     and the ones that can, by a stub that also calls the real writers.
   This is in progress; nothing in N, I, S or W is proved yet.
2. **The binary**: B2 makes the binary's behaviour equal the host build's on every fuzzed script;
   a proof needs tier 3 (the binary against Sail) for the whole frame, or a verified compiler.
