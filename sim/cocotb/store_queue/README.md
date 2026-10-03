# Store queue dependency contract

Run on Alan: `make -C sim/cocotb/store_queue SIM=verilator`.

The directed test checks unknown-address older stores, non-overlapping stores,
the youngest full-cover store, partial overlap, and a younger store ignored by
an older load. It exercises the existing single-store forwarding contract.
It does not cover DCache traffic or a speculative memory violation replay.
