#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/itype_shift_cmp.json");
    harness.expect_retired_count(18);

    // Setup: x1 = 2047
    // SLLI x2, x1, 1         -> 2047 << 1 = 4094 = 0xFFE
    // SRLI x3, x1, 1         -> 2047 >> 1 = 1023 = 0x3FF
    // SRAI x4, x1, 1         -> 2047 >>> 1 = 1023 = 0x3FF (positive, same as SRL)
    harness.expect_register(1, 0x00000000000007ffULL);
    harness.expect_register(2, 0x0000000000000ffeULL);
    harness.expect_register(3, 0x00000000000003ffULL);
    harness.expect_register(4, 0x00000000000003ffULL);

    // ADDI x5, x0, -1        -> -1
    // SRLI x6, x5, 31        -> u(-1) >> 31 = 0x00000001FFFFFFFF
    // SRAI x7, x5, 31        -> s(-1) >>> 31 = -1  (DIFFERS from x6!)
    harness.expect_register(5, 0xffffffffffffffffULL);
    harness.expect_register(6, 0x00000001ffffffffULL);
    harness.expect_register(7, 0xffffffffffffffffULL);

    // ADDI x8, x0, 1         -> 1
    // SLLI x9, x8, 31        -> 1 << 31 = 0x0000000080000000
    // SRLI x10, x8, 0        -> 1 >> 0 = 1 (shift by 0)
    // SRAI x11, x5, 0        -> -1 >>> 0 = -1 (shift by 0)
    harness.expect_register(8,  0x0000000000000001ULL);
    harness.expect_register(9,  0x0000000080000000ULL);
    harness.expect_register(10, 0x0000000000000001ULL);
    harness.expect_register(11, 0xffffffffffffffffULL);

    // ADDI x12, x0, -5       -> -5  (imm=0xFFB)
    // SLTI x13, x12, 5       -> signed(-5 < 5) = 1
    // SLTIU x14, x12, 3      -> unsigned(-5 < 3) = 0
    // SLTI x15, x12, -5      -> signed(-5 < -5) = 0
    // SLTIU x16, x1, -1      -> unsigned(2047 < u(-1)) = 1
    // SLTI x17, x12, 3       -> signed(-5 < 3) = 1
    // SLTIU x18, x12, 3      -> unsigned(-5 < 3) = 0  (same imm/rs1 as x17, differs!)
    harness.expect_register(12, 0xfffffffffffffffbULL);
    harness.expect_register(13, 0x0000000000000001ULL);
    harness.expect_register(14, 0x0000000000000000ULL);
    harness.expect_register(15, 0x0000000000000000ULL);
    harness.expect_register(16, 0x0000000000000001ULL);
    harness.expect_register(17, 0x0000000000000001ULL);
    harness.expect_register(18, 0x0000000000000000ULL);

    harness.run();

    return 0;
}
