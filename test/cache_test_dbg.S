# Bare-metal cache test for the ULX3S Flute SoC.
# Loaded at 0x80000000 by the UART boot loader (same protocol as the REPL blob).
# Exercises the D-cache hard: pattern store -> evict -> readback compare.
# UART (16550 @ 0xC0000000, 32-bit registers):
#   prints 'T' on entry, then for each mismatch 'M <addr> <exp> <got>\r\n',
#   finally 'D' when the whole pass is done, then idles.
# Register use: keeps it simple, no trap setup needed (MIE=0 at reset).

    .section .text
    .globl _start
_start:
    li   sp, 0x81000000        # stack well inside RAM

    # UART greeting 'T'
    li   s0, 0xC0000000        # UART base (reg 0 = THR/RBR, word stride)
    li   t0, 'T'
    sw   t0, 0(s0)

    li   t0, '1'
    sw   t0, 0(s0)
    # ---------------- Phase 1: fill 16 KB at BUF with an address pattern
    li   s1, 0x80500000        # BUF
    li   s2, 0x80504000        # BUF end
    li   s4, 0x5a5a0000
    mv   a0, s1
1:  xor  t0, a0, s4
    sw   t0, 0(a0)
    addi a0, a0, 4
    blt  a0, s2, 1b

    li   t0, '2'
    sw   t0, 0(s0)
    # ---------------- Phase 2: evict -- read 64 KB of scratch (dummies)
    li   a0, 0x80600000
    li   a1, 0x80610000
2:  lw   zero, 0(a0)
    addi a0, a0, 4
    blt  a0, a1, 2b

    li   t0, '3'
    sw   t0, 0(s0)
    # ---------------- Phase 3: readback compare
    mv   a0, s1
3:  lw   t1, 0(a0)
    xor  t0, a0, s4
    beq  t1, t0, 4f
    # mismatch: 'M' + addr + exp + got
    li   t2, 'M'
    sw   t2, 0(s0)
    mv   a1, a0
    jal  ra, puthex
    mv   a1, t0
    jal  ra, puthex
    mv   a1, t1
    jal  ra, puthex
4:  addi a0, a0, 4
    blt  a0, s2, 3b

    li   t0, '4'
    sw   t0, 0(s0)
    # ---------------- Phase 4: second pattern sweep, narrower stride (byte lanes)
    li   s3, 0x80700000
    mv   a0, s3
5:  not  t0, a0
    sw   t0, 0(a0)
    addi a0, a0, 4
    li   t1, 0x80704000
    blt  a0, t1, 5b
    # evict again (different scratch, to also cross sets)
    li   a0, 0x80800000
    li   a1, 0x80810000
6:  lw   zero, 0(a0)
    addi a0, a0, 4
    blt  a0, a1, 6b
    mv   a0, s3
7:  lw   t1, 0(a0)
    not  t0, a0
    beq  t1, t0, 8f
    li   t2, 'M'
    sw   t2, 0(s0)
    mv   a1, a0
    jal  ra, puthex
    mv   a1, t0
    jal  ra, puthex
    mv   a1, t1
    jal  ra, puthex
8:  addi a0, a0, 4
    li   t1, 0x80704000
    blt  a0, t1, 7b

    li   t0, '5'
    sw   t0, 0(s0)
    # ---------------- Phase 5: I-cache stress -- dense unrolled block.
    # Sweep >8KB of code so later reps miss the 8KB I-cache; each rep also
    # re-fetches across the whole region sequentially.
    li   s5, 0
    li   a2, 4
p5: .rept 512
    addi s5, s5, 1
    .endr
    addi a2, a2, -1
    bnez a2, p5
    # verify s5 == 2048
    li   t0, 2048
    beq  s5, t0, p5ok
    li   t2, 'M'
    sw   t2, 0(s0)
    li   a1, 2048
    jal  ra, puthex
    mv   a1, s5
    jal  ra, puthex
p5ok:

    li   t0, '6'
    sw   t0, 0(s0)
    # ---------------- Phase 6: far call chain (redirect + refill storm).
    # 16 functions at 1KB stride, called 8 times: every call redirects to a
    # cold region (I-miss + branch redirect) and the rets unwind through
    # warm regions (predictor training).  Padding between functions is
    # jumped over, never executed.
    li   a2, 8
p6: jal  ra, chain0
    li   t0, 'c'
    sw   t0, 0(s0)
    addi a2, a2, -1
    bnez a2, p6
    # verify s5 == 2048 + 8*16
    li   t0, 2048 + 128
    beq  s5, t0, p6ok
    li   t2, 'M'
    sw   t2, 0(s0)
    li   a1, 2048 + 128
    jal  ra, puthex
    mv   a1, s5
    jal  ra, puthex
