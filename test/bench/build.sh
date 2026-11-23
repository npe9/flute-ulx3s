#!/bin/sh
# test/bench/build.sh: Dhrystone and CoreMark for the board (scripts/loader.py --no-banner) or the
# strict sim.  rv32imac (integer benchmarks; the toolchain's rv32imac/ilp32 newlib supplies
# strcpy / memcpy), -O2.  Output: test/bench/{dhrystone,coremark}.bin.
#   DHRY_RUNS=500000 CM_ITER=0 test/bench/build.sh    (CM_ITER=0: CoreMark calibrates to ~10 s)
set -e
cd "$(dirname "$0")"
CC=riscv64-unknown-elf-gcc
ARCH="-march=rv32imac_zicsr -mabi=ilp32"
OPT="-O2"
COMMON="$ARCH $OPT -ffreestanding -nostartfiles -static -T bench.ld -Wl,--gc-sections"
LIBS="-lc -lgcc"
DHRY_RUNS=${DHRY_RUNS:-500000}
CM_ITER=${CM_ITER:-0}
pad () { riscv64-unknown-elf-objcopy -O binary $1.elf $1.bin; s=$(wc -c < $1.bin); p=$(( (4 - s % 4) % 4 )); [ $p -eq 0 ] || head -c $p /dev/zero >> $1.bin; }

$CC $ARCH $OPT -ffreestanding -c -o bench_rt.o bench_rt.c

# Dhrystone (riscv-tests' copy, via cva6): its no-inline pragma kept; -fno-builtin-printf so the
# shims in dhry_port.c are called as written
$CC $COMMON -fno-builtin-printf -fno-common -DNUMBER_OF_RUNS=$DHRY_RUNS -Wno-implicit-int \
    -Wno-implicit-function-declaration -Wno-return-type -std=gnu89 \
    -o dhrystone.elf dhrystone/dhrystone_main.c dhrystone/dhrystone.c dhrystone/dhry_port.c bench_rt.o $LIBS
pad dhrystone

# CoreMark (upstream eembc/coremark core files unmodified, md5s in coremark/coremark.md5)
CMF="$OPT $ARCH"
$CC $COMMON -Icoremark -DITERATIONS=$CM_ITER -DPERFORMANCE_RUN=1 -DFLAGS_STR="\"$CMF\"" \
    -o coremark.elf coremark/core_list_join.c coremark/core_main.c coremark/core_matrix.c \
    coremark/core_state.c coremark/core_util.c coremark/core_portme.c coremark/ee_printf.c \
    coremark/cvt.c bench_rt.o $LIBS
pad coremark
rm -f bench_rt.o
ls -l dhrystone.bin coremark.bin
