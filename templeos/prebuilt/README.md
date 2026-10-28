# Prebuilt TempleOS images

`ulx3s_repl.blob.bin` is the HolyC REPL image the Bluesim REPL boot (`make sim-repl`,
`test/sim_preload.c`) and the board bench (`scripts/hw_test_suite.py`) load when there is no local
`templeos/build/` output. Building it needs a checkout of templeos-cursor-riscv
(`make -C templeos repl TOS_REPO=<checkout>`), which is not public yet.

| file | md5 | built from |
|---|---|---|
| ulx3s_repl.blob.bin | 5ec46fcb2c7f6576367f66e3c71dcd3f | templeos-cursor-riscv `archive` branch, 2026-10-26, for the main SoC memory map; board bench 70/0/2 on E20 |

Replace it only together with a passing `make sim-gate` and board bench.
