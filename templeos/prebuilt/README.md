# Prebuilt TempleOS images

`ulx3s_repl.blob.bin` is the HolyC REPL image the Bluesim REPL boot (`make sim-repl`,
`test/sim_preload.c`) and the board bench (`scripts/hw_test_suite.py`) load when there is no local
`templeos/build/` output. It is built from source by `make -C templeos holyc repl` once the `templeos/tos` submodule is
checked out (`git submodule update --init templeos/tos`); CI does that on every run.

| file | md5 | built from |
|---|---|---|
| ulx3s_repl.blob.bin | e798ec12726a7e2b0bb2a520efd4ec4f | templeos-cursor-riscv `ulx3s-repl` 7dc41b58 (the `templeos/tos` submodule) plus the ULX3S overlays with the board drivers (`ulx3s_repl/ulx3s_drv.hc`), `make -C templeos holyc repl` for the 25 MHz main SoC map, 2026-11-12; `ci/bluesim_gate.sh` PASS; on lx44 hw suite 76/0/2 and `scripts/hw_board_drv.py` 10/0 |

Replace it only together with a passing `ci/bluesim_gate.sh` and board bench.
