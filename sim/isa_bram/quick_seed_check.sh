#!/bin/bash
# Quick hang check: boot each named seed and watch for the banner line.
# A hanging draw never prints "banner seen" — kill after the deadline.
cd "$(dirname "$0")"
for seed in "$@"; do
    log="/tmp/j1_quick_seed$seed.log"
    STRICT_BRAM=warn ./obj_dir/Vsv_tb_top +verilator+seed+$seed > "$log" 2>&1 &
    pid=$!
    for i in $(seq 1 48); do   # up to ~4 min per seed
        if grep -q "banner seen" "$log" 2>/dev/null; then break; fi
        if ! kill -0 $pid 2>/dev/null; then break; fi
        sleep 5
    done
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    line=$(grep "banner seen" "$log" 2>/dev/null)
    if [[ -n "$line" ]]; then
        echo "seed $seed: BOOT OK ($line)"
    else
        echo "seed $seed: NO BANNER (still hangs)"
    fi
done
