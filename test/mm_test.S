# Bare-metal single-hart memory-ordering litmus test for the ULX3S Flute SoC
# (verification roadmap item 5, notes/linux-isa-plan.md).
# Loaded at 0x80000000 by the UART boot loader, like cache_test.S / amo_test.S.
# UART (16550 @ 0xC0000000): 'T' on entry, 'M <id> <exp> <got>' per mismatch, 'D' when done.
#
# RVWMO on one hart reduces to: every load sees the latest program-order store to the
# same bytes, and instruction fetch sees stores after a FENCE.I, and translation sees
# page-table stores after an SFENCE.VMA.  The checks aim at the parts of this core that
# can break that: the write-through D$ and its store/load paths (partial-width merge,
# 64-bit cache words, conflict misses, cached/uncached addresses with equal low bits),
# the uncached MMIO path (framebuffer RAM and palette, non-posted: a load after a store
# must see it), FENCE.I against an I$ that already holds the line, and SFENCE.VMA
# against the TLB (remap, address-specific flush, invalidate -> page fault, read-only
# -> store page fault, megapage).  LR/SC and AMOs are amo_test.S's.
#
#   0x1x  self-modifying code + FENCE.I     0x2x  cached store -> load
#   0x3x  uncached MMIO store -> load       0x4x  SFENCE.VMA / TLB (M-mode, MPRV=1, MPP=S)
#
# Build: riscv64-unknown-elf-gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib
#   -nostartfiles -Wl,-Ttext=0x80000000 -o mm_test.elf mm_test.S; objcopy -O binary;
#   pad the .bin to a multiple of 4.

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

# data accesses translated at S (instruction fetch stays M, untranslated)
.macro MPRV_ON
    li   t0, 0x1000
    csrc mstatus, t0           # MPP[1] = 0
    li   t0, 0x20800
    csrs mstatus, t0           # MPP[0] = 1 (S), MPRV = 1
.endm
.macro MPRV_OFF
    li   t0, 0x20000
    csrc mstatus, t0
.endm
# store a leaf PTE for PA (4 KB page) into L0[0]: V R W A D (or the given flags)
.macro SETPTE pa, flags
    li   t0, ((\pa >> 12) << 10) | \flags
    sw   t0, 0(s10)
.endm

    .equ X,      0x80720000    # cached scratch
    .equ FB,     0xC1000000    # framebuffer pixel RAM (uncached, R/W)
    .equ PAL200, 0xC0010720    # palette entry 200
    .equ ROOT,   0x80710000    # Sv32 root table
    .equ L0,     0x80711000    # level-0 table for VA 0x40000000
    .equ PGA,    0x80712000
    .equ PGB,    0x80713000
    .equ MEGA,   0x80400000    # megapage for VA 0x40400000
    .equ VA,     0x40000000
    .equ VAM,    0x40400000
    .equ RWAD,   0xC7          # D A - - - W R V
    .equ RAD,    0xC3          # D A - - - - R V

