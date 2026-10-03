# Empty L1D inclusive probe endpoint

Run `make -C sim/cocotb/dcache SIM=verilator TEST_SEED=1` on Alan.
The test checks reset, back-to-back recall probe identities, and empty-line
acknowledgements. Normal load/store, DMA, dirty data, and DCache arrays are
not implemented by this L4 integration slice.
