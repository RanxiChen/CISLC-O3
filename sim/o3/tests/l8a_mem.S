// M6: self-checking L8a stream, independent misses, RFO, bank and Down probe.
.option norvc
.option norelax
.section .text.init
.globl _start
.macro eight_loads
    ld a0,0(s0)
    ld a1,0(s1)
    ld a2,0(s2)
    ld a3,0(s3)
    ld a4,0(s4)
    ld a5,0(s5)
    ld a6,0(s6)
    ld a7,0(s7)
.endm
.macro advance
    addi s0,s0,64
    addi s1,s1,64
    addi s2,s2,64
    addi s3,s3,64
    addi s4,s4,64
    addi s5,s5,64
    addi s6,s6,64
    addi s7,s7,64
.endm
.macro bases
    la s0,array
    li t0,8192
    add s1,s0,t0
    addi s1,s1,8
    add s2,s1,t0
    addi s2,s2,8
    add s3,s2,t0
    addi s3,s3,8
    add s4,s3,t0
    addi s4,s4,8
    add s5,s4,t0
    addi s5,s5,8
    add s6,s5,t0
    addi s6,s6,8
    add s7,s6,t0
    addi s7,s7,8
.endm
.macro check_word reg,offset
    li t0,\offset
    add t0,t0,s8
    xori t0,t0,0x5a5
    bne \reg,t0,fail
.endm
_start:
    li s11,1
    bases
    li s9,128
cold_loop:
    // Eight independent first touches over 64KiB, on eight distinct banks.
    eight_loads
    or t0,a0,a1
    or t0,t0,a2
    or t0,t0,a3
    or t0,t0,a4
    or t0,t0,a5
    or t0,t0,a6
    or t0,t0,a7
    bnez t0,fail
    advance
    addi s9,s9,-1
    bnez s9,cold_loop
    li s11,2
    la s0,array
    li s8,0
    li s9,1024
store_loop:
    // Eight writes to every line; the 64KiB traversal exceeds the 32KiB L1D.
    xori t0,s8,0x5a5
    sd t0,0(s0)
    sd t0,8(s0)
    sd t0,16(s0)
    sd t0,24(s0)
    sd t0,32(s0)
    sd t0,40(s0)
    sd t0,48(s0)
    sd t0,56(s0)
    addi s0,s0,64
    addi s8,s8,1
    addi s9,s9,-1
    bnez s9,store_loop
    li s11,3
    la s0,array
    li s8,0
    li s9,1024
verify_loop:
    ld a0,0(s0)
    ld a1,8(s0)
    ld a2,16(s0)
    ld a3,24(s0)
    ld a4,32(s0)
    ld a5,40(s0)
    ld a6,48(s0)
    ld a7,56(s0)
    check_word a0,0
    check_word a1,0
    check_word a2,0
    check_word a3,0
    check_word a4,0
    check_word a5,0
    check_word a6,0
    check_word a7,0
    addi s0,s0,64
    addi s8,s8,1
    addi s9,s9,-1
    bnez s9,verify_loop
    li s11,4
    la s0,array
    // A line miss with multiple independent waiting words, then resident hits.
    ld a0,0(s0)
    ld a1,8(s0)
    ld a2,16(s0)
    ld a3,24(s0)
    li t0,0x5a5
    bne a0,t0,fail
    bne a1,t0,fail
    bne a2,t0,fail
    bne a3,t0,fail
    li s11,5
    li s9,128
bank_loop:
    // Both addresses target word bank 0 in different sets.
    ld a0,0(s0)
    ld a1,64(s0)
    li t0,0x5a5
    bne a0,t0,fail
    li t0,0x5a4
    bne a1,t0,fail
    addi s9,s9,-1
    bnez s9,bank_loop
    li s11,6
    la t0,mixed_line
    li s10,0x123456789abcdef
    sd s10,32(t0)
    fence.i
    jal ra,mixed_line
    bne a0,s10,fail
    la t0,tohost
    li t1,1
    sd t1,0(t0)
1:  j 1b
fail:
    la t0,tohost
    slli t1,s11,1
    ori t1,t1,1
    sd t1,0(t0)
2:  j 2b
.org 0x2000
.balign 64
mixed_line:
    auipc t0,0
    ld a0,32(t0)
    ret
.balign 32
    .dword 0
.section .data
.balign 4096
array: .zero 65536
