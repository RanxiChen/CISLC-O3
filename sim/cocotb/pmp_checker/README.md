# L10 PMP/PMA tests

`make -C sim/cocotb/pmp_checker SIM=verilator TEST_SEED=1` on Alan.

Independent byte-interval model covers G=2 TOR/NAPOT, raw low bits, minimum 16B
regions, first-entry priority, partial overlap, M/L permissions, stalls/reset
and fixed-seed random addresses. PMA checks full 64-bit Bare addresses and bounds.
PMP CSR NA4 WARL, read masks, retained raw storage and locks are in `csr_file`.
No Sv39/PTW, synthesis or platform checks.
