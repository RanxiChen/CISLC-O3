/* Source: Breeze software/breeze-linux/serial-handoff.S @
 * ec899c7c4367cfab56b9a6206d82066bc79f8a8b; O3 single-hart handoff. */
.section .text.entry, "ax", @progbits
.globl _start
.option norvc
_start:
    csrw mie, zero
    li t0, 8
    csrc mstatus, t0
    csrr a0, mhartid
    li a1, 0x80100000
    li a2, 0
    fence rw, rw
    fence.i
    li t0, 0x80000000
    jr t0
