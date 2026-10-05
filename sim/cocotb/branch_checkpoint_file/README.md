# branch_checkpoint_file L3 contract

Run on Alan: `make -C sim/cocotb/branch_checkpoint_file SIM=verilator TEST_SEED=1`.

Wrapper preserves all DUT ports and only exports configuration and state observations. Tests cover reset, directed four-wide/C/M boundaries and seeded DUT transactions. Target t_* ports remain outside the L3 contract. No full ISA, PPA or FPGA claim.
