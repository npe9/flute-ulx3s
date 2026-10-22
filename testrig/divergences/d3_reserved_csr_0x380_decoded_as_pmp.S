#>QCVENGINE_TEST_V2.0
# D3 (real DUT bug, CSR decode): CSR numbers 0x380-0x39F and 0x3F0-0x3FF are
# accepted as PMP CSRs instead of raising illegal-instruction.
#   Sail:  csrrs x1, 0x380, x0 -> illegal instruction trap (mcause 2)
#   Flute: no trap, x1 = 0
# Cause: Flute/src_Core/RegFiles/PMP.bsv fv_is_pmp_csr matches a[11:6] ==
# 6'b001110 / 6'b001111, i.e. 0x380-0x3FF, wider than pmpaddr0-63 (0x3B0-0x3EF).
# (0x3C0-0x3EF = pmpaddr16-63 exist per spec as WARL zero; Sail with
# --pmp-count 16 traps on them instead -- a config difference, not this bug.)
# Not fixed (core RTL).
# Replay: testrig/run_testrig.sh -r rv32imacs_zicsr_zifencei -S -t testrig/divergences/d3_reserved_csr_0x380_decoded_as_pmp.S
.4byte 0x380020f3 # csrrs x1, 0x380, x0
