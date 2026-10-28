#!/bin/bash
# Build OpenSBI (FW_PAYLOAD) + Linux v6.12 (rv32, tinyconfig-based) + DTB + freestanding /init for
# the ULX3S Flute SoC with the toolchain in the current environment (the CI image ci/Dockerfile, or
# the flute-rv32-build image via build.sh / build-fp.sh).
#   ./build-native.sh [base|fp]    base -> out/, fp -> out-fp/ (F/D kernel, rv32imafdc DT + OpenSBI)
# Sources (downloaded if absent):
#   LINUX_SRC    kernel tree      (default src/linux-6.12 from cdn.kernel.org)
#   OPENSBI_SRC  OpenSBI tree     (default ./opensbi, v1.9 from GitHub)
#   BUILD_ROOT   build trees      (default ./build)
# Needs a case-sensitive file system for the kernel tree (not the default macOS one).
set -euo pipefail
W=$(cd "$(dirname "$0")" && pwd)
V=${1:-base}
LINUX_VERSION=6.12
OPENSBI_TAG=v1.9
X=${CROSS_COMPILE:-riscv64-linux-gnu-}
J=$(nproc)
case $V in
  base) OUT=$W/out;    INIT=$W/init;    DTS=$W/dts/flute-ulx3s.dts;    KCFG=$W/kernel/flute.config
        MARCH=rv32imac_zicsr;   MABI=ilp32;  CFLAGS_EXTRA=
        SBI_ISA=rv32imac_zicsr_zifencei ;;
  fp)   OUT=$W/out-fp; INIT=$W/init-fp; DTS=$W/dts-fp/flute-ulx3s.dts; KCFG=$W/kernel/flute-fp.config
        MARCH=rv32imafdc_zicsr; MABI=ilp32d; CFLAGS_EXTRA=-fno-math-errno
        SBI_ISA=rv32imafdc_zicsr_zifencei ;;
  *) echo "usage: $0 [base|fp]" >&2; exit 2 ;;
esac
BUILD_ROOT=${BUILD_ROOT:-$W/build}
K=$BUILD_ROOT/linux-$V; S=$BUILD_ROOT/opensbi-$V
mkdir -p "$OUT" "$K" "$BUILD_ROOT"

LINUX_SRC=${LINUX_SRC:-$W/src/linux-$LINUX_VERSION}
if [ ! -f "$LINUX_SRC/Makefile" ]; then
  mkdir -p "$(dirname "$LINUX_SRC")"
  curl -fsSL https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VERSION.tar.xz \
    | tar -xJ -C "$(dirname "$LINUX_SRC")"
fi
OPENSBI_SRC=${OPENSBI_SRC:-$W/opensbi}
[ -f "$OPENSBI_SRC/Makefile" ] || git clone -q --depth 1 -b $OPENSBI_TAG https://github.com/riscv-software-src/opensbi "$OPENSBI_SRC"

# /init: no libc
${X}gcc -march=$MARCH -mabi=$MABI $CFLAGS_EXTRA -Os -static -nostdlib -ffreestanding -fno-pic -no-pie \
  -Wl,--build-id=none -o "$INIT/init" "$INIT/init.c"
# initramfs list with this checkout's path (the committed list names /work, the docker mount)
sed "s|/work/|$W/|" "$INIT/initramfs.list" > "$K/initramfs.list"
# DTB
dtc -I dts -O dtb -o "$OUT/flute.dtb" "$DTS"
# Linux
make -s -C "$LINUX_SRC" O="$K" ARCH=riscv CROSS_COMPILE=$X tinyconfig
(cd "$LINUX_SRC" && scripts/kconfig/merge_config.sh -m -O "$K" "$K/.config" arch/riscv/configs/32-bit.config "$KCFG" >/dev/null)
"$LINUX_SRC/scripts/config" --file "$K/.config" --set-str INITRAMFS_SOURCE "$K/initramfs.list"
make -s -C "$LINUX_SRC" O="$K" ARCH=riscv CROSS_COMPILE=$X olddefconfig
make -s -C "$LINUX_SRC" O="$K" ARCH=riscv CROSS_COMPILE=$X -j"$J" Image
cp "$K/arch/riscv/boot/Image" "$K/vmlinux" "$K/System.map" "$K/.config" "$OUT/"
# OpenSBI
rm -rf "$S"; mkdir -p "$S"
make -s -C "$OPENSBI_SRC" O="$S" CROSS_COMPILE=$X PLATFORM=generic \
  PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=$SBI_ISA PLATFORM_RISCV_ABI=ilp32 \
  FW_PAYLOAD=y FW_PAYLOAD_PATH="$OUT/Image" FW_FDT_PATH="$OUT/flute.dtb" \
  FW_PAYLOAD_OFFSET=0x400000 FW_PAYLOAD_FDT_OFFSET=0x1F00000 -j"$J"
cp "$S/platform/generic/firmware/fw_payload.elf" "$S/platform/generic/firmware/fw_payload.bin" "$OUT/"
ls -la "$OUT"
