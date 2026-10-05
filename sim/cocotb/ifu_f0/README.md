# F0 L5 RV64I contract

Run on Alan: `make -C sim/cocotb/ifu_f0 SIM=verilator TEST_SEED=1` (also 7,29).
Checks every IALIGN=32 position, illegal short encodings including zero, fetch
access faults, PC/slot/FTQ identity, reset/kill/sync and backpressure. The L1
short-prefix skip expectation is replaced by a precise illegal trap assertion.
No RVC execution or cross-region assembly.
