    .section .text.start
    .global _start
_start:
    lui     a0, 0xc0000          # UART base 0xC0000000
1:
    lw      a1, 20(a0)           # LSR at offset 5
    andi    a1, a1, 0x20         # THRE bit
    beqz    a1, 1b
    li      a2, 'A'
    .option push
    .option norvc
    sw      a2, 0(a0)            # THR (32-bit store)
    .option pop
    j       1b
