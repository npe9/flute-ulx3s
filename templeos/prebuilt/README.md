# Prebuilt TempleOS images

`ulx3s_repl.blob.bin` is the HolyC REPL image the Bluesim REPL boot (`make sim-repl`,
`test/sim_preload.c`) and the board bench (`scripts/hw_test_suite.py`) load when there is no local
`templeos/build/` output. It is built from source by `make -C templeos holyc repl` once the `templeos/tos` submodule is
checked out (`git submodule update --init templeos/tos`); CI does that on every run.

| file | md5 | built from |
|---|---|---|
| ulx3s_repl.blob.bin | 400a7be9109bad833498f1c39212d19e | templeos-cursor-riscv `ulx3s-repl` 7dc41b58 (the `templeos/tos` submodule), `make -C templeos holyc repl` for the 25 MHz main SoC map, 2026-10-28; board REPL eval checks pass |

Replace it only together with a passing `ci/bluesim_gate.sh` and board bench.