_start:
    li   sp, 0x81000000
    li   s0, 0xC0000000
    li   t0, 'T'
    sw   t0, 0(s0)
    la   t0, trap
    csrw mtvec, t0

    # ================= 0x1x: self-modifying code + FENCE.I
    jal  ra, smc1              # line now in the I$
    CHK  0x10, a0, 1
    li   t1, 0x00200513        # addi a0, x0, 2
    la   t3, smc1
    sw   t1, 0(t3)
    fence.i
    jal  ra, smc1
    CHK  0x11, a0, 2
    li   t1, 0x00300513        # second rewrite of a line the I$ refilled after the first
    la   t3, smc1
    sw   t1, 0(t3)
    fence.i
    jal  ra, smc1
    CHK  0x12, a0, 3
    li   t1, 0x02a00513        # smc3: same line, never executed before (but fetched)
    la   t3, smc3
    sw   t1, 0(t3)
    fence.i
    jal  ra, smc3
    CHK  0x13, a0, 42
    jal  ra, smc2              # compressed slot, rewritten by a halfword store
    CHK  0x14, a0, 1
    li   t1, 0x450d            # c.li a0, 3
    la   t3, smc2
    sh   t1, 0(t3)
    fence.i
    jal  ra, smc2
    CHK  0x15, a0, 3

    # ================= 0x2x: cached store -> load, back to back
    li   s1, X
    li   t1, 0x81223344
    sw   t1, 0(s1)
    lbu  a2, 0(s1)
    lbu  a3, 1(s1)
    lbu  a4, 2(s1)
    lb   a5, 3(s1)
    CHK  0x20, a2, 0x44
    CHK  0x21, a3, 0x33
    CHK  0x22, a4, 0x22
    CHK  0x23, a5, 0xffffff81
    li   t1, 0xaa
    sb   t1, 1(s1)
    lw   a2, 0(s1)
    CHK  0x24, a2, 0x8122aa44
    li   t1, 0xbeef
    sh   t1, 2(s1)
    lw   a2, 0(s1)
    lhu  a3, 2(s1)
    lh   a4, 2(s1)
    CHK  0x25, a2, 0xbeefaa44
    CHK  0x26, a3, 0xbeef
    CHK  0x27, a4, 0xffffbeef
    li   t1, 0x55              # write after write, mixed widths
    sb   t1, 0(s1)
    li   t1, 0x6677
    sh   t1, 0(s1)
    lw   a2, 0(s1)
    CHK  0x28, a2, 0xbeef6677
    li   t1, 0x0badf00d        # upper half of the 64-bit cache word
    sw   t1, 4(s1)
    lw   a2, 0(s1)
    lw   a3, 4(s1)
    CHK  0x29, a2, 0xbeef6677
    CHK  0x2a, a3, 0x0badf00d
    lw   a2, 8(s1)             # write after read
    li   t1, 0x13579bdf
    sw   t1, 8(s1)
    lw   a2, 8(s1)
    CHK  0x2b, a2, 0x13579bdf
    li   s2, X + 0x10000       # same index, other tags: conflict misses
    li   s3, X + 0x20000
    li   t1, 0x11110001
    sw   t1, 0x40(s1)
    li   t1, 0x22220002
    sw   t1, 0x40(s2)
    li   t1, 0x33330003
    sw   t1, 0x40(s3)
    lw   a2, 0x40(s1)
    lw   a3, 0x40(s2)
    lw   a4, 0x40(s3)
    CHK  0x2c, a2, 0x11110001
    CHK  0x2d, a3, 0x22220002
    CHK  0x2e, a4, 0x33330003
    li   s4, FB                # cached and uncached addresses with equal low bits
    li   t1, 0x5a5a0001
    sw   t1, 0x10(s1)
    li   t1, 0xa5a50002
    sw   t1, 0x10(s4)
    lw   a2, 0x10(s1)
    lw   a3, 0x10(s4)
    CHK  0x2f, a2, 0x5a5a0001
    CHK  0x30, a3, 0xa5a50002

    # ================= 0x3x: uncached MMIO store -> load (framebuffer RAM, palette)
    li   t1, 0x01020304
    sw   t1, 0x20(s4)
    lw   a2, 0x20(s4)
    CHK  0x31, a2, 0x01020304
    li   t1, 0xff
    sb   t1, 0x21(s4)
    lw   a2, 0x20(s4)
    lbu  a3, 0x21(s4)
    lb   a4, 0x21(s4)
    CHK  0x32, a2, 0x0102ff04
    CHK  0x33, a3, 0xff
    CHK  0x34, a4, 0xffffffff
    li   t1, 0x7788
    sh   t1, 0x22(s4)
    lw   a2, 0x20(s4)
    CHK  0x35, a2, 0x7788ff04
    li   t1, 0xc0de0024
    sw   t1, 0x24(s4)
    li   t1, 0xc0de0028
    sw   t1, 0x28(s4)
    lw   a2, 0x24(s4)
    lw   a3, 0x28(s4)
    CHK  0x36, a2, 0xc0de0024
    CHK  0x37, a3, 0xc0de0028
    li   t1, 0x0000a0a0        # MMIO store, cached store, then load both
    sw   t1, 0x30(s4)
    li   t1, 0x0000b0b0
    sw   t1, 0x30(s1)
    lw   a2, 0x30(s4)
    lw   a3, 0x30(s1)
    CHK  0x38, a2, 0x0000a0a0
    CHK  0x39, a3, 0x0000b0b0
    li   t1, 0x0000c0c0        # cached store, MMIO store, fence, MMIO load, cached load
    sw   t1, 0x34(s1)
    li   t1, 0x0000d0d0
    sw   t1, 0x34(s4)
    fence rw, rw
    lw   a2, 0x34(s4)
    lw   a3, 0x34(s1)
    CHK  0x3a, a2, 0x0000d0d0
    CHK  0x3b, a3, 0x0000c0c0
    li   s5, PAL200            # palette: a write replaces [23:0], reads 0x00RRGGBB
    lw   s6, 0(s5)
    li   t1, 0xffabcdef
    sw   t1, 0(s5)
    lw   a2, 0(s5)
    sw   s6, 0(s5)
    lw   a3, 0(s5)
    CHK  0x3c, a2, 0x00abcdef
    sub  a3, a3, s6            # the restore reads back the original entry
    CHK  0x3d, a3, 0

    # ================= 0x4x: SFENCE.VMA and the TLB
    li   t0, -1                # PMP entry 0: NAPOT over everything, RWX (S accesses need a match)
    csrw pmpaddr0, t0
    li   t0, 0x1f
    csrw pmpcfg0, t0
    li   s9, VA
    li   s10, L0
    li   t1, ROOT              # root[0x100] -> L0 (pointer); root[0x101] = megapage
    li   t0, ((L0 >> 12) << 10) | 1
    sw   t0, (0x100 * 4)(t1)
    li   t0, ((MEGA >> 12) << 10) | RWAD
    sw   t0, (0x101 * 4)(t1)
    li   t1, PGA
    li   t0, 0xaaaa0001
    sw   t0, 0(t1)
    sw   zero, 8(t1)           # SDRAM is not zeroed at power-up
    li   t1, PGB
    li   t0, 0xbbbb0002
    sw   t0, 0(t1)
    sw   zero, 4(t1)
    li   t1, MEGA + 0x48c
    li   t0, 0x3e6a048c
    sw   t0, 0(t1)
    SETPTE PGA, RWAD
    li   t0, (1 << 31) | (ROOT >> 12)
    csrw satp, t0
    sfence.vma
    MPRV_ON
    lw   a2, 0(s9)
    MPRV_OFF
    CHK  0x40, a2, 0xaaaa0001
    SETPTE PGB, RWAD           # remap; full flush
    sfence.vma
    MPRV_ON
    lw   a2, 0(s9)
    MPRV_OFF
    CHK  0x41, a2, 0xbbbb0002
    SETPTE PGA, RWAD           # remap; address-specific flush
    sfence.vma s9, zero
    MPRV_ON
    lw   a2, 0(s9)
    li   t1, 0x12345678        # store through the VA lands in PGA, not PGB
    sw   t1, 4(s9)
    MPRV_OFF
    li   t1, PGA
    lw   a3, 4(t1)
    li   t1, PGB
    lw   a4, 4(t1)
    CHK  0x42, a2, 0xaaaa0001
    CHK  0x43, a3, 0x12345678
    CHK  0x44, a4, 0
    li   t1, VAM + 0x48c       # megapage
    MPRV_ON
    lw   a2, 0(t1)
    MPRV_OFF
    CHK  0x45, a2, 0x3e6a048c
    SETPTE PGA, RAD            # read-only: load ok, store -> store page fault
    sfence.vma s9, zero
    li   s7, -1
    MPRV_ON
    lw   a2, 0(s9)
    MPRV_OFF
    CHK  0x46, a2, 0xaaaa0001
    CHK  0x47, s7, -1
    MPRV_ON
    sw   a2, 8(s9)
    MPRV_OFF                   # (the trap's MRET returns with MPP = U: MPRV_ON re-arms S)
    CHK  0x48, s7, 15
    CHK  0x49, s8, VA + 8
    sw   zero, 0(s10)          # invalid: load -> load page fault
    sfence.vma
    li   s7, -1
    MPRV_ON
    lw   a2, 0(s9)
    MPRV_OFF
    CHK  0x4a, s7, 13
    CHK  0x4b, s8, VA
    li   t1, PGA               # the faulting store did not land
    lw   a3, 8(t1)
    CHK  0x4c, a3, 0

    csrw satp, zero
    sfence.vma
    li   t0, 'D'
    sw   t0, 0(s0)
9:  wfi
    j    9b

# ---- trap: record mcause / mtval, skip the (32-bit) faulting instruction
    .balign 4
trap:
    csrr s7, mcause
    csrr s8, mtval
    csrr t1, mepc
    addi t1, t1, 4
    csrw mepc, t1
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

# ---- self-modifying slots (one 32-byte line: smc1, smc3; smc2 compressed)
    .balign 32
smc1:
    .word 0x00100513           # addi a0, x0, 1
    .word 0x00008067           # ret
smc3:
    .word 0x00000513           # addi a0, x0, 0
    .word 0x00008067
smc2:
    .half 0x4505               # c.li a0, 1
    .half 0x8082               # c.ret
