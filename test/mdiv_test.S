# Bare-metal M-extension test for the ULX3S Flute SoC (E26 gate: MBox launched one cycle
# after the op enters stage2, from the registered stage2 contents).  Loaded at 0x80000000
# by the UART boot loader, like csr_test.S.
# UART (16550 @ 0xC0000000): 'T' on entry, 'M <id> <exp> <got>' per mismatch, 'D' when done.
# Covers MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU incl. divide-by-zero and signed overflow,
# back-to-back dependent M ops (the hazard: stage2 taking the PREVIOUS op's still-valid MBox
# result during the pending-launch cycle), an M op right after a load hit and before a
# store, and a mul accumulation loop.
# Build: riscv64-unknown-elf-gcc -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles
#   -Wl,-Ttext=0x80000000 -o mdiv_test.elf mdiv_test.S; objcopy -O binary; pad to 4 bytes.

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

    # ---- basic ops
    li   a3, 7
    li   a4, 6
    mul  a2, a3, a4
    CHK  0x01, a2, 42
    li   a3, -1
    li   a4, -1
    mulh a2, a3, a4
    CHK  0x02, a2, 0
    li   a3, 0x80000000
    mulh a2, a3, a3
    CHK  0x03, a2, 0x40000000
    li   a3, 0xffffffff
    mulhu a2, a3, a3
    CHK  0x04, a2, 0xfffffffe
    li   a3, -1
    li   a4, 0xffffffff
    mulhsu a2, a3, a4
    CHK  0x05, a2, 0xffffffff
    li   a3, 100
    li   a4, 7
    div  a2, a3, a4
    CHK  0x06, a2, 14
    rem  a2, a3, a4
    CHK  0x07, a2, 2
    li   a3, -100
    div  a2, a3, a4
    CHK  0x08, a2, 0xfffffff2
    rem  a2, a3, a4
    CHK  0x09, a2, 0xfffffffe
    li   a3, 0xffffffff
    li   a4, 2
    divu a2, a3, a4
    CHK  0x0a, a2, 0x7fffffff
    remu a2, a3, a4
    CHK  0x0b, a2, 1

    # ---- divide by zero, signed overflow
    li   a3, 1234
    li   a4, 0
    div  a2, a3, a4
    CHK  0x10, a2, 0xffffffff
    divu a2, a3, a4
    CHK  0x11, a2, 0xffffffff
    rem  a2, a3, a4
    CHK  0x12, a2, 1234
    remu a2, a3, a4
    CHK  0x13, a2, 1234
    li   a3, 0x80000000
    li   a4, -1
    div  a2, a3, a4
    CHK  0x14, a2, 0x80000000
    rem  a2, a3, a4
    CHK  0x15, a2, 0

    # ---- back-to-back M ops, each consuming the previous result
    li   a3, 3
    li   a4, 5
    mul  a2, a3, a4          # 15
    mul  a5, a2, a2          # 225
    div  a6, a5, a3          # 75
    rem  a7, a6, a4          # 0
    mul  s2, a6, a4          # 375
    divu s3, s2, a2          # 25
    CHK  0x20, a2, 15
    CHK  0x21, a5, 225
    CHK  0x22, a6, 75
    CHK  0x23, a7, 0
    CHK  0x24, s2, 375
    CHK  0x25, s3, 25
    # independent back-to-back (different results; a stale one shows as a repeat)
    li   a3, 11
    li   a4, 13
    mul  a2, a3, a3          # 121
    mul  a5, a4, a4          # 169
    div  a6, a4, a3          # 1
    divu a7, a5, a3          # 15
    remu s2, a5, a3          # 4
    mul  s3, a3, a4          # 143
    CHK  0x26, a2, 121
    CHK  0x27, a5, 169
    CHK  0x28, a6, 1
    CHK  0x29, a7, 15
    CHK  0x2a, s2, 4
    CHK  0x2b, s3, 143

    # ---- M op right after a load hit, result stored and reloaded
    la   s4, buf
    li   a3, 0x1234
    sw   a3, 0(s4)
    lw   a3, 0(s4)           # miss or hit; again for a sure hit
    lw   a3, 0(s4)
    li   a4, 3
    mul  a2, a3, a4          # 0x369c
    sw   a2, 4(s4)
    lw   a5, 4(s4)
    divu a6, a5, a4          # 0x1234
    sw   a6, 8(s4)
    lw   a7, 8(s4)
    CHK  0x30, a2, 0x369c
    CHK  0x31, a5, 0x369c
    CHK  0x32, a7, 0x1234

    # ---- loop: sum of i*i, i = 1..20 = 2870; and sum of (1000 / i)
    li   a2, 0
    li   a3, 1
    li   a4, 21
1:  mul  a5, a3, a3
    add  a2, a2, a5
    addi a3, a3, 1
    bne  a3, a4, 1b
    CHK  0x40, a2, 2870
    li   a2, 0
    li   a3, 1
    li   a6, 1000
2:  div  a5, a6, a3
    add  a2, a2, a5
    addi a3, a3, 1
    bne  a3, a4, 2b
    CHK  0x41, a2, 3590

    li   t0, 'D'
    sw   t0, 0(s0)
9:  wfi
    j    9b

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

    # buffer kept in .text so the binary has no gap
    .align 3
buf: .word 0, 0, 0, 0
