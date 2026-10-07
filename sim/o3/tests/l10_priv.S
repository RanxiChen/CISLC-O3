// Frozen L10 13.3. Each expected trap has a distinct phase in s2.
.option norvc
.option norelax
.section .text.init
.globl _start
_start:
    li s2, 0
    li s3, 0
    li s4, 0
    la t0, m_handler
    csrw mtvec, t0
    la t0, s_handler
    csrw stvec, t0
    li t0, 0x40000000
    csrw pmpaddr0, t0
    li t0, 0x0f
    csrw pmpcfg0, t0
    li t0, 0x100
    csrw medeleg, t0
    li t0, 0x2022
    csrw mideleg, t0
    li t0, 2
    csrw mcounteren, t0
    csrw scounteren, t0
    li t0, 0xa000000000000000
    csrw 0x30a, t0
    la t0, s_start
    csrw mepc, t0
    li t0, 0x800
    csrw mstatus, t0
.globl first_mret
first_mret:
    mret
s_start:
    la t0, u_start
    csrw sepc, t0
    csrw sstatus, zero
    sret
u_start:
    li s2, 1
    ecall                       // U ECALL -> S, scause=8
    li s2, 2
    csrr t0, sstatus            // U cannot access S CSR -> M, cause=2
    csrr t0, time               // authorized U direct read
    li s2, 3
    ecall                       // S handler returns to S continuation
s_continue:
    li s2, 4
    ecall                       // S ECALL -> M, cause=9; set TSR/TW/TVM
    li s2, 5
    sret                       // TSR, exact tval checked in M
    li s2, 6
    wfi                        // TW, exact tval checked in M
    li s2, 7
    csrr t0, satp               // TVM
    li s2, 8
    ecall                       // M disables TM
    la t0, u_time_denied
    csrw sepc, t0
    csrw sstatus, zero
    sret
u_time_denied:
    li s2, 9
    csrr t0, time               // disabled U time read -> M
    j fail
s_after_time:
    li s2, 10
    ecall                       // restore TM and authorize HPM3
    li s2, 11
    li t0, 2
    csrs sie, t0
    csrs sstatus, t0
    csrs sip, t0                // delegated software SSI
wait_ssi:
    andi t0, s4, 1
    beqz t0, wait_ssi
    li s2, 12
    csrr t0, time
    addi t0, t0, 1000
    csrw 0x14d, t0              // Sstc direct S write
    li t0, 0x20
    csrs sie, t0
    wfi
.globl after_timer_wfi
after_timer_wfi:
    andi t0, s4, 2
    beqz t0, fail               // timer handler checked EPC exactly here
    li s2, 13
    ecall                       // set HPM3 to all ones, count only S/U
    li t0, 0x2000
    csrs sie, t0
wait_lcofi:
    andi t0, s4, 4
    beqz t0, wait_lcofi
    li s2, 14
    ecall                       // protect a 16B NAPOT data region, overlapping NAPOT permits rest
    la s5, protected_word
    li s2, 15
    lw t0, 0(s5)                // PMP load access fault, VA in mtval
    li s2, 16
    sw zero, 0(s5)              // PMP store access fault
    li t0, 12                  // exact expected synchronous+asynchronous trap count
    bne s3, t0, fail
    li t0, 7
    bne s4, t0, fail
    la t0, tohost
    li t1, 1
    sd t1, 0(t0)
1:  j 1b

.balign 16
m_handler:
    csrr t4, mcause
    li t5, 2
    beq t4, t5, m_illegal
    li t5, 9
    beq t4, t5, m_ecall
    li t5, 5
    beq t4, t5, m_load
    li t5, 7
    beq t4, t5, m_store
    j fail
m_illegal:
    csrr t4, mtval
    li t5, 2
    beq s2, t5, illegal_scsr
    li t5, 5
    beq s2, t5, illegal_sret
    li t5, 6
    beq s2, t5, illegal_wfi
    li t5, 7
    beq s2, t5, illegal_satp
    li t5, 9
    beq s2, t5, illegal_time
    j fail
