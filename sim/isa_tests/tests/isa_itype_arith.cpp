#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/itype_arith.json");
    harness.expect_retired_count(11);

    // Setup:
    // x1 = ADDI x0, 0x0F0    -> 0x0F0
    // Dependencies: x1 -> x2 -> x3 -> x4, then x5 -> x6 -> x7, x7 -> x9 -> x10 -> x11
    //
    // ORI  x2, x1, 0x005     -> 0x0F0 | 0x005 = 0x0F5
    // XORI x3, x2, 0x005     -> 0x0F5 ^ 0x005 = 0x0F0
    // ANDI x4, x3, 0x0FF     -> 0x0F0 & 0x0FF = 0x0F0
    harness.expect_register(1, 0x00000000000000f0ULL);
    harness.expect_register(2, 0x00000000000000f5ULL);
    harness.expect_register(3, 0x00000000000000f0ULL);
    harness.expect_register(4, 0x00000000000000f0ULL);

    // ADDI x5, x0, -1        -> -1
    // ORI  x6, x5, 0x00F     -> -1 | 0x00F = -1
    // XORI x7, x6, 0xFFF     -> -1 ^ -1 = 0
    // ANDI x8, x5, 0x00F     -> -1 & 0x00F = 0x00F
    harness.expect_register(5, 0xffffffffffffffffULL);
    harness.expect_register(6, 0xffffffffffffffffULL);
    harness.expect_register(7, 0x0000000000000000ULL);
    harness.expect_register(8, 0x000000000000000fULL);

    // XORI x9, x7, 0x5A5     -> 0 ^ 0x5A5 = 0x5A5
    // ANDI x10, x9, 0xF00    -> 0x5A5 & sign_ext(0xF00) = 0x500
    // ORI  x11, x10, 0x0F0   -> 0x500 | 0x0F0 = 0x5F0
    harness.expect_register(9,  0x00000000000005a5ULL);
    harness.expect_register(10, 0x0000000000000500ULL);
    harness.expect_register(11, 0x00000000000005f0ULL);

    harness.run();

    return 0;
}
