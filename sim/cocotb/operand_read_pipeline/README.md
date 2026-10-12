# Overlapped operand scheduling

Four-slot A0 metadata reservations, registered circular-age priority A1, granted address
descriptors A2 and independent three-slot operand capture per FU. Full instruction
metadata remains in A0 until actual PRF capture; only narrow identities/addresses
pass through the scheduler. Capture payloads remain stationary while order indices move. Denied candidates retain
their reservation and retry, allowing one new priority packet every cycle. Allocation
reserves capture capacity including in-flight grants, using a combinational prefix tree.
FU delivery readiness never holds shared PRF addresses. The independent model uses
Python age sorting and sequential atomic budgeting, checks all owners, addresses,
captured INT/FP/store operands, cancellation and fixed-seed random backpressure.
Continuous three-source INT/BR and single-FMA bursts require one intake/read/delivery
per lane per cycle after fill; a blocked DIV must leave other lanes progressing.
The added stages contain no serial state machine. Test parameters derive from the DUT.

Function execution is deferred by the user until backend refactoring completes.
Before compilation or simulation, reread the shared `simulation-host.md`, preflight
cloud_chen first and Alan on failure. On the selected host:

```
make -C sim/cocotb/operand_read_pipeline SIM=verilator TEST_SEED=1
```

This module test does not prove whole-core execution, LSU reservation or timing closure.
