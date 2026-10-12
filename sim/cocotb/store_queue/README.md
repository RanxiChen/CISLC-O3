# Store queue dependency contract

Run on Alan: `make -C sim/cocotb/store_queue SIM=verilator`.

The directed test checks unknown-address older stores, non-overlapping stores,
the youngest full-cover store, partial overlap, and a younger store ignored by
an older load. It exercises the existing single-store forwarding contract.
It does not cover DCache traffic or a speculative memory violation replay.

2026-10-11 deferred extension: 40 batches of six real STA capture/replay transactions, reverse publication, TLB/A-D wake, dual independent ready, payload/identity checking, same-cycle branch kill, committed drain and physical-slot wrap. Added for the balanced oldest-two replay selector; not executed during synthesis-only refactor.
