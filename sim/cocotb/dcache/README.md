# DCache word-bank data and inclusive probe endpoint

Run `make -C sim/cocotb/dcache SIM=verilator TEST_SEED=1` on Alan.
The tests check reset, back-to-back empty recall identities, L2 line refill,
resident hit while an unrelated miss waits, a same-line unaligned store across
two banks, dirty recall handoff, and miss after recall. Dirty victim writeback,
DMA line protection, and whole-core retirement still need separate gates.
