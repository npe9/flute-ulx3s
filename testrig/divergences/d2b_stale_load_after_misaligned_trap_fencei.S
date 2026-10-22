#>QCVENGINE_TEST_V2.0
# D2 family, second form (real DUT bug, D-cache): with FENCE.I between the
# misaligned trap and the access, a later load MISS also returns stale data.
# Delta-debugged (testrig/minimize.py) from a QCVEngine 'cache' failure.
#   x3 = 0, x2 = 0 at reset.  lh 0x41 traps (misaligned); sh 0x104 -> 0x104
#   is written to memory and the refill of line 0x100 carries it (see
#   +dii_memtrace), yet the lw returns 0.  Sail: 0x104, Flute: 0x0.
# Removing the lh, either fence.i, or the lbu makes it pass.
# Replay: testrig/run_testrig.sh -r rv32imacs_zicsr_zifencei -S -t testrig/divergences/d2b_stale_load_after_misaligned_trap_fencei.S
.4byte 0x04110113 # addi x2, x2, 65
.4byte 0x00018683 # lb x13, x3[0]
.4byte 0x00011683 # lh x13, x2[0]
.4byte 0x0000100f # fence.i
.4byte 0x0001c683 # lbu x13, x3[0]
.4byte 0x0000100f # fence.i
.4byte 0x00211113 # slli x2, x2, 2
.4byte 0x00211023 # sh x2, x2[0]
.4byte 0x00012683 # lw x13, x2[0]
