// L5 boot/mailbox harness; upstream test bodies and expected values are unmodified.
#ifndef CISLC_O3_L5_TEST_H
#define CISLC_O3_L5_TEST_H
#include "encoding.h"
#define TESTNUM gp
#define RVTEST_RV64M
#define RVTEST_RV64S
#define RVTEST_CODE_BEGIN \
  .section .text.init; .align 6; .globl _start; \
  _start:; li TESTNUM, 0; \
  .weak mtvec_handler; la t0, mtvec_handler; bnez t0, 1f; \
  la t0, .Ldefault_trap; 1: csrw mtvec, t0;
#define RVTEST_CODE_END \
  j .; .Ldefault_trap:; li TESTNUM, 1; RVTEST_FAIL;
#define RVTEST_PASS \
  li TESTNUM, 1; la t0, tohost; sd TESTNUM, 0(t0); j .;
#define RVTEST_FAIL \
  slli TESTNUM, TESTNUM, 1; ori TESTNUM, TESTNUM, 1; la t0, tohost; sd TESTNUM, 0(t0); j .;
#define RVTEST_DATA_BEGIN .balign 16; .globl begin_signature; begin_signature:
#define RVTEST_DATA_END .globl end_signature; end_signature:
#endif
