#>QCVENGINE_TEST_V2.0
# D1 (real DUT bug, D-side store errors): a store/AMO to a vacant physical
# address completes without a store access fault.  Loads do fault.
#   Sail:  trap, mcause 7 (store/AMO access fault), mtval = address
#   Flute: no trap
# Cause: MMU_Cache's write-through/IO store path does not turn the fabric
# write error (AXI BRESP SLVERR) into a precise exception; the error is only
# latched (rg_wr_rsp_err / mv_status).  Not fixed (core RTL).
#
# Default harness map (RAM = [0, 0xFFFF_FFC0)): store to 0xFFFF_FFF0.
# Replay: testrig/run_testrig.sh -r rv32imacs_zicsr_zifencei -S -t testrig/divergences/d1_vacant_store_no_fault.S
# Sail's default map (RAM8M=1: 8 MiB at 0x8000_0000): `sb x20, 2(x0)` (0x01400123) also shows it.
.4byte 0xfe002823 # sw x0, -16(x0)
