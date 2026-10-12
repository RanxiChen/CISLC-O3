# FU issue buffer / separate RegRead contract

This suite uses the actual `fu_issue_buffer`, `mdu_regread`, `fp_regread` and
`mem_regread` modules. It checks no fall-through, read/data denial, stable operands
through FU backpressure, simultaneous replacement, identity/three FP operands,
MEM one-cycle advance, correct-resolution mask clearing, selective kill, flush,
reset, and 400 fixed-seed randomized cycles against a transaction model.

The test wrapper models read permission and actual data availability independently.
Enqueue stimulus follows IQ's contract of filtering killed incoming instructions.
It does not prove backend PRF arbitration, global wake/bypass comparison, arithmetic,
LSU reservations, or whole-core recovery. Existing integration tests must cover those.

Before compilation/simulation reread `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`,
validate cloud_chen first, and use Alan if cloud_chen is unavailable. Then on that host:

```
make -C sim/cocotb/fu_issue_pipeline SIM=verilator TEST_SEED=1
```

2026-10-11: written but not compiled/run; user deferred functional validation until
backend refactor completion. Backend-only Vivado synthesis is a separate evidence scope.
