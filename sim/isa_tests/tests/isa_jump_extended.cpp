#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/jump_extended.json");

    // Retired instruction count:
    // Scenario 1:  PC=0 (JAL), PC=12 (ADDI)                              = 2
    // Scenario 2:  PC=16 (JAL), PC=40 (ADDI)                             = 2
    // Gap:         PC=44 (NOP)                                           = 1
    // Scenario 3:  PC=48 (AUIPC), PC=52 (ADDI), PC=56 (JALR), PC=60 (ADDI) = 4
    // Scenario 4:  PC=64 (AUIPC), PC=68 (ADDI), PC=72 (JALR), PC=76 (ADDI) = 4
    // Scenario 5:  PC=80 (AUIPC), PC=84 (JALR), PC=112 (ADDI)           = 3
    // Total = 16
    harness.expect_retired_count(16);

    // Scenario 1: JAL link writeback
    harness.expect_register(1,  0x4);   // x1 = PC+4 = 4
    harness.expect_register(4,  42);    // x4 = 42

    // Scenario 2: JAL large positive offset (24 bytes, skip 6 instrs)
    harness.expect_register(5,  99);    // x5 = 99

    // Scenario 3: JALR offset=0 indirect jump
    harness.expect_register(12, 0x3C);  // x12 = AUIPC(0x30) + ADDI(12) = 0x3C (target PC=60)
    harness.expect_register(3,  0x3C);  // x3  = PC+4 = 56+4 = 60 = 0x3C
    harness.expect_register(6,  77);    // x6  = 77

    // Scenario 4: JALR target == fallthrough (regression test)
    harness.expect_register(13, 0x4C);  // x13 = AUIPC(0x40) + ADDI(12) = 0x4C (target PC=76)
    harness.expect_register(7,  0x4C);  // x7  = PC+4 = 72+4 = 76 = 0x4C
    harness.expect_register(8,  88);    // x8  = 88 (must NOT be squashed)

    // Scenario 5: JALR large positive offset
    harness.expect_register(14, 0x50);  // x14 = AUIPC at PC=80, no ADDI overwrites it
    harness.expect_register(9,  0x58);  // x9  = PC+4 = 84+4 = 88 = 0x58
    harness.expect_register(11, 99);    // x11 = 99

    harness.run();
    return 0;
}
