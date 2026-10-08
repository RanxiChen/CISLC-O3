// L7c 14.2: fixed PCs and instruction counts in feature-on/off builds.
.option norvc
.option norelax
.section .text.init
.globl _start
.macro select csr, event
 li t0, \event
 csrw \csr,t0
.endm
.macro zero_hpm
 csrw 0xb03,zero
 csrw 0xb04,zero
 csrw 0xb05,zero
 csrw 0xb06,zero
 csrw 0xb07,zero
 csrw 0xb08,zero
 csrw 0xb09,zero
 csrw 0xb0a,zero
.endm
.macro sample
 li t0,0x7f8
 csrw 0x320,t0
 csrr t1,0xb03
 sd t1,0(s0)
 csrr t1,0xb04
 sd t1,8(s0)
 csrr t1,0xb05
 sd t1,16(s0)
 csrr t1,0xb06
 sd t1,24(s0)
 csrr t1,0xb07
 sd t1,32(s0)
 csrr t1,0xb08
 sd t1,40(s0)
 csrr t1,0xb09
 sd t1,48(s0)
 csrr t1,0xb0a
 sd t1,56(s0)
 csrr t1,0xb00
 sd t1,64(s0)
 addi s0,s0,72
 csrw 0x320,zero
.endm
_start:
 la t0,fail
 csrw mtvec,t0
 la s0,samples
#ifdef FE_OFF
 li t0,3
#else
 li t0,0
#endif
 csrw 0x7c0,t0
 csrr t1,0x7c0
 bne t0,t1,fail
 li t0,0x7f8
 csrw 0x320,t0
 select 0x323,0x134
 select 0x324,0x135
 select 0x325,0x136
 select 0x326,0x13b
 select 0x327,0x13c
 select 0x328,0x10f
 select 0x329,0x13d
 select 0x32a,0
 zero_hpm
 sample
 li s3,40
 li s2,0
outer_loop:
 li s1,300
.balign 16
long_loop:
 addi s2,s2,1
 addi s1,s1,-1
 bnez s1,long_loop
 nop
 addi s3,s3,-1
 bnez s3,outer_loop
 li t0,12000
 bne s2,t0,fail
 sample
 // FENCE.I guarantees an initially cold instruction stream in both groups.
 fence.i
 li t0,0x7f8
 csrw 0x320,t0
 select 0x323,0x123
 select 0x324,0x12b
 select 0x325,0x13f
 select 0x326,0x140
 select 0x327,0x141
 select 0x328,0x12d
 select 0x329,0x142
 select 0x32a,0x12a
 zero_hpm
 sample
 li s2,0
 li s3,0
 li s4,0
 li s5,0
 j cold0
.macro cold n,next
 .balign 16
cold\n:
 .rept 7
 addi s2,s2,1
 addi s3,s3,1
 addi s4,s4,1
 addi s5,s5,1
 .endr
 beq zero,zero,cold\next
 .rept 3
 nop
 .endr
.endm
 cold 0,1
 cold 1,2
 cold 2,3
 cold 3,4
 cold 4,5
 cold 5,6
 cold 6,7
 cold 7,8
 cold 8,9
 cold 9,10
 cold 10,11
 cold 11,12
 cold 12,13
 cold 13,14
 cold 14,15
 cold 15,16
 cold 16,17
 cold 17,18
 cold 18,19
 cold 19,20
 cold 20,21
 cold 21,22
 cold 22,23
 cold 23,24
 cold 24,25
 cold 25,26
 cold 26,27
 cold 27,28
 cold 28,29
 cold 29,30
 cold 30,31
 cold 31,32
 cold 32,33
 cold 33,34
 cold 34,35
 cold 35,36
 cold 36,37
 cold 37,38
 cold 38,39
 cold 39,40
 cold 40,41
 cold 41,42
 cold 42,43
 cold 43,44
 cold 44,45
 cold 45,46
 cold 46,47
 cold 47,48
 cold 48,49
 cold 49,50
 cold 50,51
 cold 51,52
 cold 52,53
 cold 53,54
 cold 54,55
 cold 55,56
 cold 56,57
 cold 57,58
 cold 58,59
 cold 59,60
 cold 60,61
 cold 61,62
 cold 62,63
 cold 63,64
 cold 64,65
 cold 65,66
 cold 66,67
 cold 67,68
 cold 68,69
 cold 69,70
 cold 70,71
 cold 71,72
 cold 72,73
 cold 73,74
 cold 74,75
 cold 75,76
 cold 76,77
 cold 77,78
 cold 78,79
 cold 79,80
 .balign 16
cold80:
 li t0,560
 bne s2,t0,fail
 bne s3,t0,fail
 bne s4,t0,fail
 bne s5,t0,fail
 sample
 li t0,0x7f8
 csrw 0x320,t0
 select 0x323,0x10f
 select 0x324,0x13d
 select 0x325,0x115
 select 0x326,0x12e
 select 0x327,0x132
 select 0x328,0x133
 select 0x329,0x130
 select 0x32a,0x13e
 zero_hpm
 sample
 li s1,200
 li s2,0
 j short0
.macro short n,next
 .balign 16
short\n:
 addi s2,s2,1
 j short\next
.endm
 short 0,1
 short 1,2
 short 2,3
 short 3,4
 short 4,5
 short 5,6
 short 6,7
 short 7,8
 short 8,9
 short 9,10
 short 10,11
 short 11,12
 short 12,13
 short 13,14
 short 14,15
 short 15,16
 short 16,17
 short 17,18
 short 18,19
 short 19,20
 short 20,21
 short 21,22
 short 22,23
 short 23,24
 .balign 16
short24:
 addi s1,s1,-1
 bnez s1,short0
 li t0,4800
 bne s2,t0,fail
 sample
 li t0,1
 la t1,tohost
 sd t0,0(t1)
1: j 1b
fail:
 li t0,3
 la t1,tohost
 sd t0,0(t1)
2: j 2b
.section .data
.balign 8
samples: .zero 432
