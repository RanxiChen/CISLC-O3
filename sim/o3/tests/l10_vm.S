// L10 13.3: physical shared-cache page tables, no Spike. VM_AD=0 is T08b.
#ifndef VM_AD
#define VM_AD 0
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
    li s3,0
    li t0,0x4000
    ld t1,0(t0)
    li t2,0x11223344
    bne t1,t2,fail
    li t0,0x200000
    lw t1,0(t0)
    la t0,_start
    lw t2,0(t0)
    bne t1,t2,fail
    expect_fault 13,0x5000,after_sum_fault
    li t0,0x5000
    ld t1,0(t0)
    j fail
after_sum_fault:
    li t0,0x40000
    csrs sstatus,t0
    li t0,0x5000
    ld t1,0(t0)
    li t2,0x11223344
    bne t1,t2,fail
    li t0,0x40000
    csrc sstatus,t0
    expect_fault 15,0x6000,after_store_fault
    li t0,0x6000
    sd zero,0(t0)
    j fail
after_store_fault:
    expect_fault 12,0x6000,after_exec_fault
    li t0,0x6000
    jr t0
    j fail
after_exec_fault:
#if VM_AD
    li t0,0x7000
    ld t1,0(t0)
    la t0,leaf
    ld t1,56(t0)
    andi t1,t1,0xc0
    li t2,0x40
    bne t1,t2,fail            // speculative load sets A only
    li t0,0x7000
    li t1,0x55667788
    sd t1,0(t0)              // D must be set at ROB head
    fence rw,rw
    la t0,leaf
    ld t1,56(t0)
    andi t1,t1,0xc0
    li t2,0xc0
    bne t1,t2,fail
    li t0,0x7000
    ld t1,0(t0)
    li t2,0x55667788
    bne t1,t2,fail
#endif
    li s4,1
    ecall                    // M disables ADUE and clears leaf A/D
    expect_fault 13,0x7000,after_adue_fault
    li t0,0x7000
    ld t1,0(t0)
    j fail
after_adue_fault:
    // New ASID must not use the old ASID's 0x4000 mapping.
    la t0,leaf
    la t1,data_b
    srli t1,t1,12
    slli t1,t1,10
    ori t1,t1,0xc7
    sd t1,32(t0)
    fence rw,rw
    csrr t0,satp
    li t1,0x100000000000
    or t0,t0,t1
    csrw satp,t0
    li t0,0x4000
    ld t1,0(t0)
    li t2,0x99aabbcc
    bne t1,t2,fail
    la t0,leaf
    la t1,data_a
    srli t1,t1,12
    slli t1,t1,10
    ori t1,t1,0xc7
    sd t1,32(t0)
    li t0,0x4000
    sfence.vma t0,zero
    ld t1,0(t0)
#if VM_AD
    li t2,0x55667788
#else
    li t2,0x11223344
#endif
    bne t1,t2,fail
    li s4,2
    ecall                    // M denies the target's 16B PMP region
    expect_fault 5,0x8000,after_pmp_load
    li t0,0x8000
    ld t1,0(t0)
    j fail
after_pmp_load:
    expect_fault 7,0x8000,after_pmp_store
    li t0,0x8000
    sd zero,0(t0)
    j fail
after_pmp_store:
    li t0,6
    bne s3,t0,fail
    li t0,0x801ff000
    li t1,1
    sd t1,0(t0)
    j .
.balign 16
s_handler:
    csrr t4,scause
    bne t4,s0,fail
    csrr t4,stval
    bne t4,s1,fail
    csrw sepc,s2
    addi s3,s3,1
    sret
.balign 16
m_handler:
    csrr t4,mcause
    li t5,9
    beq t4,t5,m_ecall
    bne t4,s0,fail
    csrr t4,mtval
    bne t4,s1,fail
    csrw mepc,s2
    addi s3,s3,1
    mret
m_ecall:
    li t5,1
    bne s4,t5,pmp_setup
    csrw 0x30a,zero
    la t4,leaf
    ld t5,56(t4)
    andi t5,t5,-193
    sd t5,56(t4)
    li t4,0x7000
    sfence.vma t4,zero
    j m_return
pmp_setup:
    csrw pmpcfg0,zero
    la t4,protected_word
    srli t4,t4,2
    ori t4,t4,1
    csrw pmpaddr0,t4
    li t4,0x1fffffff
    csrw pmpaddr1,t4
    li t4,0x1f18
    csrw pmpcfg0,t4
m_return:
    csrr t4,mepc
    addi t4,t4,4
    csrw mepc,t4
    mret
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
