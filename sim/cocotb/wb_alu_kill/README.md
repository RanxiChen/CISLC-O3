# Shared WB / ALU recovery contract

`make -C sim/cocotb/wb_alu_kill SIM=verilator TEST_SEED=1`

Two real ALU Result producers plus a ready/valid JAL-link producer compete for the real shared WB arbiter. Its two ports hold the older ALU0 result while younger RegRead is independently killed by M. Every tag is tested with seeded transaction delays; killed ROB4 never completes. No forced DUT state, CSR/trap, full ISA or timing claim.
