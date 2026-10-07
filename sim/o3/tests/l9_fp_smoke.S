// Basic sequential functional smoke. Larger replay interactions stay in l9_fp.S.
// CSR reads between memory blocks drain older work through the existing contract.
.option norelax
.option norvc
.section .text.init
.globl _start
.macro check reg, value
    li t6, \value
    bne \reg, t6, fail
.endm
.macro check_d freg, value
    fmv.x.d t5, \freg
    check t5, \value
.endm
_start:
    li s11, 1
    la t0, fail
    csrw mtvec, t0
    li t0, 0x2000
    csrs mstatus, t0
    la a0, data
    la a1, scratch
    fld f0, 0(a0)
    fld f1, 8(a0)
    fsd f0, 0(a1)
    csrr t0, mstatus
    srli t0, t0, 13
    andi t0, t0, 3
    check t0, 3
    ld t0, 0(a1)
    check t0, 0x4000000000000000
    flw f2, 16(a0)
    check_d f2, 0xffffffff3fc00000
    fsw f2, 8(a1)
    csrr t0, mstatus
    lwu t0, 8(a1)
    check t0, 0x3fc00000
    li s11, 2
    fadd.d f3, f0, f1
    check_d f3, 0x4014000000000000
    fmadd.d f3, f0, f1, f0
    check_d f3, 0x4020000000000000
    fdiv.d f3, f1, f0
    check_d f3, 0x3ff8000000000000
    fmul.d f3, f1, f1
    fsqrt.d f3, f3
    check_d f3, 0x4008000000000000
    fadd.s f3, f2, f2
    check_d f3, 0xffffffff40400000
    fmin.d f3, f0, f1
    check_d f3, 0x4000000000000000
    fcvt.w.d t0, f1, rtz
    check t0, 3
    fcvt.d.w f3, t0
    check_d f3, 0x4008000000000000
    li s11, 3
    fmv.d.x f4, zero
    csrw fflags, zero
    fdiv.d f3, f0, f4
    csrr t0, fflags
    check t0, 8
    li s11, 4
    mv s0, a0
    mv s1, a1
    csrr t0, mstatus  // address setup retires before this memory block
    .option rvc
    c.fld f8, 0(s0)
    c.fsd f8, 16(s1)
    .option norvc
    csrr t0, mstatus
    ld t0, 16(a1)
    check t0, 0x4000000000000000
    addi sp, a1, 32
    .option rvc
    c.fsdsp f8, 0(sp)
    c.fldsp f0, 0(sp)
    .option norvc
    csrr t0, mstatus
    check_d f0, 0x4000000000000000
    li s11, 5
    fmv.d.x f4, zero
    li s0, 50
loop:
    fmadd.d f4, f0, f1, f4
    addi s0, s0, -1
    bnez s0, loop
    check_d f4, 0x4072c00000000000  // 50 * 2 * 3 = 300.0
    li t1, 1
    j report
fail:
    slli t1, s11, 1
    ori t1, t1, 1
report:
    la t0, tohost
    sd t1, 0(t0)
1:  j 1b
.section .data
.balign 8
data:
    .dword 0x4000000000000000,0x4008000000000000,0x000000003fc00000
scratch:
    .zero 64
