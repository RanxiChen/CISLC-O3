// Shared N6 self-check / exact cause+tval trap fixture. No external oracle.
.option norvc
.option norelax
.macro boot
    la t0,trap_handler
    csrw mtvec,t0
    li s3,0                  // synchronous traps
    li s4,0                  // interrupts
    li s0,-1                 // unexpected trap must fail
    li s5,0x02000000
.endm
.macro fault cause, address, resume
    li s0,\cause
    mv s1,\address
    la s2,\resume
.endm
.macro check reg, value
    li t6,\value
    bne \reg,t6,fail
.endm
.macro finish traps
    check s3,\traps
    li t0,0x801ff000
    li t1,1
    sd t1,0(t0)
    j .
.endm
.macro handlers
.balign 16
trap_handler:
    csrr t4,mcause
    bltz t4,irq_handler
    bne t4,s0,fail
    csrr t4,mtval
    bne t4,s1,fail
    csrw mepc,s2
    addi s3,s3,1
    mret
irq_handler:
    li t5,0x8000000000000003
    bne t4,t5,fail
    li t4,0x02000838
    sd zero,0(t4)
    addi s4,s4,1
    mret
fail:
    li t0,0x801ff000
    li t1,3
    sd t1,0(t0)
    j .
.endm
