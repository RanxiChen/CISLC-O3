.option norvc
.option norelax
.section .text.init
.globl _start
_start:
    li t0, -1
    li t1, 3
    # Two destinations and retirement events, one fused execution when visible together.
    mulh a0, t0, t1
    mul a1, t0, t1
    li t2, -1
    bne a0, t2, fail
    li t2, -3
    bne a1, t2, fail
    mulhsu a2, t0, t1
    li t2, -1
    bne a2, t2, fail
    mulhu a3, t0, t1
    li t2, 2
    bne a3, t2, fail
    li t0, 37
    div a0, t0, t1
    # ALU and multiply continue while DIV iterates; a dependent consumer uses the wake/bypass path.
    mul a1, t0, t1
    addi a2, a1, 1
    li t2, 112
    bne a2, t2, fail
    li t2, 12
    bne a0, t2, fail
    rem a0, t0, t1
    li t2, 1
    bne a0, t2, fail
    divu a0, t0, zero
    li t2, -1
    bne a0, t2, fail
    remu a0, t0, zero
    bne a0, t0, fail
    li t0, 0x8000000000000000
    li t1, -1
    div a0, t0, t1
    bne a0, t0, fail
    rem a1, t0, t1
    bnez a1, fail
    li t0, 0x80000000
    divw a0, t0, t1
    li t2, -2147483648
    bne a0, t2, fail
    remw a0, t0, t1
    bnez a0, fail
    divuw a0, t0, t1
    bnez a0, fail
    remuw a0, t0, t1
    bne a0, t2, fail
    mulw a0, t0, t1
    bne a0, t2, fail
    # Resolve a branch behind long DIV while wrong-path M operations can execute.
    li t0, 0x7fffffffffffffff
    li t1, 7
    div a0, t0, t1
    beq a0, a0, correct
    mul a4, t0, t1
    div a5, t0, t1
    li a6, 99
correct:
    li a6, 1
    # Odd target bit0 is cleared. JALR link -> return must retain its own mapping.
    la t0, function
    addi t0, t0, 1
    jalr ra, 0(t0)
return_here:
    li t2, 42
    bne a7, t2, fail
    la t0, tohost
    li t1, 1
    sd t1, 0(t0)
1:  j 1b
function:
    li a7, 42
    jalr zero, 0(ra)
fail:
    la t0, tohost
    li t1, 3
    sd t1, 0(t0)
2:  j 2b
