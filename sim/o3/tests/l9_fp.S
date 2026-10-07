// Basic L9 functional gate. Integer comparisons are the oracle; no Spike/MRET.
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
    li s10, 0
    la t0, trap
    csrw mtvec, t0
    csrr t0, misa
    check t0, 0x800000000000112c
    csrr t0, mstatus
    srli t0, t0, 13
    andi t0, t0, 3
    check t0, 0
    // FS Off traps with the original instruction and fault PC.
    li s10, 1
    la s8, off_fault
    la s9, enabled
off_fault:
    .word 0x22000053  // fsgnj.d f0,f0,f0
    j fail
enabled:
    check s10, 0
    li t0, 0x2000
    csrs mstatus, t0
    csrr t0, fcsr
    check t0, 0
    li s11, 2
    la a0, data
    la a1, scratch
    fld f0, 0(a0)
    check_d f0, 0x4000000000000000  // f0 is writable: 2.0
    fsd f0, 0(a1)
    ld t0, 0(a1)
    check t0, 0x4000000000000000
    flw f1, 32(a0)
    check_d f1, 0xffffffff3fc00000
    fsw f1, 8(a1)
    lwu t0, 8(a1)
    check t0, 0x3fc00000
    // FLD alone must set FS Dirty and SD at retirement.
    li t0, 0x6000
    csrc mstatus, t0
    li t0, 0x4000
    csrs mstatus, t0
    fld f2, 8(a0)
    csrr t0, mstatus
    srli t1, t0, 13
    andi t1, t1, 3
    check t1, 3
    srli t0, t0, 63
    check t0, 1
    li s11, 3
    li t0, 0x80000001
    fmv.w.x f3, t0
    check_d f3, 0xffffffff80000001
    fmv.x.w t0, f3
    check t0, 0xffffffff80000001
    fsgnjn.d f3, f0, f0
    check_d f3, 0xc000000000000000
    fmin.d f3, f0, f2
    check_d f3, 0x4000000000000000
    fmax.d f3, f0, f2
    check_d f3, 0x4008000000000000
    feq.d t0, f0, f0
    check t0, 1
    flt.d t0, f0, f2
    check t0, 1
    fle.d t0, f2, f0
    check t0, 0
    fclass.d t0, f0
    check t0, 64
    li t0, -3
    fcvt.d.w f3, t0
    fcvt.w.d t0, f3, rtz
    check t0, -3
    fcvt.s.d f3, f0
    check_d f3, 0xffffffff40000000
    fcvt.d.s f3, f3
    check_d f3, 0x4000000000000000
    li s11, 4
    fadd.d f3, f0, f2
    check_d f3, 0x4014000000000000
    fsub.d f3, f2, f0
    check_d f3, 0x3ff0000000000000
    fmul.d f3, f0, f2
    check_d f3, 0x4018000000000000
    fmadd.d f3, f0, f2, f0
    check_d f3, 0x4020000000000000
    fmsub.d f3, f0, f2, f0
    check_d f3, 0x4010000000000000
    fnmsub.d f3, f0, f2, f0
    check_d f3, 0xc010000000000000
    fnmadd.d f3, f0, f2, f0
    check_d f3, 0xc020000000000000
    fdiv.d f3, f2, f0
    check_d f3, 0x3ff8000000000000
    fld f4, 16(a0)
    fsqrt.d f3, f4
    check_d f3, 0x4008000000000000
    fadd.s f3, f1, f1
    check_d f3, 0xffffffff40400000
    fmadd.s f3, f1, f1, f1
    check_d f3, 0xffffffff40700000
    fdiv.s f3, f1, f1
    check_d f3, 0xffffffff3f800000
    fsqrt.s f3, f3
    check_d f3, 0xffffffff3f800000
    li s11, 5
    fld f4, 24(a0)  // signaling NaN
    csrw fflags, zero
    feq.d zero, f4, f0  // x0 destination still completes and retires NV
    csrr t0, fflags
    check t0, 16
    csrw fflags, zero
    fld f4, 40(a0)  // 1.0
    fdiv.d f3, f4, f2  // 1/3: NX
    fmv.d.x f5, zero
    fdiv.d f3, f4, f5  // DZ
    fsgnjn.d f5, f4, f4
    fsqrt.d f3, f5  // NV
    csrr t0, fflags
    check t0, 25
    li s11, 6
    fld f4, 48(a0)  // 2.75
    csrwi frm, 1
    fcvt.w.d t0, f4, dyn
    check t0, 2
    csrwi frm, 0
    fcvt.w.d t0, f4, dyn
    check t0, 3
    li s11, 7
    .option rvc
    mv s0, a0
    mv s1, a1
    c.fld f8, 0(s0)
    c.fsd f8, 16(s1)
    .option norvc
    ld t0, 16(a1)
    check t0, 0x4000000000000000
    addi sp, a1, 32
    .option rvc
    c.fsdsp f8, 0(sp)
    c.fldsp f0, 0(sp)
    .option norvc
    check_d f0, 0x4000000000000000
    li s11, 8
    fmv.d.x f6, zero
    fld f4, 40(a0)
    li s0, 50
loop:
    fmadd.d f6, f4, f2, f6  // RAW and WAW across loop iterations
    fdiv.d f7, f2, f4
    fcvt.w.d t0, f7, rtz
    li t1, 3
    beq t0, t1, correct
    // Wrong path must not replace the accumulator or set architectural NV.
    fld f6, 24(a0)
    fsqrt.d f6, f5
    j fail
correct:
    addi s0, s0, -1
    bnez s0, loop
    check_d f6, 0x4062c00000000000  // 50*3 = 150.0
    li t1, 1
    j report
trap:
    li t0, 1
    bne s10, t0, fail
    csrr t0, mcause
    check t0, 2
    csrr t0, mepc
    bne t0, s8, fail
    csrr t0, mtval
    check t0, 0x22000053
    li s10, 0
    jr s9
fail:
    slli t1, s11, 1
    ori t1, t1, 1  // odd stage code identifies the failed block
report:
    la t0, tohost
    sd t1, 0(t0)
1:  j 1b
.section .data
.balign 8
data:
    .dword 0x4000000000000000,0x4008000000000000,0x4022000000000000,0x7ff0000000000001
    .dword 0x000000003fc00000,0x3ff0000000000000,0x4006000000000000
scratch:
    .zero 64
