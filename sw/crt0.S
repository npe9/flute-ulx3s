    .section .text.start
    .global _start
_start:
    la      sp, _sp_top
    la      gp, _gp
    la      t0, _bss_start
    la      t1, _bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  call    main
3:  wfi
    j       3b

    .data
    .align 4
_gp:
    .word 0
