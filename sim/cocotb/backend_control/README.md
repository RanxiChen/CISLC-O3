# L3 backend C control overlap

Run on Alan: `make -C sim/cocotb/backend_control SIM=verilator TEST_SEED=1`.
120 bundles of four independent architectural instructions mix correct BNE and
JAL +4 with independent/dependent ALU instructions. A fixed seed inserts fetch
pauses; a bundle stays stable until the real backend accepts it. The independent
model supplies retirement identities and values before simulation. Passive
observers require actual C cycles coinciding with rename, dispatch, PRF read and
retirement, including a cycle with all four. FTQ notifications equal actual
retirement. This wrapper contains the real backend; it does not force state.
Cache/refill and wrong-path recovery remain in the whole-core backend suite.
