#include "l8b_common.h"
.section .text.init
.globl _start
_start:
    boot
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x11
    sb t1,0(s5)
    lbu t2,0(s5)
    check t2,0x11
    ld t2,0(s5)
    check t2,0xaaaaaaaaaaaaaa11
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x11
    sb t1,1(s5)
    lbu t2,1(s5)
    check t2,0x11
    ld t2,0(s5)
    check t2,0xaaaaaaaaaaaa11aa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x11
    sb t1,2(s5)
    lbu t2,2(s5)
    check t2,0x11
    ld t2,0(s5)
    check t2,0xaaaaaaaaaa11aaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x11
    sb t1,3(s5)
    lbu t2,3(s5)
    check t2,0x11
    ld t2,0(s5)
    check t2,0xaaaaaaaa11aaaaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x11
    sb t1,4(s5)
    lbu t2,4(s5)
    check t2,0x11
    ld t2,0(s5)
    check t2,0xaaaaaa11aaaaaaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x11
    sb t1,5(s5)
    lbu t2,5(s5)
    check t2,0x11
    ld t2,0(s5)
    check t2,0xaaaa11aaaaaaaaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x11
    sb t1,6(s5)
    lbu t2,6(s5)
    check t2,0x11
    ld t2,0(s5)
    check t2,0xaa11aaaaaaaaaaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x11
    sb t1,7(s5)
    lbu t2,7(s5)
    check t2,0x11
    ld t2,0(s5)
    check t2,0x11aaaaaaaaaaaaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x2211
    sh t1,0(s5)
    lhu t2,0(s5)
    check t2,0x2211
    ld t2,0(s5)
    check t2,0xaaaaaaaaaaaa2211
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x2211
    sh t1,2(s5)
    lhu t2,2(s5)
    check t2,0x2211
    ld t2,0(s5)
    check t2,0xaaaaaaaa2211aaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x2211
    sh t1,4(s5)
    lhu t2,4(s5)
    check t2,0x2211
    ld t2,0(s5)
    check t2,0xaaaa2211aaaaaaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x2211
    sh t1,6(s5)
    lhu t2,6(s5)
    check t2,0x2211
    ld t2,0(s5)
    check t2,0x2211aaaaaaaaaaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x44332211
    sw t1,0(s5)
    lwu t2,0(s5)
    check t2,0x44332211
    ld t2,0(s5)
    check t2,0xaaaaaaaa44332211
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x44332211
    sw t1,4(s5)
    lwu t2,4(s5)
    check t2,0x44332211
    ld t2,0(s5)
    check t2,0x44332211aaaaaaaa
    li t0,0xaaaaaaaaaaaaaaaa
    sd t0,0(s5)
    li t1,0x8877665544332211
    sd t1,0(s5)
    ld t2,0(s5)
    check t2,0x8877665544332211
    ld t2,0(s5)
    check t2,0x8877665544332211
    // Warm predictor with alternating outcomes; wrong-path MMIO reads
    // after a slow DIV are forbidden. Snapshot has no read side effect.
    li a0,0x02000800
    li a1,0x02000808
    li a2,0
    li a3,64
    li a4,1234567
side_loop:
    div t0,a4,a4
    beqz t0,wrong_path
    andi t0,a2,1
    beqz t0,even_side
    ld t1,0(a0)
    bne t1,a2,fail
    j side_join
even_side:
    ld t1,0(a0)
    bne t1,a2,fail
side_join:
    addi a2,a2,1
    blt a2,a3,side_loop
    j after_wrong
wrong_path:
    ld t1,0(a0)              // never architecturally executed
    j fail
after_wrong:
    ld t1,0(a1)
    check t1,64
    li t0,8
    csrw mie,t0
    csrs mstatus,t0
    li t1,0x02000830
    li t0,1
    sd t0,0(t1)             // model raises MSI until handler clears it
    li a3,96
irq_side_loop:
    ld t1,0(a0)
    bne t1,a2,fail
    addi a2,a2,1
    blt a2,a3,irq_side_loop
    ld t1,0(a1)
    check t1,96
    check s4,1
    csrw mie,zero
    li t0,8
    csrc mstatus,t0
    li a0,0x02000f00
    fault 5,a0,after_read_error
    ld t1,0(a0)
    j fail
after_read_error:
    fault 7,a0,after_write_error
    sd zero,0(a0)
    j fail
after_write_error:
    li a0,0x02000001
    fault 4,a0,after_load_align
    ld t1,0(a0)
    j fail
after_load_align:
    fault 6,a0,after_store_align
    sd zero,0(a0)
    j fail
after_store_align:
    li a0,0x02000000
    fault 1,a0,after_io_fetch
    jr a0
    j fail
after_io_fetch:
    fault 7,a0,after_io_amo
    amoadd.d t1,zero,(a0)
    j fail
after_io_amo:
    // FENCE orders main-memory dirty store before DMA READ commanded via IO.
    la a0,ordered_line
    li t1,0x1122334455667788
    sd t1,0(a0)
    fence iorw,iorw
    li a1,0x02000908
    sd a0,0(a1)
    li t0,1
    li a1,0x02000900
    sd t0,0(a1)
    fence iorw,iorw
    li a1,0x02000920
wait_order_dma:
    ld t0,0(a1)
    li t2,2
    bne t0,t2,wait_order_dma
    li a1,0x02000a00
    ld t0,0(a1)
    check t0,0x1122334455667788
    // IO write before fenced main-memory store is also observed afterwards.
    li t1,0x99
    sd t1,8(s5)
    fence iorw,iorw
    sd t1,8(a0)
    fence iorw,iorw
    ld t0,8(s5)
    check t0,0x99
    ld t0,8(a0)
    check t0,0x99
    finish 6
    handlers
.section .data
.balign 64
ordered_line: .zero 64
