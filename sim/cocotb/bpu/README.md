# BPU L1 contract

Run on Alan: `make -C sim/cocotb/bpu SIM=verilator TEST_SEED=1`.
The directed and seeded tests cover sequential 16B PC advance only on FTQ
allocation, backpressure/hold, identity-tagged completion, reset, and constant
history/RAS snapshots. BTB/TAGE, redirects, and branch training are L2 work.
