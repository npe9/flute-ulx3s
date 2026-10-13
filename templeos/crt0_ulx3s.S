# ULX3S Flute SoC RV32 crt0
# - Sets stack pointer near top of SDRAM.
# - Installs a tiny trap handler.
# - Jumps to the HolyC AOT blob.

.equ UART_BASE, 0xC0000000
.equ STACK_TOP, 0x82000000

.section .text.init
.global _start

_start:
    la t0, trap_vector
    csrw mtvec, t0
    li sp, STACK_TOP
    la t0, _binary_blob_bin_start
    jalr ra, t0, 0
halt:
    wfi
    j halt

# putc(a0): 32-bit 16550 THR at UART_BASE, polling LSR bit 5 (THRE)
putc:
    li t0, UART_BASE
1:
    lw t1, 20(t0)        # LSR at register index 5 -> offset 5*4 = 20
    andi t1, t1, 0x20
    beqz t1, 1b
    sw a0, 0(t0)
    ret

# puts(a0 = NUL-terminated string)
puts:
    addi sp, sp, -8
    sw ra, 4(sp)
    sw s0, 0(sp)
    mv s0, a0
1:
    lbu a0, 0(s0)
    beqz a0, 2f
    call putc
    addi s0, s0, 1
    j 1b
2:
    lw s0, 0(sp)
    lw ra, 4(sp)
    addi sp, sp, 8
    ret

# puthex(a0): 8 lowercase hex digits
puthex:
    addi sp, sp, -8
    sw ra, 4(sp)
    sw s0, 0(sp)
    mv s0, a0
    li t2, 28
1:
    srl a0, s0, t2
    andi a0, a0, 0xf
    addi a0, a0, '0'
    li t3, '9'
    ble a0, t3, 2f
    addi a0, a0, 39
2:
    call putc
    addi t2, t2, -4
    bgez t2, 1b
    lw s0, 0(sp)
    lw ra, 4(sp)
    addi sp, sp, 8
    ret

.align 2
trap_vector:
    la a0, msg_trap
    call puts
    csrr a0, mcause
    call puthex
    la a0, msg_mepc
    call puts
    csrr a0, mepc
    call puthex
    la a0, msg_mtval
    call puts
    csrr a0, mtval
    call puthex
    li a0, '\n'
    call putc
    j halt

.section .rodata
msg_trap:  .asciz "\nTRAP mcause=0x"
msg_mepc:  .asciz " mepc=0x"
msg_mtval: .asciz " mtval=0x"
