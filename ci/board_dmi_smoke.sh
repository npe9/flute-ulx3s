#!/bin/bash
# Virtual-board smoke: `SIM_BLOB=none make sim-board` (nothing preloaded; the boot ROM waits on
# the UART as on the board), then scripts/dmi.py over the pty: debug module version, halt with
# dpc inside the boot ROM, a system-bus SDRAM write/readback, resume; then the board controls
# (build/sim-ctl): a GPIO LED write shows up as "leds XX", and BTN1 pressed there reads back
# through the GPIO button register.  The board top (test/ULX3S_Sim.bsv) reuses the probe-free
# SoC objects that ci/bluesim_gate.sh's sim-repl already built.  Log: build/ci/sim-board.log.
# BOARD=verilator: the Verilator board (sim/linux_bram/linux_run.py --board none) on the already
# built $BUILD_DIR (default obj_dir_lx); it has no board-controls pty, so DMI checks only.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ci
rm -f build/sim-tty build/sim-ctl
set -m                      # the sim gets its own process group, so one kill stops make + the sim
if [ "${BOARD:-bluesim}" = verilator ]; then
    BUILD_DIR="${BUILD_DIR:-obj_dir_lx}" sim/linux_bram/linux_run.py --board none > build/ci/sim-board.log 2>&1 &
    link=build/sim-tty
else
    SIM_BLOB=none make sim-board > build/ci/sim-board.log 2>&1 &
    link=build/sim-ctl      # linked after build/sim-tty
fi
sim=$!
trap 'kill -TERM -- -$sim 2>/dev/null' EXIT
deadline=$((SECONDS + 3600))
until [ -e $link ]; do
    if ! kill -0 $sim 2>/dev/null || [ $SECONDS -gt $deadline ]; then
        tail -20 build/ci/sim-board.log; echo "board smoke: FAIL (no pty)"; exit 1
    fi
    sleep 2
done
# A dead bridge would otherwise sit out dmi.py's sim-scaled timeouts (minutes per request).
timeout 900 python3 -u - <<'PY'
import os, select, sys, time
sys.path.insert(0, "scripts")
import dmi as D

GPIO_LEDS, GPIO_BTN1 = 0xC0002000, 0xC0002004
ctl = os.open("build/sim-ctl", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK) if os.path.exists("build/sim-ctl") else None

def ctl_wait(text, timeout=120):
    buf, t0 = b"", time.time()
    while text not in buf and time.time() - t0 < timeout:
        if select.select([ctl], [], [], 1)[0]:
            buf += os.read(ctl, 4096)
    return text in buf
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
    if ctl is None:
        d.resume()
        print("board smoke: PASS (no board controls on this board)")
        sys.exit(0)
    d.mem_write32(GPIO_LEDS, 0x5A)          # LED7 also shows SDRAM init_done: 0x5A -> 0xDA
    assert ctl_wait(b"leds da"), "LED write not reported on build/sim-ctl"
    print("LEDs 0x5a -> 'leds da' on build/sim-ctl")
    d.mem_write32(GPIO_LEDS, 0)
    for level in (1, 0):
        os.write(ctl, b"%d" % level)
        t0 = time.time()
        while d.mem_read32(GPIO_BTN1) & 1 != level:
            assert time.time() - t0 < 120, f"BTN1 never read {level}"
            time.sleep(0.2)
        print(f"BTN1 {level} read back")
    d.resume()
    print("board smoke: PASS")
finally:
    d.close()
PY
