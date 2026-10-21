#!/bin/bash
# step5c-sweep.sh — F2-style 8-seed X-sweep for the step5c bounded-spec
# netlist.  A seed is wedged (the no-banner signature) iff its log shows
# ZERO GROWTH over repeated polls (a live boot's UART TX grows the log
# steadily); growth-based kill only, no absolute size/deadline traps.
#
# Usage: ./step5c-sweep.sh <obj_dir> <outdir> [batch_size]
set -uo pipefail
cd "$(dirname "$0")"
OBJ="$1"; OUT="$2"; BATCH="${3:-4}"; BIN="$OBJ/Vsv_tb_top"
mkdir -p "$OUT"
[[ -x "$BIN" ]] || { echo "no binary at $BIN"; exit 2; }

run_seed() { # $1 = seed
    local seed="$1" log="$OUT/seed-$seed.log"
    ( STRICT_BRAM=error "$BIN" \
        "+verilator+coverage+file+$OUT/coverage-$seed.dat" \
        "+verilator+seed+$seed" > "$log" 2>&1 ) &
    local pid=$!
    local last=0 same=0 polls=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 30; polls=$(( polls + 1 ))
        sz=$(stat -f%z "$log" 2>/dev/null || echo 0)
        if (( sz == last )); then same=$(( same + 1 )); else same=0; fi
        last=$sz
        if (( same >= 4 )); then
            kill "$pid" 2>/dev/null
            echo "seed $seed: WEDGED (log stuck at ${sz}B after $(( polls * 30 ))s, killed)"
            wait "$pid" 2>/dev/null
            return 1
        fi
        if (( polls >= 40 )); then
            kill "$pid" 2>/dev/null
            echo "seed $seed: TIMEOUT (40 polls, ${sz}B)"
            wait "$pid" 2>/dev/null
            return 1
        fi
    done
    wait "$pid"
}

fail=0
for (( b=0; b<8; b+=BATCH )); do
    pids=()
    for (( s=b+1; s<=b+BATCH && s<=8; s++ )); do
        run_seed "$s" & pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || fail=1; done
done

ref=""
for seed in 1 2 3 4 5 6 7 8; do
    log="$OUT/seed-$seed.log"
    if ! grep -q "RESULT: PASS" "$log"; then
        echo "seed $seed: FAIL (no PASS)"; fail=1; continue
    fi
    filt() { grep -v '^- Verilator:' "$1"; }
    if [[ -z "$ref" ]]; then ref="$log"; filt "$log" > "$OUT/.ref.filt"
    elif ! diff -q "$OUT/.ref.filt" <(filt "$log") > /dev/null; then
        echo "seed $seed: OUTPUT DIFFERS:"; diff "$OUT/.ref.filt" <(filt "$log") | head -10; fail=1
    else
        echo "seed $seed: PASS (byte-identical)"
    fi
done
(( fail == 0 )) && echo "F2 SWEEP 5C: PASS (8/8)" || echo "F2 SWEEP 5C: FAIL"
exit $fail
