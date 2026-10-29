#!/bin/bash
# Virtual-board smoke: `SIM_BLOB=none make sim-board` (nothing preloaded; the boot ROM waits on
# the UART as on the board), then scripts/dmi.py over the pty: debug module version, halt with
# dpc inside the boot ROM, a system-bus SDRAM write/readback, resume.  Uses the probe-free REPL
# TB build that ci/bluesim_gate.sh already made.  Log: build/ci/sim-board.log.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ci
rm -f build/sim-tty
set -m                      # the sim gets its own process group, so one kill stops make + the sim
SIM_BLOB=none make sim-board > build/ci/sim-board.log 2>&1 &
sim=$!
trap 'kill -TERM -- -$sim 2>/dev/null' EXIT
deadline=$((SECONDS + 3600))
until [ -e build/sim-tty ]; do
    if ! kill -0 $sim 2>/dev/null || [ $SECONDS -gt $deadline ]; then
        tail -20 build/ci/sim-board.log; echo "board smoke: FAIL (no pty)"; exit 1
    fi
    sleep 2
done
python3 - <<'PY'
import sys
sys.path.insert(0, "scripts")
import dmi as D
d = D.DMI("build/sim-tty")
try:
    st = d.arm()
    print(f"dmstatus {st:#010x}")
    assert st & 0xF == 2, "debug module version != 0.13"
    d.halt()
    pc = d.read_csr(D.CSR_DPC)
    print(f"halted, dpc {pc:#x}")
    assert 0x1000 <= pc < 0x10000, "dpc outside the boot ROM"
    d.mem_write32(0x80020000, 0xCAFEF00D)
    v = d.mem_read32(0x80020000)
    print(f"SDRAM 0x80020000 = {v:#010x}")
    assert v == 0xCAFEF00D, "system-bus readback mismatch"
    d.resume()
    print("board smoke: PASS")
finally:
    d.close()
PY
