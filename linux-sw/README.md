# Linux software for the Flute ULX3S SoC

OpenSBI 1.9 (FW_PAYLOAD, PLATFORM=generic, RV32) + Linux v6.12 (tinyconfig + 32-bit.config +
kernel/flute.config) + a freestanding /init ticker, for the S-mode/Sv32/PMP Flute build.

- `docker/Dockerfile` -> image `flute-rv32-build` (`docker build -t flute-rv32-build docker`).
- Kernel source: `git archive v6.12` of linux.git into the case-sensitive docker volume
  `flute-linux-src` at `/src/linux`.
- OpenSBI source: `git archive v1.9` of opensbi.git into `linux-sw/opensbi/` (gitignored).
- `./build.sh` -> `out/fw_payload.{elf,bin}` (load at 0x80000000; kernel at +4 MB, DTB at +0x1F00000).
- Sim: `sim/linux_bram/linux_run.py out/fw_payload.bin` (passes when the console prints "tick 2").