illegal_scsr:
    li t5, 0x100022f3
    bne t4, t5, fail
    j m_skip
illegal_sret:
    li t5, 0x10200073
    bne t4, t5, fail
    li t5, 0x400000
    csrc mstatus, t5
    j m_skip
illegal_wfi:
    li t5, 0x10500073
    bne t4, t5, fail
    li t5, 0x200000
    csrc mstatus, t5
    j m_skip
illegal_satp:
    li t5, 0x180022f3
    bne t4, t5, fail
    li t5, 0x100000
    csrc mstatus, t5
    j m_skip
illegal_time:
    li t5, 0xc01022f3
    bne t4, t5, fail
    la t4, s_after_time
    csrw mepc, t4
    li t5, 0x1800
    csrc mstatus, t5
    li t5, 0x800
    csrs mstatus, t5
    j m_return
m_ecall:
    li t5, 4
    beq s2, t5, set_restrictions
    li t5, 8
    beq s2, t5, disable_time
    li t5, 10
    beq s2, t5, enable_time
    li t5, 13
    beq s2, t5, overflow_setup
    li t5, 14
    beq s2, t5, pmp_setup
    j fail
set_restrictions:
    li t5, 0x700000
    csrs mstatus, t5
    j m_skip
disable_time:
    csrw mcounteren, zero
    j m_skip
enable_time:
    li t5, 0xa
    csrw mcounteren, t5
    j m_skip
overflow_setup:
    li t5, 0x4000000000000101 // MINH; uBTB lookup continues in S
    csrw 0x323, t5
    li t5, -1
    csrw 0xb03, t5
    j m_skip
pmp_setup:
    csrw pmpcfg0, zero
    la t5, protected_word
    srli t5, t5, 2
    ori t5, t5, 1            // G=2 minimum NAPOT region is 16B
    csrw pmpaddr0, t5
    li t5, 0x1fffffff          // NAPOT 0..4 GiB, independent of entry 0 lower bound
    csrw pmpaddr1, t5
    li t5, 0x1f18
    csrw pmpcfg0, t5
    j m_skip
m_load:
    li t5, 15
    bne s2, t5, fail
    j m_check_va
m_store:
    li t5, 16
    bne s2, t5, fail
m_check_va:
    csrr t4, mtval
    bne t4, s5, fail
m_skip:
    csrr t4, mepc
    addi t4, t4, 4
    csrw mepc, t4
m_return:
    addi s3, s3, 1
    mret

.balign 16
s_handler:
    csrr t4, scause
    li t5, 8
    beq t4, t5, s_ecall
    li t5, 0x8000000000000001
    beq t4, t5, s_ssi
    li t5, 0x8000000000000005
    beq t4, t5, s_sti
    li t5, 0x800000000000000d
    beq t4, t5, s_lcofi
    j fail
s_ecall:
    li t5, 1
    beq s2, t5, s_skip
    li t5, 3
    bne s2, t5, fail
    la t4, s_continue
    csrw sepc, t4
    li t5, 0x100
    csrs sstatus, t5
    sret
s_skip:
    csrr t4, sepc
    addi t4, t4, 4
    csrw sepc, t4
    sret
s_ssi:
    li t5, 11
    bne s2, t5, fail
    li t5, 2
    csrc sip, t5
    ori s4, s4, 1
    sret
s_sti:
    li t5, 12
    bne s2, t5, fail
    csrr t4, sepc
    la t5, after_timer_wfi
    bne t4, t5, fail
    li t5, -1
    csrw 0x14d, t5
    ori s4, s4, 2
    sret
s_lcofi:
    li t5, 13
    bne s2, t5, fail
    csrr t4, 0xda0
    andi t4, t4, 8
    beqz t4, fail
    li t5, 0x2000
    csrc sip, t5
    csrc sie, t5
    ori s4, s4, 4
    sret
fail:
    la t0, tohost
    slli t1, s2, 1
    ori t1, t1, 1
    bnez s2, 2f
    li t1, 3
2:  sd t1, 0(t0)
3:  j 3b
.section .data
.balign 16
protected_word: .word 0x13572468
