#!/bin/bash
# Build OpenSBI (FW_PAYLOAD) + Linux v6.12 (rv32, tinyconfig-based) + DTB + freestanding /init for
# the ULX3S Flute SoC.  Runs the build in the flute-rv32-build image; the kernel source and
# build trees live in the case-sensitive docker volume flute-linux-src.
#   ./build-fp.sh         -> out-fp/: F/D kernel (CONFIG_FPU), rv32imafdc DT + OpenSBI, init-fp (FP context test)
set -e
W=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W/out-fp"
docker run --rm -v flute-linux-src:/src -v "$W":/work flute-rv32-build bash -ec '
X=riscv64-linux-gnu-
J=$(nproc)
# /init: no libc
${X}gcc -march=rv32imafdc_zicsr -mabi=ilp32d -fno-math-errno -Os -static -nostdlib -ffreestanding -fno-pic -no-pie \
  -Wl,--build-id=none -o /work/init-fp/init /work/init-fp/init.c
# DTB
dtc -I dts -O dtb -o /work/out-fp/flute.dtb /work/dts-fp/flute-ulx3s.dts
# Linux
K=/src/build-linux-fp; mkdir -p $K
cd /src/linux
make -s O=$K ARCH=riscv CROSS_COMPILE=$X tinyconfig
scripts/kconfig/merge_config.sh -m -O $K $K/.config arch/riscv/configs/32-bit.config /work/kernel/flute-fp.config >/dev/null
make -s O=$K ARCH=riscv CROSS_COMPILE=$X olddefconfig
make -s O=$K ARCH=riscv CROSS_COMPILE=$X -j$J Image
cp $K/arch/riscv/boot/Image $K/vmlinux $K/System.map $K/.config /work/out-fp/
# OpenSBI
rm -rf /src/build-opensbi-fp; mkdir -p /src/build-opensbi-fp
make -s -C /work/opensbi O=/src/build-opensbi-fp CROSS_COMPILE=$X PLATFORM=generic \
  PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32imafdc_zicsr_zifencei PLATFORM_RISCV_ABI=ilp32 \
  FW_PAYLOAD=y FW_PAYLOAD_PATH=/work/out-fp/Image FW_FDT_PATH=/work/out-fp/flute.dtb \
  FW_PAYLOAD_OFFSET=0x400000 FW_PAYLOAD_FDT_OFFSET=0x1F00000 -j$J
cp /src/build-opensbi-fp/platform/generic/firmware/fw_payload.elf /src/build-opensbi-fp/platform/generic/firmware/fw_payload.bin /work/out-fp/
ls -la /work/out
'
