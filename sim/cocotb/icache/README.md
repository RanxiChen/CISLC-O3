# ICache contract test

Run: `make -C sim/cocotb/icache SIM=verilator TEST_SEED=1`.

The tests cover S0–S3 identity/data alignment, whole-line bank placement,
four-beat L2 refill, hit under miss, same-bank
installation backpressure, other-bank progress, same-bank consecutive hits,
refill errors, full invalidation, inclusive line recall, and fixed-seed hit traffic.
They exercise the physical-address subset. ITLB, PMP/PMA, prefetch,
and multiple MSHRs are not yet implemented or tested. Local cocotb
results are provisional until the same command runs on Alan.
