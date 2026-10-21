# Bare-metal Zicsr test for the ULX3S Flute SoC (E21 gate: CSRRx writes moved to a third
# cycle, CPU_CSRRX_3).  Loaded at 0x80000000 by the UART boot loader, like amo_test.S.
# UART (16550 @ 0xC0000000): 'T' on entry, 'M <id> <exp> <got>' per mismatch, 'D' when done.
# Covers CSRRW/RS/RC and the immediate forms (old value in rd, new value in the CSR),
# rd = x0, rs1 = x0 (read only), CSR write then immediate read-back and immediate use of
# rd, back-to-back CSR writes, mtvec/mepc/mcause/mtval through ECALL and an illegal write to
# a read-only CSR (rd must stay unwritten), the hardwired-zero mhpm ranges, mstatus.MIE.
# Build: riscv64-unknown-elf-gcc -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles
#   -Wl,-Ttext=0x80000000 -o csr_test.elf csr_test.S; objcopy -O binary; pad to 4 bytes.

    .section .text
    .globl _start
    .option norvc

# CHK id, got, exp   (got must not be a1/t0/t2-t6)
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

    # ---- CSRRW: write, read back, swap returns the old value
    li   a3, 0x12345678
    csrw mscratch, a3
    csrr a2, mscratch
    CHK  0x01, a2, 0x12345678
    li   a3, 0xcafef00d
    csrrw a2, mscratch, a3
    csrr a4, mscratch
    CHK  0x02, a2, 0x12345678
    CHK  0x03, a4, 0xcafef00d

    # ---- the CSRRx rd used by the very next instruction
    li   a3, 41
    csrw mscratch, a3
    csrr a2, mscratch
    addi a2, a2, 1
    CHK  0x04, a2, 42

    # ---- back-to-back writes, last one wins
    li   a3, 0x11111111
    li   a4, 0x22222222
    csrw mscratch, a3
    csrw mscratch, a4
    csrr a2, mscratch
    CHK  0x05, a2, 0x22222222

    # ---- CSRRS / CSRRC
    li   a3, 0x0000ff00
    csrw mscratch, a3
    li   a4, 0x000000f0
    csrrs a2, mscratch, a4
    csrr a5, mscratch
    CHK  0x06, a2, 0x0000ff00
    CHK  0x07, a5, 0x0000fff0
    li   a4, 0x00000f00
    csrrc a2, mscratch, a4
    csrr a5, mscratch
    CHK  0x08, a2, 0x0000fff0
    CHK  0x09, a5, 0x0000f0f0

    # ---- immediate forms
    csrrwi a2, mscratch, 0x15
    csrr a5, mscratch
    CHK  0x0a, a2, 0x0000f0f0
    CHK  0x0b, a5, 0x15
    csrrsi a2, mscratch, 0x0a
    csrr a5, mscratch
    CHK  0x0c, a2, 0x15
    CHK  0x0d, a5, 0x1f
    csrrci a2, mscratch, 0x03
    csrr a5, mscratch
    CHK  0x0e, a2, 0x1f
    CHK  0x0f, a5, 0x1c

    # ---- rs1 = x0 / uimm = 0: read only, CSR unchanged
    csrrs a2, mscratch, x0
    csrrc a4, mscratch, x0
    csrrsi a5, mscratch, 0
    csrr a6, mscratch
    CHK  0x10, a2, 0x1c
    CHK  0x11, a4, 0x1c
    CHK  0x12, a5, 0x1c
    CHK  0x13, a6, 0x1c

    # ---- rd = x0 still writes the CSR
    li   a3, 0x5a5a5a5a
    csrrw x0, mscratch, a3
    csrr a2, mscratch
    CHK  0x14, a2, 0x5a5a5a5a

    # ---- read-only CSR read through csrrs x0 is permitted
    csrr a2, mhartid
    CHK  0x15, a2, 0

    # ---- hardwired-zero mhpm ranges: writes accepted, read back 0
    li   a3, 0x77
    csrw mhpmcounter3, a3
    csrr a2, mhpmcounter3
    csrw mhpmevent31, a3
    csrr a4, mhpmevent31
    csrw mhpmcounter17h, a3
    csrr a5, mhpmcounter17h
    CHK  0x16, a2, 0
    CHK  0x17, a4, 0
    CHK  0x18, a5, 0

    # ---- mtvec + ECALL: handler records mcause/mepc, skips the ECALL
    la   a3, handler
    csrw mtvec, a3
    csrr a2, mtvec
    sub  a2, a2, a3
    CHK  0x19, a2, 0
    li   s6, 0
    li   s7, 0
ecall_pc:
    ecall
    CHK  0x1a, s6, 11
    la   a3, ecall_pc
    sub  a2, s7, a3
    CHK  0x1b, a2, 0

    # ---- illegal: write to read-only mvendorid -> mcause 2, rd unwritten, mscratch intact
    li   a5, 0x0badc0de
    li   s6, 0
    li   s7, 0
illegal_pc:
    csrrw a5, mvendorid, a3
    CHK  0x1c, s6, 2
    la   a3, illegal_pc
    sub  a2, s7, a3
    CHK  0x1d, a2, 0
    CHK  0x1e, a5, 0x0badc0de
    csrr a2, mscratch
    CHK  0x1f, a2, 0x5a5a5a5a

    # ---- mepc written by CSRRW, then MRET goes there
    la   a3, after_mret
    csrw mepc, a3
    li   a3, 0x1800            # mstatus.MPP = M
    csrs mstatus, a3
    mret
    li   t2, 'X'               # skipped
    sw   t2, 0(s0)
after_mret:

    # ---- mstatus.MIE set/clear (interrupts stay disabled in mie)
    csrw mie, x0
    csrsi mstatus, 0x8
    csrr a2, mstatus
    andi a2, a2, 0x8
    CHK  0x20, a2, 8
    csrci mstatus, 0x8
    csrr a2, mstatus
    andi a2, a2, 0x8
    CHK  0x21, a2, 0

    li   t0, 'D'
    sw   t0, 0(s0)
9:  wfi
    j    9b

    .align 2
handler:
    csrr s6, mcause
    csrr s7, mepc
    addi s8, s7, 4
    csrw mepc, s8
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
