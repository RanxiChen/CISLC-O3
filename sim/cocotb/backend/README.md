# Backend L1 integration contract

Run: `make -C sim/cocotb/backend SIM=verilator TEST_SEED=1`.

This cocotb test instantiates the existing whole-core observer from sim/o3,
preloads four ITCM ADDI instructions, and checks that they pass through
decode, rename, the live integer issue queue, ALUs and ROB in program order.
It specifically guards the backend issue-queue connection. The authoritative
L1 gate remains `make -C sim/o3 run-smoke` on Alan.
