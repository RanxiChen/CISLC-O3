#include <cstdio>
#include <string>
#include "Vbackend_testharness_json.h"
#include "verilated.h"

#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

bool backend_stream_load_json(const char* path, std::string* error);

namespace {

void print_usage(const char* prog) {
    std::printf("Usage: %s [--input <path>]\n", prog);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    std::string input_path = "program.json";
    for (int i = 1; i < argc; i++) {
        const std::string arg = argv[i];
        if ((arg == "--input" || arg == "-i") && (i + 1 < argc)) {
            input_path = argv[++i];
        } else if (arg == "--help" || arg == "-h") {
            print_usage(argv[0]);
            return 0;
        } else {
            std::printf("Unknown argument: %s\n", arg.c_str());
            print_usage(argv[0]);
            return 1;
        }
    }

    std::string error;
    if (!backend_stream_load_json(input_path.c_str(), &error)) {
        std::printf("Failed to load JSON instruction stream: %s\n", error.c_str());
        return 1;
    }

    Vbackend_testharness_json* dut = new Vbackend_testharness_json;

#if VM_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("backend_testharness_json.vcd");
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
