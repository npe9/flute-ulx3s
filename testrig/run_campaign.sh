#!/bin/bash
# run_campaign.sh OUTDIR N GEN...   (GEN = QCVEngine template name, or 'bk' for
# the B/Zkn trace directory made by gen_bk_traces.py)
# Runs each generator for N tests, no shrinking, continuing past failures and
# saving every failure (re-run with the mcause/mtval suffix) to OUTDIR/GEN/fail,
# then classifies the saved failures (classify_failures.py).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$1"; N="$2"; shift 2
ARCH="${ARCH:-rv32imacs_zicsr_zifencei}"
# CSRs whose existence/behaviour is a platform choice where Sail and Flute differ
# (README "Configuration"): HPM counters/events/mcountinhibit, PMP entries 8-15,
# cycle/time counter values (not lockstep-comparable), mip (Sail's CLINT has
# mtimecmp = 0, so MTIP is always pending; the DUT ties its timer interrupt off).
CSRX="${CSRX:-mhpm|hpmcounter|mcountinhibit|pmpaddr([89]|1[0-5])|pmpcfg[23]|cycle|time|^mip$}"
mkdir -p "$OUT"
for g in "$@"; do
    d="$OUT/$g"; mkdir -p "$d/fail"
    if [ "$g" = bk ]; then
        BK="${BK:-$OUT/bk-traces}"
        [ -d "$BK" ] || python3 "$HERE/gen_bk_traces.py" "$BK" "$N" 1 24
        "$HERE/run_testrig.sh" -o "$d" -r "$ARCH" -S --continue-on-fail -s "$d/fail" -d "$BK" > /dev/null 2>&1
        echo "$g: traces $(ls "$BK"/*.S | wc -l) failed $(grep -ac '^Failure\.' "$d/qcv.log") saved $(ls "$d/fail" | wc -l)"
    else
        "$HERE/run_testrig.sh" -o "$d" -r "$ARCH" -I "^$g\$" -n "$N" -S --continue-on-fail -s "$d/fail" \
            --csr-exclude-regex "$CSRX" > /dev/null 2>&1
        echo "$g: requested $N, falsified $(grep -ac 'Falsified (after [0-9]* tests\?):' "$d/qcv.log"), saved $(ls "$d/fail" | wc -l), last: $(grep -a 'OK, passed\|Gave up' "$d/qcv.log" | tail -1)"
    fi
    python3 "$HERE/classify_failures.py" "$d/fail" | tail -1
done
