# F0 L1 contract

Run on Alan: `make -C sim/cocotb/ifu_f0 SIM=verilator TEST_SEED=1`.
Checks full 32-bit instruction starts, original PC/slot/FTQ identity, output
mask, reset/kill/sync, and backpressure. RVC and cross-region assembly wait
until L2.
