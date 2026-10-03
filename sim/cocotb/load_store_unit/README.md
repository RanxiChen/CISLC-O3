# LSU dependency replay

Run on Alan: `make -C sim/cocotb/load_store_unit SIM=verilator`.

The directed test checks that an SQ-blocked load leaves the execution stage,
the one-slot replay record holds its identity, a store can execute in the
meantime, an SQ-change event wakes recheck, and forwarding produces the
original load result. It also checks that a wrong-path replay is discarded
before an SQ wake can create a result. It does not test translation or precise
exceptions.
