// Frozen L7a 9.2: identical measured PCs/instruction counts for GROUP_A/B.
.option norvc
.option norelax
.section .text.init
.globl _start
.macro event csr, a, b
#ifdef GROUP_B
    li t0, \b
#else
    li t0, \a
#endif
    csrw \csr, t0
.endm
.macro sample
    li t0, 0x7f8
    csrw 0x320, t0
    csrr t1, 0xb03
    sd t1, 0(s0)
    csrr t1, 0xb04
    sd t1, 8(s0)
    csrr t1, 0xb05
    sd t1, 16(s0)
    csrr t1, 0xb06
    sd t1, 24(s0)
    csrr t1, 0xb07
    sd t1, 32(s0)
    csrr t1, 0xb08
    sd t1, 40(s0)
    csrr t1, 0xb09
    sd t1, 48(s0)
    csrr t1, 0xb0a
    sd t1, 56(s0)
    addi s0, s0, 64
    csrw 0x320, zero
.endm
_start:
    la s0, samples
    li t0, 0x7f8
    csrw 0x320, t0
    event 0x323, 0x0102, 0x010f
    event 0x324, 0x0105, 0x0110
    event 0x325, 0x0107, 0x0111
    event 0x326, 0x0108, 0x0112
    event 0x327, 0x010f, 0x0113
    event 0x328, 0x0114, 0x0108
    event 0x329, 0, 0
    event 0x32a, 0, 0
    csrw 0xb03, zero
    csrw 0xb04, zero
    csrw 0xb05, zero
    csrw 0xb06, zero
    csrw 0xb07, zero
    csrw 0xb08, zero
    csrw 0xb09, zero
    csrw 0xb0a, zero
    csrw 0x320, zero
    sample
.globl segment1_begin
segment1_begin:
    li s1, 1000
    li s2, 0
    li s11, 0
.balign 16
branch_loop:
    addi s2, s2, 1
    andi t1, s2, 1
    beq t1, zero, branch_taken
    addi s11, s11, 1
branch_taken:
    addi s1, s1, -1
    bnez s1, branch_loop
    li t2, 500
    bne s11, t2, fail
.globl segment1_end
segment1_end:
    sample
    sample
.globl segment2_begin
segment2_begin:
    li s1, 100
.balign 16
call_loop:
    jal ra, level1
    li t2, 8
    bne a0, t2, fail
    addi s1, s1, -1
    bnez s1, call_loop
.globl segment2_end
segment2_end:
    sample
    sample
.globl segment3_begin
segment3_begin:
    li s1, 100
    li s2, 0
    j large0
.macro region n, next
    .balign 16
large\n:
    addi s2, s2, 1
    j large\next
.endm
    region 0,1
    region 1,2
    region 2,3
    region 3,4
    region 4,5
    region 5,6
    region 6,7
    region 7,8
    region 8,9
    region 9,10
    region 10,11
    region 11,12
    region 12,13
    region 13,14
    region 14,15
    region 15,16
    region 16,17
    region 17,18
    region 18,19
    region 19,20
    region 20,21
    region 21,22
    region 22,23
    region 23,24
    region 24,25
    region 25,26
    region 26,27
    region 27,28
    region 28,29
    region 29,30
    region 30,31
    region 31,32
    region 32,33
    region 33,34
    region 34,35
    region 35,36
    region 36,37
    region 37,38
    region 38,39
.balign 16
large39:
    addi s2, s2, 1
    addi s1, s1, -1
    bnez s1, large0
    li t2, 4000
    bne s2, t2, fail
.globl segment3_end
segment3_end:
    sample
    j final_checks
// Eight nested calls, register-saved link addresses; every return value checked.
.macro level n, next, saved, expected
    .balign 16
level\n:
    mv \saved, ra
    jal ra, level\next
    li t2, \expected
    bne a0, t2, fail
    addi a0, a0, 1
    mv ra, \saved
    ret
.endm
    level 1,2,s3,7
    level 2,3,s4,6
    level 3,4,s5,5
    level 4,5,s6,4
    level 5,6,s7,3
    level 6,7,s8,2
    level 7,8,s9,1
.balign 16
level8:
    li a0, 1
    ret
// Group-specific validation is after all measured code and sampling windows.
final_checks:
    la s0, samples
#ifdef GROUP_B
    li s1, 3
classification_check:
    ld t0, 64(s0)
    ld t1, 0(s0)
    sub t0, t0, t1
    li t3, 0
    ld t1, 72(s0)
    ld t2, 8(s0)
    sub t1, t1, t2
    add t3, t3, t1
    ld t1, 80(s0)
    ld t2, 16(s0)
    sub t1, t1, t2
    add t3, t3, t1
    ld t1, 88(s0)
    ld t2, 24(s0)
    sub t1, t1, t2
    add t3, t3, t1
    ld t1, 96(s0)
    ld t2, 32(s0)
    sub t1, t1, t2
    add t3, t3, t1
    bne t0, t3, fail
    addi s0, s0, 128
    addi s1, s1, -1
    bnez s1, classification_check
#else
    la s10, performance_markers
    // Segment 1: 2000 loop BRs + one result-check BR = 2001 dynamic CFIs.
    ld t0, 88(s0)
    ld t1, 24(s0)
    sub t0, t0, t1
    slli t0, t0, 2
    li t2, 2001
    sltu t3, t0, t2
    sd t3, 0(s10)
    // Segment 2: 8 JAL + 8 returns + 7 inner checks + 2 loop/check BRs
    // per iteration, repeated 100 times = 2500 dynamic CFIs.
    ld t0, 216(s0)
    ld t1, 152(s0)
    sub t0, t0, t1
    slli t0, t0, 2
    li t2, 2500
    sltu t3, t0, t2
    sd t3, 8(s10)
    ld t0, 328(s0)
    ld t1, 264(s0)
    sub t0, t0, t1
    sltu t3, zero, t0
    sd t3, 16(s10)
#endif
    la t0, tohost
    li t1, 1
    sd t1, 0(t0)
1:  j 1b
// Keep all earlier result-check branch encodings identical between groups.
.org 0x1000
fail:
    la t0, tohost
    li t1, 3
    sd t1, 0(t0)
2:  j 2b
.section .data
.balign 64
.globl samples
samples: .zero 384
.globl performance_markers
performance_markers: .zero 24
