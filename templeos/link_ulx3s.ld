OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 32M
}

SECTIONS {
  . = 0x80000000;
  .text.init : { *(.text.init) } > RAM
  .text : { *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.*) } > RAM

  /* HolyC AOT machine code from objcopy -I binary; keep it close to crt0
     so the loader image stays small.  The blob is position-independent. */
  .user_blob ALIGN(4) : { blob_in.o(.data) } > RAM

  .data : { EXCLUDE_FILE(blob_in.o) *(.data .data.*) } > RAM
  .bss : { *(.bss .bss.*) *(COMMON) } > RAM

  . = ALIGN(16);
  . += 0x100000;
  __stack_top = .;
}
