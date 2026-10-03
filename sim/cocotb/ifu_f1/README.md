# F1 L1 contract

Run on Alan: `make -C sim/cocotb/ifu_f1 SIM=verilator TEST_SEED=1`.
Checks packed valid lanes, PC/instruction/FTQ identity/slot, last-in-region,
prediction metadata from the FTQ brief, backpressure, reset/kill, and a
permanently invalid predecode correction. Branch correction is L2 work.
