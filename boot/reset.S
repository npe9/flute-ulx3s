.section .text
.globl _start
_start:
	li sp, 0x81fff000
	call real_start
