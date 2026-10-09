/* Source: Breeze litex_wrapper/flow/crt0.S @ ec899c7c4367cfab56b9a6206d82066bc79f8a8b; O3 adaptation. */
#define MIE_MEIE 0x800

	.section .text, "ax", @progbits
	.global _start
	.global main
	.global isr
	.global smp_ap_args
	.global smp_ap_target
	.global smp_ap_ready

_start:
	j crt_init
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	.align 4
trap_vector:
	addi sp, sp, -50*8
	sd ra,   0*8(sp)
	sd t0,   1*8(sp)
	sd t1,   2*8(sp)
	sd t2,   3*8(sp)
	sd a0,   4*8(sp)
	sd a1,   5*8(sp)
	sd a2,   6*8(sp)
	sd a3,   7*8(sp)
	sd a4,   8*8(sp)
	sd a5,   9*8(sp)
	sd a6,  10*8(sp)
	sd a7,  11*8(sp)
	sd t3,  12*8(sp)
	sd t4,  13*8(sp)
	sd t5,  14*8(sp)
	sd t6,  15*8(sp)
	fsd f0, 16*8(sp)
	fsd f1, 17*8(sp)
	fsd f2, 18*8(sp)
	fsd f3, 19*8(sp)
	fsd f4, 20*8(sp)
	fsd f5, 21*8(sp)
	fsd f6, 22*8(sp)
	fsd f7, 23*8(sp)
	fsd f8, 24*8(sp)
	fsd f9, 25*8(sp)
	fsd f10, 26*8(sp)
	fsd f11, 27*8(sp)
	fsd f12, 28*8(sp)
	fsd f13, 29*8(sp)
	fsd f14, 30*8(sp)
	fsd f15, 31*8(sp)
	fsd f16, 32*8(sp)
	fsd f17, 33*8(sp)
	fsd f18, 34*8(sp)
	fsd f19, 35*8(sp)
	fsd f20, 36*8(sp)
	fsd f21, 37*8(sp)
	fsd f22, 38*8(sp)
	fsd f23, 39*8(sp)
	fsd f24, 40*8(sp)
	fsd f25, 41*8(sp)
	fsd f26, 42*8(sp)
	fsd f27, 43*8(sp)
	fsd f28, 44*8(sp)
	fsd f29, 45*8(sp)
	fsd f30, 46*8(sp)
	fsd f31, 47*8(sp)
	csrr t0, fcsr
	sd t0, 48*8(sp)
	call isr
	fld f0, 16*8(sp)
	fld f1, 17*8(sp)
	fld f2, 18*8(sp)
	fld f3, 19*8(sp)
	fld f4, 20*8(sp)
	fld f5, 21*8(sp)
	fld f6, 22*8(sp)
	fld f7, 23*8(sp)
	fld f8, 24*8(sp)
	fld f9, 25*8(sp)
	fld f10, 26*8(sp)
	fld f11, 27*8(sp)
	fld f12, 28*8(sp)
	fld f13, 29*8(sp)
	fld f14, 30*8(sp)
	fld f15, 31*8(sp)
	fld f16, 32*8(sp)
	fld f17, 33*8(sp)
	fld f18, 34*8(sp)
	fld f19, 35*8(sp)
	fld f20, 36*8(sp)
	fld f21, 37*8(sp)
	fld f22, 38*8(sp)
	fld f23, 39*8(sp)
	fld f24, 40*8(sp)
	fld f25, 41*8(sp)
	fld f26, 42*8(sp)
	fld f27, 43*8(sp)
	fld f28, 44*8(sp)
	fld f29, 45*8(sp)
	fld f30, 46*8(sp)
	fld f31, 47*8(sp)
	ld t0, 48*8(sp)
	csrw fcsr, t0
	ld ra,   0*8(sp)
	ld t0,   1*8(sp)
	ld t1,   2*8(sp)
	ld t2,   3*8(sp)
	ld a0,   4*8(sp)
	ld a1,   5*8(sp)
	ld a2,   6*8(sp)
	ld a3,   7*8(sp)
	ld a4,   8*8(sp)
	ld a5,   9*8(sp)
	ld a6,  10*8(sp)
	ld a7,  11*8(sp)
	ld t3,  12*8(sp)
	ld t4,  13*8(sp)
	ld t5,  14*8(sp)
	ld t6,  15*8(sp)
	addi sp, sp, 50*8
	mret

crt_init:
	/* lp64d BIOS may use F/D registers. FS=Initial before entering C. */
	li t0, 0x2000
	csrs mstatus, t0
	la sp, _fstack
	andi sp, sp, -16
	la t0, trap_vector
	csrw mtvec, t0

	csrr a0, mhartid
	bnez a0, smp_ap_loop

	/* Hart 0 owns C runtime initialization and the LiteX BIOS. */
	la t0, smp_ap_ready
	sd zero, 0(t0)

	la t0, _fdata
	la t1, _edata
	la t2, _fdata_rom
1:	beq t0, t1, 2f
	lbu t3, 0(t2)
	sb t3, 0(t0)
	addi t0, t0, 1
	addi t2, t2, 1
	j 1b
2:
	la t0, _fbss
	la t1, _ebss
3:	beq t0, t1, 4f
	sb zero, 0(t0)
	addi t0, t0, 1
	j 3b
4:

	call litex_startup_init
	call plic_init
	li t0, MIE_MEIE
	csrw mie, t0

	call main
5:	wfi
	j 5b

smp_ap_loop:
	/* Secondary harts do not touch the shared BIOS stack or C runtime. */
	la t0, smp_ap_ready
6:	ld t1, 0(t0)
	beqz t1, 6b
	fence r, r
	fence.i
	csrr a0, mhartid
	la t0, smp_ap_args
	ld a1, 0(t0)
	ld a2, 8(t0)
	la t0, smp_ap_target
	ld t0, 0(t0)
	jr t0

	.section .bss, "aw", @nobits
	.balign 8
smp_ap_args:
	.dword 0
	.dword 0
	.balign 8
smp_ap_target:
	.dword 0
	.balign 8
smp_ap_ready:
	.dword 0
