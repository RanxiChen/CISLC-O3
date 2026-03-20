#include <stdio.h>
#include <stdlib.h>
#include "Vfrontend_testharness.h"
#include "verilated.h"

#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // 实例化 DUT
    Vfrontend_testharness* dut = new Vfrontend_testharness;

#if VM_TRACE
    // 初始化波形追踪
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("frontend_testharness.vcd");
#endif

    // 初始化信号
    dut->clk_i = 0;
    dut->rst_i = 1;

    // 复位几个周期
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

    // 释放复位
    dut->rst_i = 0;

    // 主仿真循环
    vluint64_t main_time = 20;
    while (!Verilated::gotFinish()) {
        // 时钟下降沿
        dut->clk_i = 0;
        dut->eval();
#if VM_TRACE
        tfp->dump(main_time);
#endif
        main_time++;

        // 时钟上升沿
        dut->clk_i = 1;
        dut->eval();
#if VM_TRACE
        tfp->dump(main_time);
#endif
        main_time++;

        // 检查完成信号
        if (dut->done_o) {
            printf("Simulation done!\n");
            break;
        }

        // 可选：限制最大仿真周期数
        if (main_time > 100000) {
            printf("Max simulation time reached\n");
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
