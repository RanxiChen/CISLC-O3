.option norvc
.option norelax
.section .text.init
.globl _start
_start:
    la a0, data
    la a1, scratch
    li t6, 1
    div s0, a0, t6
    ld t1, 0(s0)
    sd t1, 0(a1)
    ld t2, 0(a1)
    li t3, 0x4000000000000000
    bne t1, t3, fail
    bne t2, t3, fail
    li t1, 1
    j report
fail:
    li t1, 3
report:
    la t0, tohost
    sd t1, 0(t0)
1:  j 1b
.section .data
.balign 8
data: .dword 0x4000000000000000
scratch: .dword 0
