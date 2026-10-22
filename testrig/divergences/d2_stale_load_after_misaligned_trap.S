#>QCVENGINE_TEST_V2.0
# D2 (real DUT bug, D-cache): the first load that HITS in the D-cache after a
# misaligned load/store exception returns stale data -- the cword of the
# previous D-cache BRAM read -- instead of the addressed data.
#   Sail:  lbu x13, 0(x3) -> 0x1 (the value just stored)
#   Flute: lbu x13, 0(x3) -> 0x0 (the value the earlier lw read)
# Only the first hit after the trap is wrong; later loads are correct.
# Not triggered by ecall (no D-cache request), nor when that first load
# misses (refill path).  The misaligned access may be to any address
# (e.g. an uncached 0x40000001).  Suspected: MMU_Cache req() takes the
# MODULE_EXCEPTION_RSP path without fa_req_ram_B, and the registered BRAM
# output (rg_tag_ram_q/rg_data_ram_q, +1 cycle hit latency) is then
# consumed stale by the next request's probe.  Not fixed (core RTL).
# Replay: testrig/run_testrig.sh -r rv32imacs_zicsr_zifencei -S -t testrig/divergences/d2_stale_load_after_misaligned_trap.S
.4byte 0x800081b7 # lui x3, 0x80008
.4byte 0x00100113 # addi x2, x0, 1
.4byte 0x0001a683 # lw x13, 0(x3)
.4byte 0x0021a023 # sw x2, 0(x3)
.4byte 0x00011683 # lh x13, 0(x2)
.4byte 0x0001c683 # lbu x13, 0(x3)
