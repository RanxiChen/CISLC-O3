#include <cstdio>
#include "Vbackend_testharness.h"
#include "verilated.h"

#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Vbackend_testharness* dut = new Vbackend_testharness;

#if VM_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("backend_testharness.vcd");
#endif

    dut->clk_i = 0;
    dut->rst_i = 1;

    for (int i = 0; i < 10; i++) {
        dut->clk_i = 0;
        dut->eval();
#if VM_TRACE
        tfp->dump(2 * i);
#endif

        dut->clk_i = 1;
        dut->eval();
#if VM_TRACE
        tfp->dump(2 * i + 1);
#endif
    }

    dut->rst_i = 0;

    vluint64_t main_time = 20;
    while (!Verilated::gotFinish()) {
        dut->clk_i = 0;
        dut->eval();
#if VM_TRACE
        tfp->dump(main_time);
#endif
        main_time++;

        dut->clk_i = 1;
        dut->eval();
#if VM_TRACE
        tfp->dump(main_time);
#endif
        main_time++;

        if (dut->done_o) {
            std::printf("Backend simulation done.\n");
            break;
        }

        if (main_time > 100000) {
            std::printf("Backend simulation reached max time.\n");
            break;
        }
    }

#if VM_TRACE
    tfp->close();
    delete tfp;
#endif

    delete dut;
    return 0;
}
