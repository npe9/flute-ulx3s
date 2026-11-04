/* sd_test: _start first at the load address; .bss cleared by _start */
ENTRY (_start)
SECTIONS {
  . = 0x80000000;
  .text   : { *(.text.start) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data   : { *(.data .data.* .sdata .sdata.*) }
  .bss    : { __bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN (4); __bss_end = .; }
}
