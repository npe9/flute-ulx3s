# D5 (real DUT bug, CSR): sie / sip bits of interrupts not delegated in
# mideleg must read 0 and ignore writes (Sail; priv spec: such bits are
# read-only zero).  With mideleg = 0, `csrrsi x3, sie, 26` set SSIE and the
# next sie read returned 2 (Sail 0).  Pre-dates the uDTLB (reproduces on the
# testrig build).  Fixed in CSR_RegFile_MSU.bsv (sie/sip masked by mideleg).
# Replay: testrig/run_testrig.sh -r rv32imacs_zicsr_zifencei -S -t testrig/divergences/d5_sie_not_masked_by_mideleg.S
#>QCVENGINE_TEST_V2.0
.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000080000004, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x104a21f3 # csrrs x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000080000008, RD: 03, RWD: 0x0000000000000000, I: 0x104a21f3 PRV_M XL:32 (csrrs x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000080000008, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a21f3 PRV_? XL:? (csrrs x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0xea5a01e7 # jalr x3, x20, -347
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x00000000fffffea4, RD: 03, RWD: 0x000000008000000c, I: 0xea5a01e7 PRV_M XL:32 (jalr x3, x20, -347)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x00000000fffffea4, RD: 03, RWD: 0x000000008000000c, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0xea5a01e7 PRV_? XL:? (jalr x3, x20, -347)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x00000000fffffea8, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x8ed19197 # auipc x3, 584985
#      Trap: False, PCWD: 0x00000000fffffeac, RD: 03, RWD: 0x000000008ed18ea8, I: 0x8ed19197 PRV_M XL:32 (auipc x3, 584985)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x00000000fffffeb0, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x00000000fffffeb4, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x00000000fffffeb8, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x00000000fffffebc, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x00000000fffffec0, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x020a02b3 # mul x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x00000000fffffec4, RD: 05, RWD: 0x0000000000000000, I: 0x020a02b3 PRV_M XL:32 (mul x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x00000000fffffec4, RD: 05, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a02b3 PRV_? XL:? (mul x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x041a0183 # lb x3, x20[65]
#                                                                                                                                                                                  ▼    ▼▼
#      Trap: False, PCWD: 0x00000000fffffec8, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00000001 I: 0x041a0183 PRV_M XL:32 (lb x3, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x00000000fffffec8, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00000001 I: 0x041a0183 PRV_? XL:? (lb x3, x20[65])
#                                                                                                                                                                                  ▲    ▲

