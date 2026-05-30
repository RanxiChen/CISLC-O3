#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/utype.json");
    harness.expect_retired_count(8);

    // LUI  x1, 0x12345 → x1 = 0x12345000 (PC=0)
    harness.expect_register(1, 0x0000000012345000ULL);
    // AUIPC x2, 0x1     → x2 = PC(4) + 0x1000 = 0x1004
    harness.expect_register(2, 0x0000000000001004ULL);
    // AUIPC x3, 0x0     → x3 = PC(8) + 0x0 = 0x0008
    harness.expect_register(3, 0x0000000000000008ULL);
    // AUIPC x4, 0x100   → x4 = PC(12) + 0x100000 = 0x0010000C
    harness.expect_register(4, 0x000000000010000CULL);
    // AUIPC x5, 0x0     → x5 = PC(16) + 0x0 = 0x0010
    harness.expect_register(5, 0x0000000000000010ULL);
    // AUIPC x6, 0x4     → x6 = PC(20) + 0x4000 = 0x4014
    harness.expect_register(6, 0x0000000000004014ULL);
    // AUIPC x7, 0x0     → x7 = PC(24) + 0x0 = 0x0018
    harness.expect_register(7, 0x0000000000000018ULL);
    // AUIPC x8, 0x4     → x8 = PC(28) + 0x4000 = 0x401C
    harness.expect_register(8, 0x000000000000401CULL);

    harness.run();

    return 0;
}
