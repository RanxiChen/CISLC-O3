OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
 . = 0x80000000;
 .text : { *(.text.init) *(.text .text.*) }
 . = ALIGN(64);
 .data : { *(.data .data.*) *(.rodata .rodata.*) }
 .bss : { *(.bss .bss.*) *(COMMON) }
 . = 0x801ff000;
 .tohost : { tohost = .; QUAD(0); fromhost = .; QUAD(0); }
}
