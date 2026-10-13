# classes — result: WORKS

Probe: `tb_classes.sv` — UVM-style component tree without uvm_pkg:
virtual base class (`component_base`) with `children[$]`, derived
driver/monitor/agent, virtual dispatch through a base handle
(`root.kind() == "agent"`), upcast on assignment, `$cast` downcast,
parameterized scoreboard class `scoreboard #(T)` with `expected[$]`,
`$urandom_range` in class code. All under `--no-timing` (F1 harness mode).

Evidence (`run.log`):

```
[tb] root.kind() through base handle = agent
[scoreboard] match=5 mismatch=0
[tb] $cast base->agent ok
CLASSES: PASS
```

Caveats hit while writing the probe (not Verilator faults):
- `expect` is a reserved keyword — rename the method (used `add_expected`).
- mid-block declarations after statements are rejected with a confusing
  "expecting '{'" parse error — declare locals at block/module scope top
  (matches Verilator's known block-item restriction).
- `down` is also a reserved word.

These all matter for J1 coding style: class declarations at scope top,
avoid keyword collisions.
