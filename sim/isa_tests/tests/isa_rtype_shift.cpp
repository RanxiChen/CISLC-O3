#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/rtype_shift.json");
    harness.expect_retired_count(21);

    // Setup: x1=1, x2=-1, x3=2047, x4=63
    // R-type shift results:
    // SLL x5,  x1, x4  -> 1 << 63             -> 0x8000000000000000
    harness.expect_register(5,  0x8000000000000000ULL);
    // SRL x6,  x2, x4  -> u(-1) >> 63         -> 1
    harness.expect_register(6,  0x0000000000000001ULL);
    // SRA x7,  x2, x4  -> s(-1) >>> 63        -> -1
    harness.expect_register(7,  0xffffffffffffffffULL);
    // SLL x8,  x3, x1  -> 2047 << 1           -> 4094
    harness.expect_register(8,  0x0000000000000ffeULL);
    // SRL x9,  x3, x1  -> 2047 >> 1           -> 1023
    harness.expect_register(9,  0x00000000000003ffULL);
    // SRA x10, x3, x1  -> 2047 >>> 1          -> 1023
    harness.expect_register(10, 0x00000000000003ffULL);
    // SLL x11, x1, x1  -> 1 << 1              -> 2
    harness.expect_register(11, 0x0000000000000002ULL);
    // SRL x12, x1, x1  -> 1 >> 1              -> 0
    harness.expect_register(12, 0x0000000000000000ULL);
    // SRA x13, x1, x1  -> 1 >>> 1             -> 0
    harness.expect_register(13, 0x0000000000000000ULL);
    // SLL x14, x2, x3  -> (-1) << (2047&63=63) -> 0x8000000000000000
    harness.expect_register(14, 0x8000000000000000ULL);
    // SRL x15, x2, x3  -> u(-1) >> 63         -> 1
    harness.expect_register(15, 0x0000000000000001ULL);
    // SRA x16, x2, x3  -> s(-1) >>> 63        -> -1
    harness.expect_register(16, 0xffffffffffffffffULL);
    // SLL x17, x4, x4  -> 63 << 63            -> 0x8000000000000000
    harness.expect_register(17, 0x8000000000000000ULL);
    // SRL x18, x4, x4  -> 63 >> 63            -> 0
    harness.expect_register(18, 0x0000000000000000ULL);
    // SRA x19, x4, x4  -> 63 >>> 63           -> 0
    harness.expect_register(19, 0x0000000000000000ULL);
    // SLL x20, x2, x1  -> (-1) << 1           -> -2
    harness.expect_register(20, 0xfffffffffffffffeULL);
    // SRL x21, x2, x1  -> u(-1) >> 1          -> 0x7FFFFFFFFFFFFFFF
    harness.expect_register(21, 0x7fffffffffffffffULL);

    harness.run();

    return 0;
}