p6ok:

    li   t0, '7'
    sw   t0, 0(s0)
    # ---------------- Phase 7: computed jump ring -- jalr through a table of
    # 16 targets at 512B stride, 4 laps.  Exercises BTB/predictor lookups on
    # data-dependent targets (rg_tval / redirect path).
    li   a2, 4
    la   s6, jtab
p7: mv   a3, s6
    li   a4, 16
p7i: lw   a5, 0(a3)
    jalr ra, 0(a5)        # each jfnN: addi s5,s5,1 ; ret
    addi a3, a3, 4
    addi a4, a4, -1
    bnez a4, p7i
    addi a2, a2, -1
    bnez a2, p7
    # verify s5 == 2176 + 64
    li   t0, 2176 + 64
    beq  s5, t0, p7ok
    li   t2, 'M'
    sw   t2, 0(s0)
    li   a1, 2176 + 64
    jal  ra, puthex
    mv   a1, s5
    jal  ra, puthex
p7ok:

    # ---------------- Done: 'D'
    li   t0, 'D'
    sw   t0, 0(s0)
9:  wfi
    j 9b

# ---------------- Phase 6 helpers: far chain (1KB stride)
chain0:  addi s5, s5, 1
    jal  ra, chain1
    ret
    .space 1016, 0
chain1:  addi s5, s5, 1
    jal  ra, chain2
    ret
    .space 1016, 0
chain2:  addi s5, s5, 1
    jal  ra, chain3
    ret
    .space 1016, 0
chain3:  addi s5, s5, 1
    jal  ra, chain4
    ret
    .space 1016, 0
chain4:  addi s5, s5, 1
    jal  ra, chain5
    ret
    .space 1016, 0
chain5:  addi s5, s5, 1
    jal  ra, chain6
    ret
    .space 1016, 0
chain6:  addi s5, s5, 1
    jal  ra, chain7
    ret
    .space 1016, 0
chain7:  addi s5, s5, 1
    jal  ra, chain8
    ret
    .space 1016, 0
chain8:  addi s5, s5, 1
    jal  ra, chain9
    ret
    .space 1016, 0
chain9:  addi s5, s5, 1
    jal  ra, chain10
    ret
    .space 1016, 0
chain10: addi s5, s5, 1
    jal  ra, chain11
    ret
    .space 1016, 0
chain11: addi s5, s5, 1
    jal  ra, chain12
    ret
    .space 1016, 0
chain12: addi s5, s5, 1
    jal  ra, chain13
    ret
    .space 1016, 0
chain13: addi s5, s5, 1
    jal  ra, chain14
    ret
    .space 1016, 0
chain14: addi s5, s5, 1
    jal  ra, chain15
    ret
    .space 1016, 0
chain15: addi s5, s5, 1
    ret

# ---------------- Phase 7 helpers: jump table + 512B-strided stubs
jtab:
    .word jfn0, jfn1, jfn2, jfn3, jfn4, jfn5, jfn6, jfn7
    .word jfn8, jfn9, jfn10, jfn11, jfn12, jfn13, jfn14, jfn15

jfn0:  addi s5, s5, 1
    ret
    .space 504, 0
jfn1:  addi s5, s5, 1
    ret
    .space 504, 0
jfn2:  addi s5, s5, 1
    ret
    .space 504, 0
jfn3:  addi s5, s5, 1
    ret
    .space 504, 0
jfn4:  addi s5, s5, 1
    ret
    .space 504, 0
jfn5:  addi s5, s5, 1
    ret
    .space 504, 0
jfn6:  addi s5, s5, 1
    ret
    .space 504, 0
jfn7:  addi s5, s5, 1
    ret
    .space 504, 0
jfn8:  addi s5, s5, 1
    ret
    .space 504, 0
jfn9:  addi s5, s5, 1
    ret
    .space 504, 0
jfn10: addi s5, s5, 1
    ret
    .space 504, 0
jfn11: addi s5, s5, 1
    ret
    .space 504, 0
jfn12: addi s5, s5, 1
    ret
    .space 504, 0
jfn13: addi s5, s5, 1
    ret
    .space 504, 0
jfn14: addi s5, s5, 1
    ret
    .space 504, 0
jfn15: addi s5, s5, 1
    ret


# puthex: print a1 as 8 hex digits (no UART status wait: 16550 TX has a
# FIFO and this test prints rarely; add a crude delay loop instead)
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
