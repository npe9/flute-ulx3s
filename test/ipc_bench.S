# IPC microbenchmark for the Flute 50 MHz campaign (fetch / pipeline redesign baseline).
# Loaded at 0x80000000 by the UART boot loader, like cache_test.S.  Each kernel runs
# twice (first pass warms the caches); the second pass's mcycle / minstret deltas are
# printed: 'T', then per kernel '<id>' + puthex(cycles) + puthex(instret), then 'D'.
# Build: see amo_test.S (rv32imac, -Ttext=0x80000000, pad .bin to a multiple of 4).

    .section .text
    .globl _start
_start:
    li   sp, 0x81000000
    li   s0, 0xC0000000
    li   t0, 'T'
    sw   t0, 0(s0)

    li   s2, 'a'
    la   s3, k_alu32
    jal  ra, measure
    li   s2, 'b'
    la   s3, k_aluc
    jal  ra, measure
    li   s2, 'c'
    la   s3, k_copy
    jal  ra, measure
    li   s2, 'd'
    la   s3, k_branchy
    jal  ra, measure
    li   s2, 'e'
    la   s3, k_calls
    jal  ra, measure
    li   s2, 'f'
    la   s3, k_chase
    jal  ra, measure

    li   s2, 'g'
    la   s3, k_poll_io
    jal  ra, measure
    li   s2, 'h'
    la   s3, k_poll_mem
    jal  ra, measure

    li   t0, 'D'
    sw   t0, 0(s0)
1:  j    1b

# measure: s2 = id char, s3 = kernel; runs it twice, reports the second run
measure:
    mv   s11, ra
    jalr ra, 0(s3)
    csrr s4, mcycle
    csrr s5, minstret
    jalr ra, 0(s3)
    csrr s6, mcycle
    csrr s7, minstret
    sw   s2, 0(s0)
    sub  a1, s6, s4
    jal  ra, puthex
    sub  a1, s7, s5
    jal  ra, puthex
    mv   ra, s11
    ret

# a: straight-line 32-bit ALU, 64 independent-ish ops per iteration
    .option push
    .option norvc
k_alu32:
    li   a0, 100
1:
    .rept 16
    addi a2, a2, 1
    xor  a3, a3, a2
    add  a4, a4, a3
    slli a5, a4, 1
    .endr
    addi a0, a0, -1
    bnez a0, 1b
    ret
    .option pop

# b: the same with compressible ops (16-bit encodings)
k_aluc:
    li   a0, 100
1:
    .rept 16
    c.addi a2, 1
    c.xor  a3, a2
    c.add  a4, a3
    c.slli a5, 1
    .endr
    addi a0, a0, -1
    bnez a0, 1b
    ret

# c: word copy of 1 KiB (load/store, cached)
k_copy:
    li   a0, 0x80600000
    li   a1, 0x80600400
    li   a2, 256
1:  lw   a3, 0(a0)
    sw   a3, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    addi a2, a2, -1
    bnez a2, 1b
    ret

# d: branchy: bit-serial popcount of 64 LFSR words
k_branchy:
    li   a0, 64
    li   a1, 0xACE1
    li   a4, 0
1:  mv   a2, a1
2:  andi a3, a2, 1
    beqz a3, 3f
    addi a4, a4, 1
3:  srli a2, a2, 1
    bnez a2, 2b
    slli a3, a1, 1         # next LFSR value
    srli a5, a1, 31
    xor  a1, a3, a5
    xori a1, a1, 0x1d
    addi a0, a0, -1
    bnez a0, 1b
    ret

# e: call/return: 200 calls to a leaf
k_calls:
    mv   s10, ra
    li   s9, 200
1:  jal  ra, leaf
    addi s9, s9, -1
    bnez s9, 1b
    mv   ra, s10
    ret
leaf:
    addi a2, a2, 3
    xor  a3, a3, a2
    ret

# f: load-use pointer chase over a 64-node ring (built on first call each time)
k_chase:
    li   a0, 0x80608000
    li   a1, 64
    mv   a2, a0
1:  addi a3, a2, 40        # node stride 40 bytes
    sw   a3, 0(a2)
    mv   a2, a3
    addi a1, a1, -1
    bnez a1, 1b
    sw   a0, -40(a2)       # close the ring
    li   a1, 512
    mv   a2, a0
2:  lw   a2, 0(a2)
    addi a1, a1, -1
    bnez a1, 2b
    ret

# g: replica of the boot-loader repair-window poll (boot_loader.c 554-575): uncached UART
#    LSR load, forward-taken beqz, addi, backward-taken bne; 500 iterations (LSR.DR == 0)
    .balign 4
k_poll_io:
    li   a4, 0xC0000014
    li   a3, 500
    li   a5, 0
1:  lw   a2, 0(a4)
    andi a2, a2, 1
    beqz a2, 2f
    j    3f
    .rept 16
    nop
    .endr
2:  addi a5, a5, 1
    bne  a5, a3, 1b
3:  ret

# h: the same loop with a cached load (word of zeros)
    .balign 4
k_poll_mem:
    li   a4, 0x80610000
    sw   zero, 0(a4)
    li   a3, 500
    li   a5, 0
1:  lw   a2, 0(a4)
    andi a2, a2, 1
    beqz a2, 2f
    j    3f
    .rept 16
    nop
    .endr
2:  addi a5, a5, 1
    bne  a5, a3, 1b
3:  ret

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
