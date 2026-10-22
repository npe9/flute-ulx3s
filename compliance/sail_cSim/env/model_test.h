// Shared by the Flute DUT plugin and the sail_cSim reference plugin (compliance/), so both
// ELFs have the same layout.  Based on riscv-arch-test 3.10.0 riscof-plugins/rv32/sail_cSim.
// RVMODEL_BOOT: the DUT enters at 0x80000000 after the boot ROM has run (sim/isa_bram jumps
// there via the loader), while Sail starts from reset; put the CSRs a test may observe back
// to reset values on both.
#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

//RV_COMPLIANCE_HALT
#define RVMODEL_HALT    ;\
li x1, 1                ;\
1:                      ;\
    sw x1, tohost, t2   ;\
    j 1b                ;\

#define RVMODEL_BOOT            ;\
  csrw mie, x0              ;\
  csrw mip, x0              ;\
  csrw medeleg, x0          ;\
  csrw mideleg, x0          ;\
  csrw satp, x0             ;\
  csrw mscratch, x0         ;\
  csrw pmpcfg0, x0          ;\
  csrw pmpcfg1, x0          ;\
  csrw pmpcfg2, x0          ;\
  csrw pmpcfg3, x0          ;

//RV_COMPLIANCE_DATA_BEGIN
#define RVMODEL_DATA_BEGIN		;\
RVMODEL_DATA_SECTION			;\
.align 4                  ;\
.global begin_signature   ;\
begin_signature:

//RV_COMPLIANCE_DATA_END
#define RVMODEL_DATA_END                                                      \
.global end_signature; end_signature:


//RVTEST_IO_INIT
#define RVMODEL_IO_INIT
//RVTEST_IO_WRITE_STR
#define RVMODEL_IO_WRITE_STR(_R, _STR)
//RVTEST_IO_CHECK
#define RVMODEL_IO_CHECK()
//RVTEST_IO_ASSERT_GPR_EQ
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
//RVTEST_IO_ASSERT_SFPR_EQ
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
//RVTEST_IO_ASSERT_DFPR_EQ
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

#define RVMODEL_SET_MSW_INT

#define RVMODEL_CLEAR_MSW_INT

#define RVMODEL_CLEAR_MTIMER_INT

#define RVMODEL_CLEAR_MEXT_INT


#endif // _COMPLIANCE_MODEL_H
