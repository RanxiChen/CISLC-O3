# One read / one write SRAM

Run: `make -C sim/cocotb/o3_sram_1r1w SIM=verilator TEST_SEED=1`.

Checks synchronous read latency, held read output, and independent-address
read/write on the same edge. Same-address read/write is forbidden by assertion
and excluded by ICache arbitration. This test does not prove FPGA block RAM
inference or timing closure.
