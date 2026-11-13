#!/bin/bash
# sim/sdh_ut/run.sh: the native SD host against the behavioral card (iverilog)
set -e
cd "$(dirname "$0")"
iverilog -g2012 -o sdh_ut.vvp tb.v ../../src/Sd_Host.v ../common/sd_native_model.v
vvp -n sdh_ut.vvp "$@" | tee sdh_ut.log | grep -v "^ok" || true
grep -q "SDH_UT PASS" sdh_ut.log
