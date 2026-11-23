/* test/bench: _start first at the load address; .bss cleared by _start; stack below 0x81000000 */
ENTRY (_start)
SECTIONS {
  . = 0x80000000;
  .text   : { *(.text.start) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data   : { *(.data .data.* .sdata .sdata.*) }
  .bss    : { . = ALIGN (4); __bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN (4); __bss_end = .; }
}
