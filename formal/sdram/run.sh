#!/bin/bash
# formal/sdram/run.sh: the whole SDRAM proof.  Who relies on whom (no cycles):
#   fifo.sby prove_fifo   SizedFIFO full/empty contract          <- nothing
#   prove_init            init order, MRS once, state at the MRS <- nothing
#   prove_handoff         refresh gap at the MRS (BMC, init takes no inputs) <- nothing
#   prove_timing          JEDEC timings                          <- nothing
#   prove_credit          read credit, delivery times            <- FIFO contract
#   prove_refresh         refresh gap bound                      <- MRS state + gap, credit
#   prove_decode          commands match the request             <- MRS state, credit, init (no RW before MRS)
#   prove_k               read and write data                    <- credit
# cover and bmc_deep then run everything together on the real FIFO, assuming none of the hand-offs.
set -u
cd "$(dirname "$0")"; rc=0
rm -f ../../build/vid/boot_loader.memhex; make -C ../.. -s formal-sdram-verilog >/dev/null || exit 1
one() { f=$1; t=$2; timeout "${LIMIT:-3600}" sby -f "$f" "$t" >/dev/null 2>&1
        d="${f%.sby}_$t"; r=$(LC_ALL=C grep -o 'DONE ([A-Z]*' "$d/logfile.txt" | tr -d '(' | awk '{print $2}'); echo "$t: ${r:-TIMEOUT}"; [ "$r" = PASS ] || rc=1; }
one fifo.sby prove_fifo; one fifo.sby cover
for t in prove_init prove_handoff prove_timing prove_credit prove_refresh prove_decode prove_k cover; do one sdram.sby $t; done
# cross-check on the real FIFO with no hand-off assumed: a bound, reported as the frames reached
keep=$rc; one sdram.sby bmc_deep; rc=$keep; LC_ALL=C grep -E 'Resource limit|No output asserted' sdram_bmc_deep/logfile.txt | tail -1
exit $rc
