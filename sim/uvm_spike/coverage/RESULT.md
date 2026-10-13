# coverage — result: WORKS (SV functional covergroups, bins, crosses)

Probe: `tb_coverage.sv` — J3-shaped functional coverage, all under
`--no-timing`:

- `loader_cov`: coverpoints with range/value bins (`chunk_idx`
  first/middle/last, `naks` none/one/many/flood) + an auto **cross**
  (`chunk_idx x naks`).
- `hazard_cov`: strict-BRAM violation bins that must stay EMPTY —
  the J3 rule "a non-empty bin IS the failure".
- Sampled from class instances via explicit `cg.sample(...)`; the
  `--binary` main writes `coverage.dat`; `run.sh` greps per-bin hit
  counts and enforces the empty-violation-bin gate (the exact J3 gate
  mechanism).

Evidence (`run.log`):

```
checks: hazard lost_read.violated=0 cross_port.violated=0 | loader first=3 mid=15 last=3 nak0=19 nak1=1 nak2=1 cross=21
COVERAGE: PASS (functional covergroup bins + empty-violation-bin gate)
```

Findings:
- covergroup / coverpoint / bins (value, range) / illegal_bins / auto
  cross: supported and counted in coverage.dat.
- **Explicit cross bins (`bins foo = binsof(a.x) && binsof(b.y);`) are
  NOT supported** — COVERIGN warning ("Unsupported: 'binsof' in
  coverage select expression"), promoted to error. Model cross coverage
  with auto crosses or separate coverpoints.
- `--coverage` (at least `--coverage-user`) must be on the verilation
  command line or **no coverage.dat is written at all** (counters
  silently lost — verified by running without it).
- Verilator's own line/toggle/fsm/expr coverage rides along in the same
  coverage.dat when `--coverage` is given (line entries were visible in
  the /tmp characterization run); `--coverage-line --coverage-toggle`
  etc. are independent per-type flags for the J3/J4 gate.
