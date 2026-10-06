OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
 . = 0x80000000;
 .text : { *(.text.init) *(.text .text.*) }
 ASSERT(. < 0x80100000, "L7 text overlaps fixed data")
 . = 0x80100000;
 .data : { *(.data .data.*) *(.rodata .rodata.*) }
 .bss : { *(.bss .bss.*) *(COMMON) }
 . = 0x801ff000;
 .tohost : { tohost = .; QUAD(0); fromhost = .; QUAD(0); }
}
