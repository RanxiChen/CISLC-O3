L10 Sv39 directed and TEST_SEED replayable sparse-page-table tests. Python model implements the architectural walk independently. Includes Bare/M, canonical VA, three-level/walk-cache shortcuts, superpages, malformed PTE/read errors, permissions, ASID/path-global/SFENCE scopes, nonblocking hits, kill, epoch, round-robin and randomized backpressure.

On Alan: `source /home/chen/miniforge3/bin/activate cislc-o3; make -C sim/cocotb/mmu -j8 SIM=verilator TEST_SEED=1`.

This harness models the PTW physical memory port; whole-core programs validate integration. No Spike, synthesis or FPGA evidence.

T08c additionally covers A CAS/retry/PMP write rejection, queue-head D rewalk/PTE replacement/permission failure, and epoch drain. `make -C sim/cocotb/mmu -f Makefile.pte -j8 SIM=verilator TEST_SEED=1` runs the real DCache PTE entry hit/miss/full compare/read fault and 80 seeded interleaved CAS/store/read checks. This is an L10 atomic-entry harness, not the deferred general memory suite.
