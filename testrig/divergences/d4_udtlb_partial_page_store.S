#>QCVENGINE_TEST_V2.0
# D4 (uDTLB regression, found by campaign5 on V12): a load fills a uDTLB
# entry for the top page 0xFFFF_F000, which is RAM except its last line
# (default harness map: RAM = [0, 0xFFFF_FFC0)); a store to that vacant
# line then hit the entry as memory and lost its store access fault.
#   Sail:  load OK; store traps, mcause 7, mtval = 0xFFFF_FFF0
#   Flute V12 (5a35aa4): no trap
# Fix: fill only pages that are memory end to end; a memory access in a
# partial page re-probes once with rg_pa (rg_udtlb_bypass), no entry.
# Replay: testrig/run_testrig.sh -r rv32imacs_zicsr_zifencei -S -t testrig/divergences/d4_udtlb_partial_page_store.S
.4byte 0x80002083 # lw x1, -2048(x0)   (0xFFFF_F800: RAM, same page)
.4byte 0xfe002823 # sw x0, -16(x0)     (0xFFFF_FFF0: vacant)
