#include "l8b_common.h"
.section .text.init
.globl _start
_start:
    boot
    la a0,dma_line
    li a1,0x02000900
    sd a0,8(a1)
    li t0,-1
    sd t0,16(a1)
    li a2,0x1122334455667788
    li t0,8
    mv t1,a0
dirty_line:
    sd a2,0(t1)
    addi t1,t1,8
    addi t0,t0,-1
    bnez t0,dirty_line
    fence iorw,iorw
    li t0,1
    sd t0,0(a1)
    jal ra,wait_dma
    li t0,0x02000a00
    li t1,8
check_read:
    ld t2,0(t0)
    bne t2,a2,fail
    addi t0,t0,8
    addi t1,t1,-1
    bnez t1,check_read
    li a2,0xaabbccddeeff0011
    sd a2,24(a1)
    li t0,2
    sd t0,0(a1)
    jal ra,wait_dma
    li t1,8
    mv t0,a0
check_write:
    ld t2,0(t0)
    bne t2,a2,fail
    addi t0,t0,8
    addi t1,t1,-1
    bnez t1,check_write
    // Sparse byte mask: each touched byte is observed, untouched bytes retained.
    li t0,0x5555555555555555
    sd t0,16(a1)
    li t0,0x123456789abcdef0
    sd t0,24(a1)
    li t0,2
    sd t0,0(a1)
    jal ra,wait_dma
    ld t0,0(a0)
    check t0,0xaa34cc78eebc00f0
    li t0,-1
    sd t0,16(a1)
    lr.d t2,(a0)
    li t0,2
    sd t0,0(a1)
    jal ra,wait_dma
    sc.d t0,t2,(a0)
    check t0,1
    // Alternate full-line writes and loads. A complete 64-bit value must be
    // either the previous pattern or current pattern while DMA is in flight.
    li a3,128
    li a4,0x123456789abcdef0
    li a5,0xfedcba9876543210
alternate:
    sd a5,24(a1)
    li t0,2
    sd t0,0(a1)
    ld t1,0(a0)
    beq t1,a4,value_ok
    bne t1,a5,fail
value_ok:
    jal ra,wait_dma
    ld t1,0(a0)
    bne t1,a5,fail
    mv t0,a4
    mv a4,a5
    mv a5,t0
    addi a3,a3,-1
    bnez a3,alternate
    finish 0
wait_dma:
    ld t3,32(a1)
    andi t4,t3,4
    bnez t4,fail
    li t4,2
    bne t3,t4,wait_dma
    ret
    handlers
.section .data
.balign 64
dma_line: .zero 64
