# DCache L8a M2 (blocked, no layer pass)

Run only on the host chosen by rereading the shared simulation-host configuration
and preflighting its environment. `make MSHRS=4` executes the three migrated
existing cases and 23 L8a cases. The full layer currently fails
`wb_capacity_full_wait_contract`; see `doc/tasks/O3-T09-report.md`.

Focused reproduction:

```sh
make MSHRS=4 COCOTB_TESTCASE=wb_capacity_full_wait_contract
```

The original byte patterns and unaligned store value are preserved. The empty
probe test keeps 24 iterations. The capacity test preserves the original lines
and adds lines to exceed the new eight-way capacity. Whole-line grants and
install-driven CPU replay replace the removed four-beat and recall interfaces.
No former test was removed. `dcache_model.py` is retained for historical context.

`l8a_agents.py` contains an independent behavioral L2 with per-ID grants, clean
and dirty PutAck, Inv/Down probes, refill errors and a separate golden memory.
CPU requests reserve an IS slot and arrive at S0 two cycles later; translation
payload follows at S1. Internal sources use their actual handshakes. Load MISS
waits for install before replay. Monitors never modify DUT state.

`wb_capacity_full_wait_contract` fills both writeback slots while withholding
PutAck, waits for every associated MSHR to complete, then requests another
same-set line. Frozen spec 5.4 requires MSHR_FULL, whereas current RTL returns
WB_LINE. A reason-only RTL correction reaches the next check and fails because
PutAck emits wb_free without mshr_free, leaving the spec 6.1 waiter asleep.
The reason-only diagnostic change was not retained in production RTL.
