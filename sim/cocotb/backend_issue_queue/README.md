# Memory issue selection

Run on Alan: `make -C sim/cocotb/backend_issue_queue SIM=verilator`.

This test checks that a ready younger load may bypass an unready older store,
that the LSU replay-slot gate blocks new loads, and that the older store can
still issue after its operand wakes. It does not test LSU dependency replay or
the complete backend; those have separate gates.
