#!/bin/bash
# ================================================================
# run_sweep.sh — F2 X-sweep: N seeded runs of the strict sim.
#
#   ./run_sweep.sh [N]        # N seeds (default 8), STRICT_BRAM=warn
#   SWEEP_STRICT=error ./run_sweep.sh 4
#
# Every seed must exit 0 with a PASS line, and every seed's stdout must
# be byte-identical to seed 1 (the design is reset-clean: uninitialized
# state must not leak into observable behavior).  Logs land in
# build/timing-exp/f2-sweep/.
#
# Note: this Verilator build's --x-initial modes are 0|fast|unique;
# run.sh already uses `unique`, so each +verilator+seed+N re-randomizes
# all uninitialized state.
# ================================================================
set -uo pipefail
cd "$(dirname "$0")"

N="${1:-8}"
STRICT="${SWEEP_STRICT:-warn}"
OUTDIR="${SWEEP_OUT:-../../build/timing-exp/f2-sweep}"
mkdir -p "$OUTDIR"

ref=""
fail=0
for seed in $(seq 1 "$N"); do
    log="$OUTDIR/seed-$seed.log"
    echo "=== seed $seed (STRICT_BRAM=$STRICT) ==="
    ./run.sh --strict="$STRICT" "+verilator+seed+$seed" > "$log" 2>&1
    rc=$?
    if [[ $rc != 0 ]]; then
        echo "seed $seed: SIM FAILED (exit $rc) — see $log"
        fail=1
        continue
    fi
    if ! grep -q "RESULT: PASS" "$log"; then
        echo "seed $seed: no PASS line — see $log"
        fail=1
        continue
    fi
    # Compare on content, not Verilator's own compile-time stats (the
    # walltime/allocated lines legitimately differ run to run).
    filt() { grep -v '^- Verilator:' "$1"; }
    if [[ -z "$ref" ]]; then
        ref="$log"
        filt "$log" > "$OUTDIR/.ref.filt"
    elif ! diff -q "$OUTDIR/.ref.filt" <(filt "$log") > /dev/null; then
        echo "seed $seed: OUTPUT DIFFERS from seed 1:"
        diff "$OUTDIR/.ref.filt" <(filt "$log") | head -20
        fail=1
    else
        echo "seed $seed: identical to seed 1"
    fi
done

if [[ $fail == 0 ]]; then
    echo "F2 SWEEP: PASS ($N seeds, STRICT_BRAM=$STRICT, identical output)"
else
    echo "F2 SWEEP: FAIL"
    exit 1
fi
