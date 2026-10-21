# Zkr seed CSR (0x015) access test, expectations from Sail check_seed_CSR (af5c2f2):
#   legal  only in M-mode and only for an access that writes (CSRRW/CSRRWI any operand,
#          CSRRS/CSRRC with rs1 != x0, CSRRSI/CSRRCI with uimm != 0);
#   illegal (mcause 2) for read-only access (CSRRS/CSRRC rs1 = x0, CSRRSI/CSRRCI uimm = 0)
#          and for any access from S or U (no mseccfg: SSEED = USEED = 0).
# A legal read (after BIST) must have reserved/custom bits [29:16] = 0 and OPST WAIT (01) or ES16 (10);
# an ES16 sample must arrive within a bounded poll, and the next ES16 sample must differ.
# Sail run: riscv_sim_RV32 --pmp-count 16 --pmp-grain 10 test/seed_test.elf
# Reports via tohost only (no UART), so the same ELF runs on Sail and Flute:
#   tohost = 1 pass, else (last failing id << 7) | (failures << 1) | 1  (failures < 64).
# Build: riscv64-unknown-elf-gcc -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
#        -Wl,-Ttext=0x80000000 -o test/seed_test.elf test/seed_test.S
    .section .text
    .globl _start
    .option norvc
_start:
    li   s9, 0
    la   t0, trap
    csrw mtvec, t0
    li   t0, 0x1FFFFFFF      # PMP entry 0: NAPOT 0..4 GiB, RWX, so S/U can run (not all-ones:
    csrw pmpaddr0, t0        # Sail af5c2f2 mis-sizes the all-ones NAPOT); Sail: --pmp-count 16
    li   t0, 0x1F
    csrw pmpcfg0, t0

# ACC id, expected cause (-1 = no trap), instruction: run in M-mode, compare s6
#define ACC(id, exp, ...) \
    li s4, id; la s5, 1f; li s6, -1; __VA_ARGS__; 1: li t0, exp; jal ra, chk

    li   t1, 0x1234
    ACC(1,  -1, csrrw  a0, 0x015, x0)
    ACC(2,  -1, csrrw  a0, 0x015, t1)
    ACC(3,  -1, csrrw  x0, 0x015, t1)
    ACC(4,  -1, csrrwi a0, 0x015, 0)
    ACC(5,  -1, csrrwi a0, 0x015, 7)
    ACC(6,  -1, csrrs  a0, 0x015, t1)
    ACC(7,  -1, csrrc  a0, 0x015, t1)
    ACC(8,  -1, csrrsi a0, 0x015, 1)
    ACC(9,  -1, csrrci a0, 0x015, 31)
    ACC(10,  2, csrrs  a0, 0x015, x0)
    ACC(11,  2, csrrc  a0, 0x015, x0)
    ACC(12,  2, csrrsi a0, 0x015, 0)
    ACC(13,  2, csrrci a0, 0x015, 0)
    ACC(14,  2, csrrs  x0, 0x015, x0)

# value format of a legal read
    li   s4, 20
    li   s3, 100000          # poll past BIST (startup health window) -- bounded
0:  la   s5, 1f              # a trap (no seed CSR) resumes here with a0 = 0xFFFFFFFF
    li   a0, -1
    csrrw a0, 0x015, x0
1:  srli t0, a0, 30
    bnez t0, 2f
    addi s3, s3, -1
    bnez s3, 0b
2:
    li   t0, 0x3FFF0000
    and  a2, a0, t0
    li   t0, 0
    jal  ra, chk
    li   s4, 21
    srli a2, a0, 30
    addi a2, a2, -1          # WAIT (1) -> 0, ES16 (2) -> 1
    sltiu a2, a2, 2
    li   t0, 1
    jal  ra, chk

# an ES16 sample arrives within a bounded poll (check 22), and the next one differs (check 23)
    li   s4, 22
    jal  ra, get_es16
    mv   s2, a0
    srli a2, a0, 30
    li   t0, 2
    jal  ra, chk
    li   s4, 23
    jal  ra, get_es16
    xor  a2, a0, s2
    snez a2, a2
    li   t0, 1
    jal  ra, chk

# S-mode and U-mode: every seed access is illegal. The lower-mode code ends in ECALL, so
# "no trap" shows up as cause 8 (U) / 9 (S) instead of 2.
#define LOWER(id, mpp, exp, ...) \
    li s4, id; la s5, 2f; li s6, -1; li t0, 0x1800; csrc mstatus, t0; li t0, mpp; csrs mstatus, t0; \
    la t0, 1f; csrw mepc, t0; mret; 1: __VA_ARGS__; ecall; 2: li t0, exp; jal ra, chk

    LOWER(30, 0x0800, 2, csrrw  a0, 0x015, x0)
    LOWER(31, 0x0800, 2, csrrw  a0, 0x015, t1)
    LOWER(32, 0x0800, 2, csrrwi a0, 0x015, 3)
    LOWER(33, 0x0800, 2, csrrs  a0, 0x015, t1)
    LOWER(34, 0x0800, 2, csrrs  a0, 0x015, x0)
    LOWER(40, 0x0000, 2, csrrw  a0, 0x015, x0)
    LOWER(41, 0x0000, 2, csrrwi a0, 0x015, 3)
    LOWER(42, 0x0000, 2, csrrc  a0, 0x015, t1)
    LOWER(43, 0x0000, 2, csrrs  a0, 0x015, x0)

# sanity: ECALL from S really reports 9 (the lower-mode path works)
    LOWER(50, 0x0800, 9, nop)
    LOWER(51, 0x0000, 8, nop)

    li   t0, 1
    beqz s9, 8f
    slli t0, s9, 1
    ori  t0, t0, 1
    slli t1, s8, 7           # tohost[15:7] = id of the last failing check (the sim sees 16 bits)
    or   t0, t0, t1
8:  la   t1, tohost
    sw   t0, 0(t1)
9:  j    9b

# get_es16: poll seed (M-mode) until OPST = ES16 or 200000 tries; returns the last value in a0
get_es16:
    li   s3, 200000
    la   s5, 1f
0:  li   a0, -1
    csrrw a0, 0x015, x0
1:  srli t0, a0, 30
    li   t1, 2
    beq  t0, t1, 2f
    addi s3, s3, -1
    bnez s3, 0b
2:  ret

# chk: ACC/LOWER compare s6 against t0; value checks call it with a2 preloaded (s6 unused)
chk:
    li   t2, 20
    blt  s4, t2, 3f
    li   t2, 30
    bge  s4, t2, 3f
    j    4f
3:  mv   a2, s6
4:  beq  a2, t0, 5f
    addi s9, s9, 1
    mv   s8, s4
5:  ret

# M-mode trap: record mcause, return to M at s5
    .align 2
trap:
    csrr s6, mcause
    li   t0, 0x1800
    csrs mstatus, t0
    csrw mepc, s5
    mret

    .section .tohost, "aw"
    .align 6
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0
