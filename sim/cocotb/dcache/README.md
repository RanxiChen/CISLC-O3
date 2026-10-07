# DCache L8a M2 (X11)

Run only on the host chosen by rereading the shared simulation-host configuration
and preflighting its environment. `make MSHRS=4` executes the three migrated
existing cases, 23 L8a cases and supplemental PS/probe coverage.
`make MSHRS=1` runs every applicable case plus a single-MSHR full/free case.
The three cases that require four concurrent MSHRs run unchanged at MSHRS=4.
See `doc/tasks/O3-T09-report.md` for results.

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
same-set line. Approved X11 (eb1432c) requires WB_LINE and wb_free.
The test verifies PutAck emits wb_free without a fabricated mshr_free, then
reissues the request and checks replacement completion against golden memory.
The original failing evidence and reason-only diagnostic remain in the report.
