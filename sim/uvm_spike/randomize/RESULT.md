# randomize — result: WORKS (strong J2-relevant subset; one silent gap)

Probe: `tb_randomize.sv` — every item verified **procedurally** after
`randomize()` (15,000 checked solves), plus `tb_randcase.sv` and
`tb_randsequence.sv`. `--no-timing` throughout.

Works, with zero violations across the run (`run.log`):

| Construct | Evidence |
|---|---|
| range constraints (`a > 10; a < 20`) | 2000 iters clean |
| modulo/alignment (`c % 8 == 0`) | 2000 iters clean |
| `dist` weights | histogram 3628/1772/600 ≈ 60/30/10 over 6000 |
| `inside` multi-range + value lists | 6000 iters clean |
| implication `valid -> delay < 100` | 2000 iters clean |
| if/else constraint | 2000 iters clean |
| chained ordering `a<b; b<c; c<64` | 2000 iters clean |
| `foreach` per-element bounds | 1000 iters clean |
| `unique` on array | 1000 iters clean |
| inline `randomize() with { y < 8 }` | 1000 iters clean |
| `soft` constraints | satisfied when satisfiable (x==10 1000/1000) |
| unsatisfiable → rc=0, vars untouched | `rc=0 a=777` (+ UNSATCONSTR warning) |
| `constraint_mode(0)` | unconstrained value returned |
| `randcase` weights | 1510/875/615 ≈ 5:3:2 over 3000 |
| `randsequence` productions | 49/51 over 100 |
| `+verilator+seed+N` | same seed → identical stream; seed 7 differs (determinism + variation verified) |

## THE GAP (J2 must know)

**Array-reduction constraints are silently unenforced.** A constraint
`total.sum() < 20;` compiles with NO warning (even with all warnings
enabled) and the solver returns values violating it:

```
SUM-CONSTR2: max_sum=45435 over=2999/3000 elem_bad=0
```

(per-element `< 16` in the same class IS enforced — `elem_bad=0` — so
it is specifically the aggregate reduction that is dropped). Worse,
when the reduction shares a constraint BLOCK with per-element bounds,
the whole block's enforcement was lost in the original probe run
(999 violations). Rules for J2:
1. Never put `.sum()`/`.product()`/etc. in a constraint block.
2. Keep unsupported constructs out of blocks that also carry supported
   ones (one bad expression can void the block).
3. Bookkeep aggregates procedurally (accumulate in the sequence body,
   reject/regenerate when over budget), or pre-compute the aggregate
   into a non-rand field and constrain only per-element.

This does NOT force stimulus generation out of SV: the J2-relevant
shapes (chunk boundaries, corruption injection via dist/if-else,
address streams via inside/alignment) are all in the supported set.

Speed: ~0.5 ms/solve CPU (15k solves in 7.2 s CPU). Stimulus-scale,
not waveform-scale — fine for J2 (thousands of transactions per boot).
