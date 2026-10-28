#!/bin/bash
# compliance/run.sh -- riscv-arch-test (3.10.0) under RISCOF: Flute DUT vs Sail reference.
#
#   ./run.sh                      # full rv32i_m suite (every extension the ISA yaml selects)
#   ./run.sh I M                  # only these rv32i_m subdirectories
#   EXCLUDE='pmp-NAPOT-R*' ./run.sh pmp32   # a subset minus some tests
#   SUITE_ONLY=1 ./run.sh         # just list the selected tests (riscof testlist)
#
# CONFIG=config-fd.ini: the F/D build (FP=1 FPU_TRIM=1 netlist, Sail with F/D).
# Env: SAIL_DIR (Sail C emulator dir, default ~/src/sail-riscv/c_emulator/),
#      ARCH_TEST (default ~/src/riscv-arch-test, checked out at 3.10.0),
#      RISCOF (default ~/src/riscof-venv/bin/riscof), WORK (default riscof_work).
# The DUT plugin builds sim/isa_bram/obj_dir_riscof from build/timing-exp/verilog_all.v.v8
# on first use (JOBS=4).  Results: $WORK/report.html, per test $WORK/<test>/{dut,ref}/.
set -euo pipefail
cd "$(dirname "$0")"
ARCH_TEST="${ARCH_TEST:-$HOME/src/riscv-arch-test}"
RISCOF="${RISCOF:-$HOME/src/riscof-venv/bin/riscof}"
WORK="${WORK:-riscof_work}"
# The committed configs name the Sail C model directory as @SAIL_DIR@.
SAIL_DIR="${SAIL_DIR:-$HOME/src/sail-riscv/c_emulator/}"
CFG=".${CONFIG:-config.ini}.gen"
sed "s|@SAIL_DIR@|$SAIL_DIR|" "${CONFIG:-config.ini}" > "$CFG"
export PATH="$(dirname "$RISCOF"):$PATH"     # python3 for isa_run.py, riscv_isac
SUITE="$ARCH_TEST/riscv-test-suite"
ENV="$ARCH_TEST/riscv-test-suite/env"

if (($#)); then   # a subset: a suite dir of copies of the chosen rv32i_m subdirectories
    SUITE="$PWD/$WORK.suite/rv32i_m"; rm -rf "$PWD/$WORK.suite"; mkdir -p "$SUITE"
    for d in "$@"; do cp -R "$ARCH_TEST/riscv-test-suite/rv32i_m/$d" "$SUITE/$d"; done   # copies: riscof walks without following symlinks
    # EXCLUDE: space-separated globs of test files to drop from the copies, e.g. the
    # pmp-NAPOT-R*/RW* tests, which assume a 4-byte PMP grain (Flute G=10) and loop
    # forever in the Sail reference too (riscv_sim -l does not stop them).
    for g in ${EXCLUDE:-}; do find "$SUITE" -name "$g" -print -delete; done
else
    SUITE="$ARCH_TEST/riscv-test-suite/rv32i_m"
fi

if [[ "${SUITE_ONLY:-0}" == "1" ]]; then
    exec "$RISCOF" testlist --config="$CFG" --suite="$SUITE" --env="$ENV" --work-dir="$WORK"
fi
"$RISCOF" run --config="$CFG" --suite="$SUITE" --env="$ENV" --work-dir="$WORK" --no-browser
