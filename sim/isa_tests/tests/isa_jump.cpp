#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/jump.json");
    // 4 instructions retire after squashes:
    // jal (PC=0), auipc (PC=12), jalr (PC=16), addi (PC=24)
    // addi at PC=4,8 squashed by JAL redirect
    // addi at PC=20 squashed by JALR redirect (target=24 ≠ fallthrough=20)
    harness.expect_retired_count(4);

    // x2 = 0x42 (from addi x2, x0, 0x42 at PC=24)
    harness.expect_register(2,  0x0000000000000042ULL);
    // x4 = 20 (PC+4 from jalr at PC=16: 16 + 4 = 20)
    harness.expect_register(4,  0x0000000000000014ULL);
    // x10 = 12 (from auipc x10, 0 at PC=12)
    harness.expect_register(10, 0x000000000000000cULL);

    harness.run();

    return 0;
}
