// Independent T08c positive A/D program; full run-l10-vm remains unchanged.
#ifndef VM_AD
#define VM_AD 1
#endif
.option norvc
.option norelax
.macro expect_fault cause, addr, resume
    li s0, \cause
    li s1, \addr
    la s2, \resume
.endm
.section .text.init
.globl _start
_start:
    la t0,m_handler
    csrw mtvec,t0
    la t0,s_handler
    csrw stvec,t0
    li t0,0x40000000
    csrw pmpaddr0,t0
    li t0,15
    csrw pmpcfg0,t0
    li t0,0xb000
    csrw medeleg,t0
#if VM_AD
    li t0,0x2000000000000000
#else
    li t0,0
#endif
    csrw 0x30a,t0
    la t0,root
    li t1,1536
zero_pt:
    sd zero,0(t0)
    addi t0,t0,8
    addi t1,t1,-1
    bnez t1,zero_pt
    la t0,root
    li t1,0x200000cf             // root[2]: 1GiB identity 0x80000000
    sd t1,16(t0)
    la t1,middle
    srli t1,t1,12
    slli t1,t1,10
    ori t1,t1,1
    sd t1,0(t0)
    la t0,middle
    la t1,leaf
    srli t1,t1,12
    slli t1,t1,10
    ori t1,t1,1
    sd t1,0(t0)
    li t1,0x200000c7             // VA 0x200000: 2MiB data alias
    sd t1,8(t0)
    la t0,leaf
    la t1,data_a
    srli t1,t1,12
    slli t1,t1,10
    ori t1,t1,0xc7
    sd t1,32(t0)                // VA 0x4000 RW supervisor
    ori t2,t1,16
    sd t2,40(t0)                // VA 0x5000 U
    andi t2,t1,-5
    sd t2,48(t0)                // VA 0x6000 R, NX
    andi t2,t1,-193
    sd t2,56(t0)                // VA 0x7000 A=D=0
    la t1,protected_word
    srli t1,t1,12
    slli t1,t1,10
    ori t1,t1,0xc7
    sd t1,64(t0)                // VA 0x8000 protected PA
    fence rw,rw
    la t0,root
    srli t0,t0,12
    li t1,0x8000000000000000
    or t0,t0,t1
    csrw satp,t0
    sfence.vma zero,zero
    la t0,s_start
    csrw mepc,t0
    li t0,0x800
    csrw mstatus,t0
    mret
s_start:
    // Load sets A without D. The next store is the first writer of this page.
    li t0,0x7000
    ld t1,0(t0)
    li t2,0x11223344
    bne t1,t2,fail
    la t0,leaf
    ld t1,56(t0)
    andi t1,t1,0xc0
    li t2,0x40
    bne t1,t2,fail
    li t0,0x7000
    li t1,0x55667788
    sd t1,0(t0)
    ld t2,0(t0)              // younger load must wait behind needs_D
    bne t1,t2,fail
    fence rw,rw
    la t0,leaf
    ld t1,56(t0)
    andi t1,t1,0xc0
    li t2,0xc0
    bne t1,t2,fail
    li t0,0x801ff000
    li t1,1
    sd t1,0(t0)
    j .
m_handler:
s_handler:
fail:
    li t0,0x801ff000
    li t1,3
    sd t1,0(t0)
    j .
.section .data
.balign 4096
root: .zero 4096
middle: .zero 4096
leaf: .zero 4096
.balign 4096
data_a: .dword 0x11223344
.balign 4096
data_b: .dword 0x99aabbcc
.balign 4096
protected_word: .dword 0
