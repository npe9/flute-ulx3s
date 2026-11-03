# Box-result latency microbenchmark (LX42: MBox/XBox/FBox results bypass from stage3, not
# stage2).  Same harness and output format as ipc_bench.S: each kernel runs twice and the
# second pass's mcycle / minstret deltas are printed: 'T', then per kernel '<id>' +
# puthex(cycles) + puthex(instret), then 'D'.  Each kernel has 64 box ops per iteration,
# 100 iterations; "dep" kernels consume the box result in the very next instruction.
# Build: riscv64-unknown-elf-gcc -march=rv32imafdc_zbb -mabi=ilp32 -nostdlib -nostartfiles
#   -Wl,-Ttext=0x80000000 -o box_bench.elf box_bench.S; objcopy -O binary; pad to 4 bytes

    .section .text
    .globl _start
_start:
    li   sp, 0x81000000
    li   s0, 0xC0000000
    li   t0, 0x2000            # mstatus.FS = Initial
    csrs mstatus, t0
    li   t0, 'T'
    sw   t0, 0(s0)

    li   s2, 'm'
    la   s3, k_mul_dep
    jal  ra, measure
    li   s2, 'n'
    la   s3, k_mul_ind
    jal  ra, measure
    li   s2, 'h'
    la   s3, k_hash
    jal  ra, measure
    li   s2, 'v'
    la   s3, k_div_dep
    jal  ra, measure
    li   s2, 'x'
    la   s3, k_zbb_dep
    jal  ra, measure
    li   s2, 'f'
    la   s3, k_fadd_dep
    jal  ra, measure
    li   s2, 'g'
    la   s3, k_fmv_dep
    jal  ra, measure

    li   t0, 'D'
    sw   t0, 0(s0)
1:  j    1b

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

    .option push
    .option norvc
# m: mul result used by the next instruction
k_mul_dep:
    li   a0, 100
    li   a3, 3
1:
    .rept 64
    mul  a2, a2, a3
    add  a2, a2, a3
    .endr
    addi a0, a0, -1
    bnez a0, 1b
    ret
# n: mul result used three instructions later (independent ALU work in between)
k_mul_ind:
    li   a0, 100
    li   a3, 3
1:
    .rept 64
    mul  a2, a4, a3
    addi a5, a5, 1
    xor  a6, a6, a5
    add  a4, a4, a2
    .endr
    addi a0, a0, -1
    bnez a0, 1b
    ret
# h: string hash h = h*31 + c over 64 bytes (the common C idiom)
k_hash:
    li   a0, 100
    li   a3, 31
1:  la   a1, _start
    li   a4, 64
2:  lbu  a5, 0(a1)
    mul  a2, a2, a3
    add  a2, a2, a5
    addi a1, a1, 1
    addi a4, a4, -1
    bnez a4, 2b
    addi a0, a0, -1
    bnez a0, 1b
    ret
# v: div result used by the next instruction (10 per iteration; div is multicycle)
k_div_dep:
    li   a0, 100
    li   a3, 7
1:
    .rept 10
    li   a2, 0x7fffffff
    div  a2, a2, a3
    add  a4, a4, a2
    .endr
    addi a0, a0, -1
    bnez a0, 1b
    ret
# x: Zbb result used by the next instruction
k_zbb_dep:
    li   a0, 100
    li   a3, 0x5a5a
1:
    .rept 64
    rori a2, a2, 3
    add  a2, a2, a3
    .endr
    addi a0, a0, -1
    bnez a0, 1b
    ret
# f: FP add chain (FPR -> FPR)
k_fadd_dep:
    li   a0, 100
    fcvt.s.w fa1, a0
1:
    .rept 64
    fadd.s fa0, fa0, fa1
    .endr
    addi a0, a0, -1
    bnez a0, 1b
    ret
# g: FP compare to GPR, used by the next instruction
k_fmv_dep:
    li   a0, 100
    fcvt.s.w fa1, a0
1:
    .rept 64
    flt.s a2, fa0, fa1
    add  a4, a4, a2
    .endr
    addi a0, a0, -1
    bnez a0, 1b
    ret
    .option pop

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
