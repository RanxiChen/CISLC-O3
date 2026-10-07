// RV64C integer end-to-end test. No Spike; tohost self-checks 100 iterations.
.option norelax
.option rvc
.section .text.init
.globl _start
_start:
    la t0, fail
    csrw mtvec, t0
    li s0, 100
    li s1, 0
    la t2, leaf
loop:
    c.beqz s0, finish
    c.addi s1, 1
    c.j call_site
    c.j fail
call_site:
    c.jalr t2
    .balign 16
    .rept 7
    c.nop
    .endr
edge_branch:
    .option norvc
    beq zero, zero, edge_target
    .option rvc
    c.j fail
edge_target:
    c.addi s1, 1
    // Jump exactly to the first halfword at slot 7: an empty F0 beat.
    j zero_target
    .balign 16
    .rept 7
    c.nop
    .endr
zero_target:
    .option norvc
    addi s1, s1, 1
    .option rvc
    c.addi s0, -1
    c.bnez s0, loop
finish:
    li t0, 400
    bne s1, t0, fail
    la t0, tohost
    li t1, 1
    sd t1, 0(t0)
1:  c.j 1b
leaf:
    c.addi s1, 1
    c.jr ra
    .balign 4
fail:
    la t0, tohost
    li t1, 3
    sd t1, 0(t0)
2:  c.j 2b