.4byte 0x104a21f3 # csrrs x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x00000000fffffecc, RD: 03, RWD: 0x0000000000000000, I: 0x104a21f3 PRV_M XL:32 (csrrs x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x00000000fffffecc, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a21f3 PRV_? XL:? (csrrs x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x00000000fffffed0, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x040a20a3 # sw x0, x20[65]
#                                                                                                ▼    ▼▼
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, I: 0x040a20a3 PRV_M XL:32 (sw x0, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x040a20a3 PRV_? XL:? (sw x0, x20[65])
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x140a21af # lr.w x3, x20 (aq)
#                                                                                                                                                                                  ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000004, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x140a21af PRV_M XL:32 (lr.w x3, x20 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000004, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x140a21af PRV_? XL:? (lr.w x3, x20 (aq))
#                                                                                                                                                                                  ▲    ▲

.4byte 0x000a11b3 # sll x3, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000000000000, I: 0x000a11b3 PRV_M XL:32 (sll x3, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x000a11b3 PRV_? XL:? (sll x3, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000000c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x140a21af # lr.w x3, x20 (aq)
#                                                                                                                                                                                  ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000010, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x140a21af PRV_M XL:32 (lr.w x3, x20 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000010, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x140a21af PRV_? XL:? (lr.w x3, x20 (aq))
#                                                                                                                                                                                  ▲    ▲

.4byte 0x041a0183 # lb x3, x20[65]
#                                                                                                                                                                                  ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000014, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00000001 I: 0x041a0183 PRV_M XL:32 (lb x3, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000014, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00000001 I: 0x041a0183 PRV_? XL:? (lb x3, x20[65])
#                                                                                                                                                                                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000018, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000001c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000020, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000024, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000028, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x0c0a21af # amoswap.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000002c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x0c0a21af PRV_M XL:32 (amoswap.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000002c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x0c0a21af PRV_? XL:? (amoswap.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0x020a62b3 # rem x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000030, RD: 05, RWD: 0x0000000000000000, I: 0x020a62b3 PRV_M XL:32 (rem x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000030, RD: 05, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a62b3 PRV_? XL:? (rem x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x104a11f3 # csrrw x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000034, RD: 03, RWD: 0x0000000000000000, I: 0x104a11f3 PRV_M XL:32 (csrrw x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000034, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a11f3 PRV_? XL:? (csrrw x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x8ed19197 # auipc x3, 584985
#      Trap: False, PCWD: 0x0000000000000038, RD: 03, RWD: 0x000000008ed19034, I: 0x8ed19197 PRV_M XL:32 (auipc x3, 584985)

.4byte 0xa40a21af # amomax.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000003c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xa40a21af PRV_M XL:32 (amomax.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000003c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xa40a21af PRV_? XL:? (amomax.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0xea5a0193 # addi x3, x20, -347
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000040, RD: 03, RWD: 0x00000000fffffea5, I: 0xea5a0193 PRV_M XL:32 (addi x3, x20, -347)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000040, RD: 03, RWD: 0x00000000fffffea5, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0xea5a0193 PRV_? XL:? (addi x3, x20, -347)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000044, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000048, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x040a00a3 # sb x0, x20[65]
#                                                                                                                                                                                  ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000004c, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWD: 0x0000000000000000, MWM: 0b00000001, MRM: 0b00000000 I: 0x040a00a3 PRV_M XL:32 (sb x0, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000004c, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWD: 0x0000000000000000, MWM: 0b00000001, MRM: 0b00000000 I: 0x040a00a3 PRV_? XL:? (sb x0, x20[65])
#                                                                                                                                                                                  ▲    ▲

.4byte 0x104a31f3 # csrrc x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000050, RD: 03, RWD: 0x0000000000000000, I: 0x104a31f3 PRV_M XL:32 (csrrc x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000050, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a31f3 PRV_? XL:? (csrrc x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000054, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x0c0a21af # amoswap.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000058, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x0c0a21af PRV_M XL:32 (amoswap.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000058, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x0c0a21af PRV_? XL:? (amoswap.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000005c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000060, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x040a00a3 # sb x0, x20[65]
#                                                                                                                                                                                  ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000064, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWD: 0x0000000000000000, MWM: 0b00000001, MRM: 0b00000000 I: 0x040a00a3 PRV_M XL:32 (sb x0, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000064, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWD: 0x0000000000000000, MWM: 0b00000001, MRM: 0b00000000 I: 0x040a00a3 PRV_? XL:? (sb x0, x20[65])
#                                                                                                                                                                                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000068, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x104d61f3 # csrrsi x3, sie (0x104), 26
#      Trap: False, PCWD: 0x000000000000006c, RD: 03, RWD: 0x0000000000000000, I: 0x104d61f3 PRV_M XL:32 (csrrsi x3, sie (0x104), 26)

.4byte 0xa40a21af # amomax.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000070, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xa40a21af PRV_M XL:32 (amomax.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000070, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xa40a21af PRV_? XL:? (amomax.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000074, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x8330000f # fence.tso
#      Trap: False, PCWD: 0x0000000000000078, RD: 00, RWD: 0x0000000000000000, I: 0x8330000f PRV_M XL:32 (fence.tso)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000007c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x020a72b3 # remu x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000080, RD: 05, RWD: 0x0000000000000000, I: 0x020a72b3 PRV_M XL:32 (remu x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000080, RD: 05, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a72b3 PRV_? XL:? (remu x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x020a32b3 # mulhu x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000084, RD: 05, RWD: 0x0000000000000000, I: 0x020a32b3 PRV_M XL:32 (mulhu x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000084, RD: 05, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a32b3 PRV_? XL:? (mulhu x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000088, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x104d71f3 # csrrci x3, sie (0x104), 26
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000008c, RD: 03, RWD: 0x0000000000000000, I: 0x104d71f3 PRV_M XL:32 (csrrci x3, sie (0x104), 26)
# ╷
# │ ^ A, B v: mismatch in field rd_wdata: 0x0 != 0x2
# ╵
#      Trap: False, PCWD: 0x000000000000008c, RD: 03, RWD: 0x0000000000000002, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104d71f3 PRV_? XL:? (csrrci x3, sie (0x104), 26)
#                                                                           ▲▲▲▲▲▲▲ ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲  ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000090, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x005a5193 # srli x3, x20, 5
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000094, RD: 03, RWD: 0x0000000000000000, I: 0x005a5193 PRV_M XL:32 (srli x3, x20, 5)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000094, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x005a5193 PRV_? XL:? (srli x3, x20, 5)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x041a1183 # lh x3, x20[65]
#                                                                                                ▼    ▼▼
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, I: 0x041a1183 PRV_M XL:32 (lh x3, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x041a1183 PRV_? XL:? (lh x3, x20[65])
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000004, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x041a4183 # lbu x3, x20[65]
#                                                                                                                                                                                  ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00000001 I: 0x041a4183 PRV_M XL:32 (lbu x3, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000041, MWM: 0b00000000, MRD: 0x0000000000000000, MRM: 0b00000001 I: 0x041a4183 PRV_? XL:? (lbu x3, x20[65])
#                                                                                                                                                                                  ▲    ▲

.4byte 0x8ed19197 # auipc x3, 584985
#      Trap: False, PCWD: 0x000000000000000c, RD: 03, RWD: 0x000000008ed19008, I: 0x8ed19197 PRV_M XL:32 (auipc x3, 584985)

.4byte 0xea5a6193 # ori x3, x20, 3749
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000010, RD: 03, RWD: 0x00000000fffffea5, I: 0xea5a6193 PRV_M XL:32 (ori x3, x20, 3749)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000010, RD: 03, RWD: 0x00000000fffffea5, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0xea5a6193 PRV_? XL:? (ori x3, x20, 3749)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000014, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000018, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x0000100f # fence.i
#      Trap: False, PCWD: 0x000000000000001c, RD: 00, RWD: 0x0000000000000000, I: 0x0000100f PRV_M XL:32 (fence.i)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000020, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000024, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0xd40a15e3 # bne x20, x0, -694
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000028, RD: 00, RWD: 0x0000000000000000, I: 0xd40a15e3 PRV_M XL:32 (bne x20, x0, -694)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000028, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0xd40a15e3 PRV_? XL:? (bne x20, x0, -694)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x020a52b3 # divu x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000002c, RD: 05, RWD: 0x00000000ffffffff, I: 0x020a52b3 PRV_M XL:32 (divu x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000002c, RD: 05, RWD: 0x00000000ffffffff, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a52b3 PRV_? XL:? (divu x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x104a31f3 # csrrc x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000030, RD: 03, RWD: 0x0000000000000000, I: 0x104a31f3 PRV_M XL:32 (csrrc x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000030, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a31f3 PRV_? XL:? (csrrc x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x0000100f # fence.i
#      Trap: False, PCWD: 0x0000000000000034, RD: 00, RWD: 0x0000000000000000, I: 0x0000100f PRV_M XL:32 (fence.i)

.4byte 0x020a22b3 # mulhsu x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000038, RD: 05, RWD: 0x0000000000000000, I: 0x020a22b3 PRV_M XL:32 (mulhsu x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000038, RD: 05, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a22b3 PRV_? XL:? (mulhsu x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x041a2183 # lw x3, x20[65]
#                                                                                                ▼    ▼▼
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, I: 0x041a2183 PRV_M XL:32 (lw x3, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x041a2183 PRV_? XL:? (lw x3, x20[65])
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x0000100f # fence.i
#      Trap: False, PCWD: 0x0000000000000004, RD: 00, RWD: 0x0000000000000000, I: 0x0000100f PRV_M XL:32 (fence.i)

.4byte 0x0000100f # fence.i
#      Trap: False, PCWD: 0x0000000000000008, RD: 00, RWD: 0x0000000000000000, I: 0x0000100f PRV_M XL:32 (fence.i)

.4byte 0x040a10a3 # sh x0, x20[65]
#                                                                                                ▼    ▼▼
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, I: 0x040a10a3 PRV_M XL:32 (sh x0, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x040a10a3 PRV_? XL:? (sh x0, x20[65])
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0xd40a65e3 # bltu x20, x0, -694
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000004, RD: 00, RWD: 0x0000000000000000, I: 0xd40a65e3 PRV_M XL:32 (bltu x20, x0, -694)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000004, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0xd40a65e3 PRV_? XL:? (bltu x20, x0, -694)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x000a51b3 # srl x3, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000000000000, I: 0x000a51b3 PRV_M XL:32 (srl x3, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x000a51b3 PRV_? XL:? (srl x3, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x440a21af # amoor.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000000c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x440a21af PRV_M XL:32 (amoor.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000000c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x440a21af PRV_? XL:? (amoor.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000010, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000014, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000018, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x041a5183 # lhu x3, x20[65]
#                                                                                                ▼    ▼▼
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, I: 0x041a5183 PRV_M XL:32 (lhu x3, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x041a5183 PRV_? XL:? (lhu x3, x20[65])
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x020a02b3 # mul x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000004, RD: 05, RWD: 0x0000000000000000, I: 0x020a02b3 PRV_M XL:32 (mul x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000004, RD: 05, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a02b3 PRV_? XL:? (mul x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x000a01b3 # add x3, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000000c, RD: 03, RWD: 0x0000000000000000, I: 0x000a01b3 PRV_M XL:32 (add x3, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000000c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x000a01b3 PRV_? XL:? (add x3, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000010, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000014, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000018, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000001c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000020, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x400a01b3 # sub x3, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000024, RD: 03, RWD: 0x0000000000000000, I: 0x400a01b3 PRV_M XL:32 (sub x3, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000024, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x400a01b3 PRV_? XL:? (sub x3, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x020a42b3 # div x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000028, RD: 05, RWD: 0x00000000ffffffff, I: 0x020a42b3 PRV_M XL:32 (div x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000028, RD: 05, RWD: 0x00000000ffffffff, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a42b3 PRV_? XL:? (div x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x240a21af # amoxor.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000002c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x240a21af PRV_M XL:32 (amoxor.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000002c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0x240a21af PRV_? XL:? (amoxor.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0xe40a21af # amomaxu.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000030, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xe40a21af PRV_M XL:32 (amomaxu.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000030, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xe40a21af PRV_? XL:? (amomaxu.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000034, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x0000100f # fence.i
#      Trap: False, PCWD: 0x0000000000000038, RD: 00, RWD: 0x0000000000000000, I: 0x0000100f PRV_M XL:32 (fence.i)

.4byte 0x0000100f # fence.i
#      Trap: False, PCWD: 0x000000000000003c, RD: 00, RWD: 0x0000000000000000, I: 0x0000100f PRV_M XL:32 (fence.i)

.4byte 0x020a02b3 # mul x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000040, RD: 05, RWD: 0x0000000000000000, I: 0x020a02b3 PRV_M XL:32 (mul x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000040, RD: 05, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a02b3 PRV_? XL:? (mul x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000044, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000048, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000004c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000050, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000054, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000058, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x020a32b3 # mulhu x5, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000005c, RD: 05, RWD: 0x0000000000000000, I: 0x020a32b3 PRV_M XL:32 (mulhu x5, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000005c, RD: 05, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x020a32b3 PRV_? XL:? (mulhu x5, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x0000100f # fence.i
#      Trap: False, PCWD: 0x0000000000000060, RD: 00, RWD: 0x0000000000000000, I: 0x0000100f PRV_M XL:32 (fence.i)

.4byte 0x104a11f3 # csrrw x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000064, RD: 03, RWD: 0x0000000000000000, I: 0x104a11f3 PRV_M XL:32 (csrrw x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000064, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a11f3 PRV_? XL:? (csrrw x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000068, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000006c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000070, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x104d61f3 # csrrsi x3, sie (0x104), 26
#      Trap: False, PCWD: 0x0000000000000074, RD: 03, RWD: 0x0000000000000000, I: 0x104d61f3 PRV_M XL:32 (csrrsi x3, sie (0x104), 26)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000078, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0xc40a21af # amominu.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000007c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xc40a21af PRV_M XL:32 (amominu.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000007c, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xc40a21af PRV_? XL:? (amominu.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000080, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000084, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000088, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x104a11f3 # csrrw x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x000000000000008c, RD: 03, RWD: 0x0000000000000000, I: 0x104a11f3 PRV_M XL:32 (csrrw x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rd_wdata: 0x0 != 0x2, mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x000000000000008c, RD: 03, RWD: 0x0000000000000002, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a11f3 PRV_? XL:? (csrrw x3, sie (0x104), x20)
#                                                                           ▲▲▲▲▲▲▲ ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲  ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x104a11f3 # csrrw x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000090, RD: 03, RWD: 0x0000000000000000, I: 0x104a11f3 PRV_M XL:32 (csrrw x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000090, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a11f3 PRV_? XL:? (csrrw x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000094, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x104a21f3 # csrrs x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000098, RD: 03, RWD: 0x0000000000000000, I: 0x104a21f3 PRV_M XL:32 (csrrs x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000098, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a21f3 PRV_? XL:? (csrrs x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x041a1183 # lh x3, x20[65]
#                                                                                                ▼    ▼▼
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, I: 0x041a1183 PRV_M XL:32 (lh x3, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x041a1183 PRV_? XL:? (lh x3, x20[65])
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x104a11f3 # csrrw x3, sie (0x104), x20
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000004, RD: 03, RWD: 0x0000000000000000, I: 0x104a11f3 PRV_M XL:32 (csrrw x3, sie (0x104), x20)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000004, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x104a11f3 PRV_? XL:? (csrrw x3, sie (0x104), x20)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x0000100f # fence.i
#      Trap: False, PCWD: 0x0000000000000008, RD: 00, RWD: 0x0000000000000000, I: 0x0000100f PRV_M XL:32 (fence.i)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000000c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000010, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000014, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x104d61f3 # csrrsi x3, sie (0x104), 26
#      Trap: False, PCWD: 0x0000000000000018, RD: 03, RWD: 0x0000000000000000, I: 0x104d61f3 PRV_M XL:32 (csrrsi x3, sie (0x104), 26)

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x000000000000001c, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0xc40a21af # amominu.w x3, x20, x0 (aq)
#                                                                                                                                                                                                           ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000020, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xc40a21af PRV_M XL:32 (amominu.w x3, x20, x0 (aq))
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000020, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWD: 0x0000000000000000, MWM: 0b00001111, MRD: 0x0000000000000000, MRM: 0b00001111 I: 0xc40a21af PRV_? XL:? (amominu.w x3, x20, x0 (aq))
#                                                                                                                                                                                                           ▲    ▲

.4byte 0x041a2183 # lw x3, x20[65]
#                                                                                                ▼    ▼▼
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, I: 0x041a2183 PRV_M XL:32 (lw x3, x20[65])
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap:  True, PCWD: 0x0000000000000000, RD: 00, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x041a2183 PRV_? XL:? (lw x3, x20[65])
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

.4byte 0x800081b7 # lui x3, 524296
#      Trap: False, PCWD: 0x0000000000000004, RD: 03, RWD: 0x0000000080008000, I: 0x800081b7 PRV_M XL:32 (lui x3, 524296)

.4byte 0x400a01b3 # sub x3, x20, x0
#                                                                                                ▼    ▼▼
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000000000000, I: 0x400a01b3 PRV_M XL:32 (sub x3, x20, x0)
# ╷
# │ ^ A, B v: mismatch in field rs1_addr: 0 != 20
# ╵
#      Trap: False, PCWD: 0x0000000000000008, RD: 03, RWD: 0x0000000000000000, MA: 0x0000000000000000, MWM: 0b00000000, MRM: 0b00000000 I: 0x400a01b3 PRV_? XL:? (sub x3, x20, x0)
#                                                                              ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲                  ▲    ▲

# Test end
#      halt token
