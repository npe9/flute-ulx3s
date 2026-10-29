#!/bin/bash
# Bluesim boot gate: (1) boot ROM loads sw/hello.bin over the simulated UART into the SDRAM model
# and hello prints its banner; (2) the TempleOS HolyC REPL image (preloaded) reaches its prompt
# and answers '1+1;' with 2; (3) the virtual board (make sim-board) answers DMI over its pty.
# Judged on the decoded UART TX stream, not on exit codes (Bluesim $finish exits 0 either way).
# Logs: build/ci/.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ci
# TempleOS REPL image from source when the templeos/tos submodule is checked out (else
# test/sim_preload.c falls back to templeos/prebuilt/).
if [ -f templeos/tos/Makefile ]; then
    make -C templeos holyc repl > build/ci/templeos.log 2>&1 || { tail -30 build/ci/templeos.log; exit 1; }
    echo "templeos: built $(ls -l templeos/build/ulx3s_repl.blob.bin | awk '{print $5}') byte REPL image from source"
fi
# bsc -u does not see -D changes: a probe-free build needs its own bdir.
rm -rf build/bsc-sim-boot build/sim-boot
make sim-boot SIM_BOOT_PROBES= > build/ci/sim-boot.log 2>&1
python3 - build/ci/sim-boot.log <<'PY' || exit 1
import re, sys
txt = ''.join(re.findall(r'TX: (.)', open(sys.argv[1], encoding='latin-1').read(), re.S))
print('sim-boot console:', repr(txt[-200:]))
ok = 'Hello from Flute' in txt
print('sim-boot:', 'PASS' if ok else 'FAIL (no hello banner)'); sys.exit(0 if ok else 1)
PY
make SIM_REPL_PROBES= sim-repl > build/ci/sim-repl.log 2>&1
python3 - build/ci/sim-repl.log <<'PY' || exit 1
import re, sys
log = open(sys.argv[1], encoding='latin-1').read()
txt = ''.join(chr(int(h, 16)) for h in re.findall(r'\[tb\] txc ([0-9a-f]{2})', log))
print('sim-repl console tail:', repr(txt[-300:]))
prompt = '[tb] prompt seen' in log
after = txt.split('1+1;', 1)[1] if '1+1;' in txt else ''
answered = re.search(r'=\s*2\b', after) is not None
print(f'prompt={prompt} answered={answered}')
ok = prompt and answered
print('sim-repl:', 'PASS' if ok else 'FAIL'); sys.exit(0 if ok else 1)
PY
ci/board_dmi_smoke.sh || exit 1
echo "bluesim gate: PASS"
