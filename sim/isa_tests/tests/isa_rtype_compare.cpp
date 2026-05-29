#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/rtype_compare.json");
    harness.expect_retired_count(23);

    // Setup: x1=-5, x2=3, x3=-1, x4=0, x5=5
    // SLT  / SLTU results:
    // SLT  x6,  x1, x2  -> (-5 < 3)             -> 1
    harness.expect_register(6,  0x0000000000000001ULL);
    // SLT  x7,  x2, x1  -> (3 < -5)             -> 0
    harness.expect_register(7,  0x0000000000000000ULL);
    // SLTU x8,  x1, x2  -> u(-5) < 3            -> 0
    harness.expect_register(8,  0x0000000000000000ULL);
    // SLTU x9,  x2, x1  -> 3 < u(-5)            -> 1
    harness.expect_register(9,  0x0000000000000001ULL);
    // SLT  x10, x1, x3  -> (-5 < -1)            -> 1
    harness.expect_register(10, 0x0000000000000001ULL);
    // SLT  x11, x3, x1  -> (-1 < -5)            -> 0
    harness.expect_register(11, 0x0000000000000000ULL);
    // SLTU x12, x1, x3  -> u(-5) < u(-1)        -> 1
    harness.expect_register(12, 0x0000000000000001ULL);
    // SLTU x13, x3, x1  -> u(-1) < u(-5)        -> 0
    harness.expect_register(13, 0x0000000000000000ULL);
    // SLT  x14, x1, x4  -> (-5 < 0)             -> 1
    harness.expect_register(14, 0x0000000000000001ULL);
    // SLT  x15, x4, x1  -> (0 < -5)             -> 0
    harness.expect_register(15, 0x0000000000000000ULL);
    // SLTU x16, x1, x4  -> u(-5) < 0            -> 0
    harness.expect_register(16, 0x0000000000000000ULL);
    // SLTU x17, x4, x1  -> 0 < u(-5)            -> 1
    harness.expect_register(17, 0x0000000000000001ULL);
    // SLT  x18, x2, x5  -> (3 < 5)              -> 1
    harness.expect_register(18, 0x0000000000000001ULL);
    // SLT  x19, x5, x2  -> (5 < 3)              -> 0
    harness.expect_register(19, 0x0000000000000000ULL);
    // SLTU x20, x2, x5  -> (3 < 5)              -> 1
    harness.expect_register(20, 0x0000000000000001ULL);
    // SLTU x21, x5, x2  -> (5 < 3)              -> 0
    harness.expect_register(21, 0x0000000000000000ULL);
    // SLT  x22, x1, x1  -> (-5 < -5)            -> 0
    harness.expect_register(22, 0x0000000000000000ULL);
    // SLTU x23, x1, x1  -> u(-5) < u(-5)        -> 0
    harness.expect_register(23, 0x0000000000000000ULL);

    harness.run();

    return 0;
}
