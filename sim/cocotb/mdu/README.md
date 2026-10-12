# MDU directed verification

Before compilation/simulation reread `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`,
validate cloud_chen first, and use Alan if cloud_chen is unavailable.
Run `make -C sim/cocotb/mdu`; DIV uses `DIV=1`.

The existing arithmetic, identity, cancellation, credit, reset and backpressure
checks remain. Under the user-authorized 2026-10-11 B33 update, the next-head wake
assertion applies to an empty FIFO; FIFO tails can notify scheduling as well.
The new test explicitly checks exactly one notice per destination behind a stalled
head, simultaneous notices for both fused MUL destinations, unchanged live-head
bypass, and eventual exact ROB/preg/value delivery in order.

2026-10-11: fixture migrated and tail-notice test written, not compiled/run.
These tests do not prove backend buffer/read arbitration or whole-core behavior.
