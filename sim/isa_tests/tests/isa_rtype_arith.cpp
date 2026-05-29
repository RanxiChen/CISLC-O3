#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/rtype_arith_logical.json");
    harness.expect_retired_count(26);

    // Setup: x1=63, x2=-1, x3=2047, x4=-2048
    // R-type results:
    harness.expect_register(5,  0x000000000000003eULL);  // ADD  x5,  x1, x2  -> 62
    harness.expect_register(6,  0x0000000000000040ULL);  // SUB  x6,  x1, x2  -> 64
    harness.expect_register(7,  0xffffffffffffffc0ULL);  // XOR  x7,  x1, x2  -> -64
    harness.expect_register(8,  0xffffffffffffffffULL);  // OR   x8,  x1, x2  -> -1
    harness.expect_register(9,  0x000000000000003fULL);  // AND  x9,  x1, x2  -> 63
    harness.expect_register(10, 0x000000000000083eULL);  // ADD  x10, x1, x3  -> 2110
    harness.expect_register(11, 0xfffffffffffff840ULL);  // SUB  x11, x1, x3  -> -1984
    harness.expect_register(12, 0x00000000000007c0ULL);  // XOR  x12, x1, x3  -> 1984
    harness.expect_register(13, 0x00000000000007ffULL);  // OR   x13, x1, x3  -> 2047
    harness.expect_register(14, 0x000000000000003fULL);  // AND  x14, x1, x3  -> 63
    harness.expect_register(15, 0x00000000000007feULL);  // ADD  x15, x2, x3  -> 2046
    harness.expect_register(16, 0xfffffffffffff800ULL);  // SUB  x16, x2, x3  -> -2048
    harness.expect_register(17, 0xfffffffffffff800ULL);  // XOR  x17, x2, x3  -> -2048
    harness.expect_register(18, 0xffffffffffffffffULL);  // OR   x18, x2, x3  -> -1
    harness.expect_register(19, 0x00000000000007ffULL);  // AND  x19, x2, x3  -> 2047
    harness.expect_register(20, 0xffffffffffffffffULL);  // ADD  x20, x3, x4  -> -1
    harness.expect_register(21, 0x0000000000000fffULL);  // SUB  x21, x3, x4  -> 4095
    harness.expect_register(22, 0xffffffffffffffffULL);  // XOR  x22, x3, x4  -> -1 (2047 ^ -2048 = -1)
    harness.expect_register(23, 0xffffffffffffffffULL);  // OR   x23, x3, x4  -> -1
    harness.expect_register(24, 0x0000000000000000ULL);  // AND  x24, x3, x4  -> 0
    harness.expect_register(25, 0xfffffffffffff001ULL);  // SUB  x25, x4, x3  -> -4095
    harness.expect_register(26, 0xfffffffffffff7c1ULL);  // SUB  x26, x4, x1  -> -2111

    harness.run();

    return 0;
}
