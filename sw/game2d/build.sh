#!/bin/sh
# sw/game2d/build.sh: Lantern Drift for the game2d SoC (lantern.bin: runs forever) and the frame
# check (lantern_f<n>.bin: stops after n frames, see board.c), plus the host model
# (build/game2d/lantern_host).  Uses test/bench's runtime and linker script; no libc (-nostdlib),
# so the CI image's bare gcc-riscv64-unknown-elf (no newlib) builds it.
#   FRAMES=40 sw/game2d/build.sh
set -e
cd "$(dirname "$0")"
R=../..
CC=riscv64-unknown-elf-gcc
ARCH="-march=rv32imac_zicsr -mabi=ilp32"
FRAMES=${FRAMES:-40}
COMMON="$ARCH -O2 -Wall -ffreestanding -nostartfiles -nostdlib -static -T $R/test/bench/bench.ld -Wl,--gc-sections"
pad () { riscv64-unknown-elf-objcopy -O binary $1.elf $1.bin; s=$(wc -c < $1.bin); p=$(( (4 - s % 4) % 4 )); [ $p -eq 0 ] || head -c $p /dev/zero >> $1.bin; }
$CC $ARCH -O2 -ffreestanding -c -o bench_rt.o $R/test/bench/bench_rt.c
$CC $COMMON -o lantern.elf board.c lantern.c sound.c bench_rt.o -lgcc
pad lantern
$CC $COMMON -DGAME_FRAMES=$FRAMES -o lantern_f$FRAMES.elf board.c lantern.c sound.c bench_rt.o -lgcc
pad lantern_f$FRAMES
mkdir -p $R/build/game2d
cc -O2 -Wall -o $R/build/game2d/lantern_host host.c lantern.c sound.c ../vdp/vdp_ref.c
ls -l lantern.bin lantern_f$FRAMES.bin
