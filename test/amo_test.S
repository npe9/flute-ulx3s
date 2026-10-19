# Bare-metal RV32A test for the ULX3S Flute SoC (E12 gate: the D-cache AMO path).
# Loaded at 0x80000000 by the UART boot loader, like cache_test.S.
# UART (16550 @ 0xC0000000): 'T' on entry, 'M <id> <exp> <got>' per mismatch,
# 'D' when done.  Covers every AMO .W op, both 32-bit halves of a 64-bit cache
# word, AMO on a cache miss (refill path), AMO -> load and AMO -> AMO back to
# back, rd = x0, LR/SC success/failure/cancel, and write-through of AMO results
# (re-read after evicting the line).
# Build: riscv64-unknown-elf-gcc -march=rv32imac -mabi=ilp32 -nostdlib -nostartfiles
#   -Wl,-Ttext=0x80000000 -o amo_test.elf amo_test.S; objcopy -O binary; then pad
#   the .bin to a multiple of 4 (the boot loader rejects a non-word length and
#   falls back to its byte path, which the sim scoreboard does not model).

    .section .text
    .globl _start

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

    li   s1, 0x80500100        # X (fresh line: first AMO misses)
    addi s2, s1, 4             # Y = upper half of X's 64-bit cache word
    addi s3, s1, 8             # Z
    addi s4, s1, 12            # W
    li   s5, 0x80500200        # V (LR/SC)

    # ---- AMO on a cache miss, then an immediate load
    li   a3, 100
    sw   a3, 0(s1)             # write-miss: no allocate
    li   a3, 23
    amoadd.w a2, a3, (s1)
    lw   a4, 0(s1)
    CHK  0x01, a2, 100
    CHK  0x02, a4, 123

    # ---- swap (hit)
    li   a3, 0xdeadbeef
    amoswap.w a2, a3, (s1)
    lw   a4, 0(s1)
    CHK  0x03, a2, 123
    CHK  0x04, a4, 0xdeadbeef

    # ---- xor on the upper half; lower half must be untouched
    li   a3, 0x0f0f0f0f
    sw   a3, 0(s2)
    li   a3, 0xff00ff00
    amoxor.w a2, a3, (s2)
    lw   a4, 0(s2)
    lw   a5, 0(s1)
    CHK  0x05, a2, 0x0f0f0f0f
    CHK  0x06, a4, 0xf00ff00f
    CHK  0x07, a5, 0xdeadbeef

    # ---- and (lower), or (upper)
    li   a3, 0x0000ffff
    amoand.w a2, a3, (s1)
    CHK  0x08, a2, 0xdeadbeef
    li   a3, 0x00000ff0
    amoor.w a2, a3, (s2)
    lw   a4, 0(s1)
    lw   a5, 0(s2)
    CHK  0x09, a2, 0xf00ff00f
    CHK  0x0a, a4, 0x0000beef
    CHK  0x0b, a5, 0xf00fffff

    # ---- signed / unsigned min and max
    li   a3, -16
    sw   a3, 0(s3)
    li   a3, 5
    amomin.w a2, a3, (s3)      # min(-16, 5) = -16
    CHK  0x10, a2, 0xfffffff0
    amomax.w a2, a3, (s3)      # max(-16, 5) = 5
    CHK  0x11, a2, 0xfffffff0
    li   a3, 0x80000000
    amomaxu.w a2, a3, (s3)     # maxu(5, 0x80000000)
    CHK  0x12, a2, 5
    li   a3, 7
    amominu.w a2, a3, (s3)     # minu(0x80000000, 7) = 7
    CHK  0x13, a2, 0x80000000
    li   a3, 0x80000000
    amomin.w a2, a3, (s3)      # min(7, INT_MIN)
    CHK  0x14, a2, 7
    li   a3, -1
    amomax.w a2, a3, (s3)      # max(INT_MIN, -1) = -1
    CHK  0x15, a2, 0x80000000
    li   a3, 0xfffffffe
    amominu.w a2, a3, (s3)     # minu(0xffffffff, 0xfffffffe)
    CHK  0x16, a2, 0xffffffff
    lw   a4, 0(s3)
    CHK  0x17, a4, 0xfffffffe

    # ---- AMO -> AMO back to back, dependent rd, and rd = x0
    sw   zero, 0(s4)
    li   a3, 1
    amoadd.w a2, a3, (s4)
    amoadd.w a4, a2, (s4)      # += 0
    amoadd.w a5, a3, (s4)
    amoadd.w zero, a3, (s4)
    lw   a6, 0(s4)
    CHK  0x20, a2, 0
    CHK  0x21, a4, 1
    CHK  0x22, a5, 1
    CHK  0x23, a6, 3

    # ---- store hit then AMO on the same word
    li   a3, 0x11111111
    sw   a3, 0(s4)
    li   a3, 0x22222222
    amoadd.w a2, a3, (s4)
    lw   a4, 0(s4)
    CHK  0x24, a2, 0x11111111
    CHK  0x25, a4, 0x33333333

    # ---- LR/SC
    li   a3, 42
    sw   a3, 0(s5)
    lr.w a2, (s5)
    li   a3, 77
    sc.w a4, a3, (s5)          # success
    lw   a5, 0(s5)
    CHK  0x30, a2, 42
    CHK  0x31, a4, 0
    CHK  0x32, a5, 77
    li   a3, 88
    sc.w a4, a3, (s5)          # no reservation: fail
    lw   a5, 0(s5)
    CHK  0x33, a4, 1
    CHK  0x34, a5, 77
    lr.w a2, (s5)
    li   a3, 99
    sw   a3, 0(s5)             # store cancels the reservation
    li   a3, 55
    sc.w a4, a3, (s5)
    lw   a5, 0(s5)
    CHK  0x35, a4, 1
    CHK  0x36, a5, 99
    lr.w a2, (s5)
    li   a3, 1
    amoadd.w zero, a3, (s5)    # AMO to the reserved addr cancels it
    li   a3, 55
    sc.w a4, a3, (s5)
    lw   a5, 0(s5)
    CHK  0x37, a2, 99
    CHK  0x38, a4, 1
    CHK  0x39, a5, 100

    # ---- write-through: evict (64 KB of reads), re-read every AMO result
    li   a0, 0x80600000
    li   a1, 0x80610000
1:  lw   zero, 0(a0)
    addi a0, a0, 4
    blt  a0, a1, 1b
    lw   a2, 0(s1)
    lw   a3, 0(s2)
    lw   a4, 0(s3)
    lw   a5, 0(s4)
    lw   a6, 0(s5)
    CHK  0x40, a2, 0x0000beef
    CHK  0x41, a3, 0xf00fffff
    CHK  0x42, a4, 0xfffffffe
    CHK  0x43, a5, 0x33333333
    CHK  0x44, a6, 100

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
