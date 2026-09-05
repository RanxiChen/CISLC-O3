# core_three_alu

Core-level three-ALU smoke simulation.

This test drives `o3_core` with three independent RV64I integer ALU
instructions in the first fetch group:

- `0x0`: `addi x1, x0, 1` (`0x00100093`)
- `0x4`: `ori x2, x0, 5` (`0x00506113`)
- `0x8`: `xori x3, x0, 7` (`0x00704193`)
- other instruction addresses: `0xffffffff`

The fourth lane is intentionally non-integer/invalid for the current backend
subset. The test only waits for the first three independent ALU instructions,
so it can observe the current 3-wide integer execute and 3-wide retire path
without introducing inter-group dependency behavior.

Commands:

```bash
make test
make run
```

The same directory also contains a directed same-bundle Rename dependency test:

```bash
make test TEST=rename_bundle_dependencies
```

It places `addi x1,5; add x2,x1,x1; sub x3,x2,x1; xor x1,x3,x2` in one
four-lane bundle.  The test checks same-bundle RAW forwarding, the WAW chain
for `x1`, next-cycle wakeup, in-order ROB retirement, and final values
`5, 10, 5, 15`.

Default logging defines `O3_SIM` and `ENABLE_RETIRE_INFO`, but not
`O3_SIM_SINGLE_INST_TRACE`. The backend therefore prints the normal per-cycle
stage block. Look for one cycle with:

```text
ISSUE alu0 id=0x0 ... op=ADD
ISSUE alu1 id=0x1 ... op=OR
ISSUE alu2 id=0x2 ... op=XOR
```

followed by matching `EXECUTE`, `WRITEBACK`, and one retire observation with
ports 0, 1, and 2 valid for PCs `0x0`, `0x4`, and `0x8`.
