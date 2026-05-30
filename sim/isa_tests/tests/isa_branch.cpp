#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/branch.json");
    harness.expect_retired_count(54);

    // ── Test strategy ──
    // Each branch instruction is tested twice: once where the condition
    // is TRUE (branch should be TAKEN) and once where it is FALSE
    // (branch should NOT be taken).  For TAKEN tests, the fall-through
    // instruction is skipped and only the target path executes, writing
    // value 1 into the result register.  For NOT-TAKEN tests, the
    // fall-through path executes (writing value 2) and the target path
    // also executes sequentially (writing to scratch x15).

    // ── BEQ tests ──
    // BEQ taken: x1=5, x2=5 → equal → branch taken, x3=1
    harness.expect_register(3,  0x0000000000000001ULL);
    // BEQ not-taken: x1=5, x2=3 → not equal → fall-through, x4=2
    harness.expect_register(4,  0x0000000000000002ULL);

    // ── BNE tests ──
    // BNE taken: x1=5, x2=3 → not equal → branch taken, x5=1
    harness.expect_register(5,  0x0000000000000001ULL);
    // BNE not-taken: x1=5, x2=5 → equal → fall-through, x6=2
    harness.expect_register(6,  0x0000000000000002ULL);

    // ── BLT tests (signed less-than) ──
    // BLT taken: x1=-5, x2=3 → signed(-5 < 3) → branch taken, x7=1
    harness.expect_register(7,  0x0000000000000001ULL);
    // BLT not-taken: x1=5, x2=-3 → signed(5 >= -3) → fall-through, x8=2
    harness.expect_register(8,  0x0000000000000002ULL);

    // ── BGE tests (signed greater-or-equal) ──
    // BGE taken: x1=5, x2=-3 → signed(5 >= -3) → branch taken, x9=1
    harness.expect_register(9,  0x0000000000000001ULL);
    // BGE not-taken: x1=-5, x2=3 → signed(-5 < 3) → fall-through, x10=2
    harness.expect_register(10, 0x0000000000000002ULL);

    // ── BLTU tests (unsigned less-than) ──
    // BLTU taken: x1=3, x2=-5 → u(3) < u(-5)=0xFFFF...FFFB → branch taken, x11=1
    harness.expect_register(11, 0x0000000000000001ULL);
    // BLTU not-taken: x1=-5, x2=3 → u(-5)=huge >= 3 → fall-through, x12=2
    harness.expect_register(12, 0x0000000000000002ULL);

    // ── BGEU tests (unsigned greater-or-equal) ──
    // BGEU taken: x1=-5, x2=3 → u(-5)=huge >= 3 → branch taken, x13=1
    harness.expect_register(13, 0x0000000000000001ULL);
    // BGEU not-taken: x1=3, x2=-5 → u(3) < u(-5)=huge → fall-through, x14=2
    harness.expect_register(14, 0x0000000000000002ULL);

    harness.run();

    return 0;
}
