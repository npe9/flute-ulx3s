# Linux software for the Flute ULX3S SoC

OpenSBI 1.9 (FW_PAYLOAD, PLATFORM=generic, RV32) + Linux v6.12 (tinyconfig + 32-bit.config +
kernel/flute.config) + a freestanding /init ticker, for the S-mode/Sv32/PMP Flute build.

- `docker/Dockerfile` -> image `flute-rv32-build` (`docker build -t flute-rv32-build docker`).
- Kernel source: `git archive v6.12` of linux.git into the case-sensitive docker volume
  `flute-linux-src` at `/src/linux`.
- OpenSBI source: `git archive v1.9` of opensbi.git into `linux-sw/opensbi/` (gitignored).
- `./build.sh` -> `out/fw_payload.{elf,bin}` (load at 0x80000000; kernel at +4 MB, DTB at +0x1F00000).
- Sim: `sim/linux_bram/linux_run.py out/fw_payload.bin` (passes when the console prints "tick 2").

## F/D build (FP=1 FPU_TRIM=1 bitstream)

`./build-fp.sh` -> `out-fp/`: kernel with `CONFIG_FPU=y` (kernel/flute-fp.config), DT
`rv32imafdc` with `f`, `d` (dts-fp/), OpenSBI `PLATFORM_RISCV_ISA=rv32imafdc_zicsr_zifencei`,
separate build trees in the docker volume (build-linux-fp, build-opensbi-fp).  Its /init
(init-fp/init.c) forks; both processes load f0-f31 and fcsr (different frm/fflags each),
sleep so the kernel switches between them, and check every register bit for bit, plus a
sqrt/div/fma chain in double and single against its first result.  The parent prints
`tick N  uptime U s  fp ok` (or `fp BAD` with the mismatching register).
Board, 2026-10-23, fpt3 seed-1 bitstream: OpenSBI "rv32imafdcb ... f,d", kernel "acdfim",
all ticks `fp ok`.
