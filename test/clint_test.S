# Bare-metal CLINT test for the ULX3S Flute SoC (E22 gate: near_mem_io two-stage read/write).
# CLINT at 0x02000000: msip +0x0, mtimecmp +0x4000/+0x4004, mtime +0xBFF8/+0xBFFC.
# UART: 'T', 'M <id> <exp> <got>' per mismatch, 'D'.  Checks: mtime advances; mtime and
# mtimecmp write/read-back through both 32-bit halves; back-to-back write then read of the
# same register; msip -> mip.MSIP set/clear; mtimecmp <= mtime -> mip.MTIP, mtimecmp max ->
# MTIP clear; a read at an unmapped CLINT offset -> load access fault; a write there is not
# reported (write-through stores; baseline behaviour).
# Interrupts stay disabled (mie = 0), so MSIP/MTIP are only observed in mip.
    .section .text
    .globl _start
    .option norvc

.macro CHK id, got, exp
    li   t0, \exp
    beq  \got, t0, 99f
    li   t2, 'M'
    sw   t2, 0(s0)
    li   a1, \id
    jal  ra, puthex
    mv   a1, t0
    jal  ra, puthex
    mv   a1, \got
    jal  ra, puthex
99:
.endm

_start:
    li   sp, 0x81000000
    li   s0, 0xC0000000
    li   t0, 'T'
    sw   t0, 0(s0)
    csrw mie, x0
    la   a3, handler
    csrw mtvec, a3
    li   s1, 0x02000000        # msip
    li   s2, 0x02004000        # mtimecmp
    li   s3, 0x0200BFF8        # mtime

    # ---- mtime advances
    lw   a2, 0(s3)
    nop
    nop
    nop
    lw   a4, 0(s3)
    sltu a5, a2, a4
    CHK  0x01, a5, 1

    # ---- mtime write via both halves, read back
    sw   x0, 0(s3)
    li   a3, 5
    sw   a3, 4(s3)
    li   a3, 0x100
    sw   a3, 0(s3)
    lw   a2, 4(s3)
    lw   a4, 0(s3)
    CHK  0x02, a2, 5
    li   a5, 0x100
    sltu a6, a4, a5            # lo >= 0x100
    CHK  0x03, a6, 0
    li   a5, 0x10000
    sltu a6, a4, a5            # lo < 0x10000
    CHK  0x04, a6, 1

    # ---- mtimecmp write/read back (both halves), back to back
    li   a3, 0x89abcdef
    sw   a3, 0(s2)
    lw   a2, 0(s2)
    CHK  0x05, a2, 0x89abcdef
    li   a3, 0x01234567
    sw   a3, 4(s2)
    lw   a2, 4(s2)
    lw   a4, 0(s2)
    CHK  0x06, a2, 0x01234567
    CHK  0x07, a4, 0x89abcdef

    # ---- MTIP: mtimecmp = 0 (<= mtime) -> pending
    sw   x0, 4(s2)
    sw   x0, 0(s2)
    li   a5, 50
1:  addi a5, a5, -1
    bnez a5, 1b
    csrr a2, mip
    andi a2, a2, 0x80
    CHK  0x08, a2, 0x80
    # mtimecmp = max -> clear
    li   a3, -1
    sw   a3, 0(s2)
    sw   a3, 4(s2)
    li   a5, 50
1:  addi a5, a5, -1
    bnez a5, 1b
    csrr a2, mip
    andi a2, a2, 0x80
    CHK  0x09, a2, 0
    lw   a2, 4(s2)
    CHK  0x0a, a2, 0xffffffff

    # ---- MSIP -> mip.MSIP
    li   a3, 1
    sw   a3, 0(s1)
    lw   a2, 0(s1)
    CHK  0x0b, a2, 1
    li   a5, 50
1:  addi a5, a5, -1
    bnez a5, 1b
    csrr a2, mip
    andi a2, a2, 0x8
    CHK  0x0c, a2, 8
    sw   x0, 0(s1)
    lw   a2, 0(s1)
    CHK  0x0d, a2, 0
    li   a5, 50
1:  addi a5, a5, -1
    bnez a5, 1b
    csrr a2, mip
    andi a2, a2, 0x8
    CHK  0x0e, a2, 0

    # ---- unmapped CLINT offset: load and store access faults
    li   s6, 0
    li   a4, 0x02000100
    li   a2, 0x5555
    lw   a2, 0(a4)
    CHK  0x0f, s6, 5           # load access fault
    CHK  0x10, a2, 0x5555      # rd unwritten
    li   s6, 0
    sw   a2, 0(a4)
    fence                      # store fault may be imprecise
    li   a5, 50
1:  addi a5, a5, -1
    bnez a5, 1b
    mv   a2, s6
    # Baseline (E21 and earlier): the store's bus error is NOT reported -- write-through
    # stores are fire-and-forget, so no store access fault is raised.  Checked as 0 so a
    # change in that behaviour shows up.
    CHK  0x11, a2, 0

    # ---- the CLINT still answers after the faults
    lw   a2, 4(s2)
    CHK  0x12, a2, 0xffffffff

    li   t0, 'D'
    sw   t0, 0(s0)
9:  wfi
    j    9b

    .align 2
handler:
    csrr s6, mcause
    csrr s7, mepc
    addi s7, s7, 4
    csrw mepc, s7
    mret

puthex:
    li   t3, 8
    li   t4, 28
ph1: srl  t5, a1, t4
    andi t5, t5, 0xf
    li   t6, 10
    blt  t5, t6, ph2
    addi t5, t5, 'a' - 10
    j    ph3
ph2: addi t5, t5, '0'
ph3: sw   t5, 0(s0)
    addi t3, t3, -1
    addi t4, t4, -4
    bgez t4, ph1
    li   t5, 13
    sw   t5, 0(s0)
    li   t5, 10
    sw   t5, 0(s0)
    ret
