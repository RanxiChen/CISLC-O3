# Branch recovery contract test

Run on Alan:

```sh
make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1
```

The test covers the L2 execution-source closure only: BRU metadata and one-shot
resolution, R0/R1/R2 redirect recovery, execution-redirect fetch-buffer clear,
and killing a younger ALU RegRead entry while an older result is backpressured.
It does not cover JALR/RVC, predecode/slow/system redirect arbitration, or real
BTB/TAGE/RAS prediction.
