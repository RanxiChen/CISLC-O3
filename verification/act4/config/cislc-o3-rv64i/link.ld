/* CISLC-O3 ACT4 map: local ITCM/DTCM plus an external tohost mailbox. */
CODE_ORIGIN = 0x10000000;
CODE_LENGTH = 0x01000000;
DATA_ORIGIN = 0x11000000;
DATA_LENGTH = 0x00040000;
TOHOST_ORIGIN = 0x12000000;
STACK_SIZE = 0x2000;
NUM_HARTS = 1;
TEST_BASE = CODE_ORIGIN;

OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)

MEMORY
{
  code   (rx) : ORIGIN = CODE_ORIGIN,   LENGTH = CODE_LENGTH
  data   (rw) : ORIGIN = DATA_ORIGIN,   LENGTH = DATA_LENGTH
  tohost (rw) : ORIGIN = TOHOST_ORIGIN, LENGTH = 0x1000
}

PROVIDE(__stack_size = STACK_SIZE);
PROVIDE(__num_harts = NUM_HARTS);

SECTIONS
{
  .text.init TEST_BASE : { *(.text.init) } > code
  .text.rvtest . : { *(.text.rvtest) *(.text.rvtest.*) } > code
  . = ALIGN(0x1000);
  .text.rvmodel . : { *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) } > code

  .rodata DATA_ORIGIN : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > data
  .data . : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) } > data
  . = ALIGN(16);
  .bss . : {
    __bss_start = .;
    *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > data
  . = ALIGN(16);
  __stack_bottom = .;
  . += __stack_size * __num_harts;
  __stack_top = .;

  .tohost TOHOST_ORIGIN : { KEEP(*(.tohost)) } > tohost
  _end = .;

  ASSERT(__stack_top <= ORIGIN(data) + LENGTH(data), "ACT4 data and stack exceed DTCM")
}
