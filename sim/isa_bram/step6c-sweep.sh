#!/bin/bash
# step5d-sweep.sh — F2 8-seed X-sweep (growth-wedged-kill), absolute paths.
set -u
cd "$(dirname "$0")"
OBJ="$1"; OUT="$2"; BIN="$(pwd)/$OBJ/Vsv_tb_top"
mkdir -p "$OUT"
[[ -x "$BIN" ]] || { echo "no binary at $BIN"; exit 2; }

run_one() {
    local seed="$1"
    local log="$OUT/seed-$seed.log"
    ( exec script -q /dev/null env STRICT_BRAM=error "$BIN" \
        "+verilator+coverage+file+$OUT/coverage-$seed.dat" \
        "+verilator+seed+$seed" ) > "$log" 2>&1 &
    local pid=$!
    # Sound wedge rule: the banner prints ~20K cycles in (~1 min at
    # full CPU, seconds even under contention, and ALWAYS flushed via
    # the pty).  No banner within 10 min => the real no-banner wedge
    # class (5x signature).  Once the banner is seen, the seed is
    # healthy: the banner->ACKs window is quiet by design, so let it
    # run to completion (PASS or FAIL) with no growth requirement.
    local polls=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 30; polls=$((polls + 1))
        if grep -q "banner seen" "$log" 2>/dev/null; then
            wait "$pid"
            return 0
        fi
        if [ "$polls" -ge 20 ]; then
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            echo "seed $seed: WEDGED (no banner after $((polls * 30))s)"
            return 1
        fi
    done
    wait "$pid"
    return 0
}

fail=0
run_one 1 & run_one 2 & run_one 3 & run_one 4 & wait
run_one 5 & run_one 6 & run_one 7 & run_one 8 & wait

ref=""
for seed in 1 2 3 4 5 6 7 8; do
    log="$OUT/seed-$seed.log"
    if ! grep -qE "(RESULT|STRICT-SIM): PASS" "$log" 2>/dev/null; then
        echo "seed $seed: FAIL (no PASS)"; fail=1; continue
    fi
    if [ -z "$ref" ]; then
        ref="$log"; grep -v '^- Verilator:' "$log" > "$OUT/.ref.filt"
        echo "seed $seed: PASS (reference)"
    elif ! diff -q "$OUT/.ref.filt" <(grep -v '^- Verilator:' "$log") > /dev/null; then
        echo "seed $seed: OUTPUT DIFFERS:"; diff "$OUT/.ref.filt" <(grep -v '^- Verilator:' "$log") | head -10; fail=1
    else
        echo "seed $seed: PASS (byte-identical)"
    fi
done
if [ "$fail" = 0 ]; then echo "F2 SWEEP 5D: PASS (8/8)"; else echo "F2 SWEEP 5D: FAIL"; fi
exit $fail
