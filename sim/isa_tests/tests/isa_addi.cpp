#include "isa_harness.h"

int main(int argc, char** argv) {
    IsaTestHarness harness(argc, argv);

    harness.load_json("programs/addi_chain.json");
    harness.expect_retired_count(3);
    harness.expect_register(1, 1);   // addi x1, x0, 1  -> x1 = 1
    harness.expect_register(2, 5);   // ori  x2, x0, 5  -> x2 = 5
    harness.expect_register(3, 7);   // xori x3, x0, 7  -> x3 = 7

    harness.run();

    return 0;
}
