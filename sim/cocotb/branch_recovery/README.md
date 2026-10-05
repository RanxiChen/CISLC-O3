# Branch recovery contract test

Run on Alan:

```sh
make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1
```

The test covers the L2 execution-source closure only: BRU metadata and one-shot
resolution, R0/R1/R2 redirect recovery, execution-redirect fetch-buffer clear,
and killing a younger ALU RegRead entry while an older result is backpressured.
It also checks D24 replacement of a busy younger execution recovery by an
older request: across FTQ regions, within one region, and across ring wrap;
old completion cannot release a newly replaced region, and younger requests
cannot replace an older one. The integrated twelve-instruction loop is run by
`make -C sim/o3 run-spike-branch-loop`.
It does not cover JALR/RVC, predecode/slow/system redirect arbitration, or real
BTB/TAGE/RAS prediction.
