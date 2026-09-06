# CISLC-O3 Tandem trace simulation

This is the new whole-core Verilator simulation entry. It drives the real
frontend and backend through `o3_core`, services ICache refill requests from a
word-per-line instruction image, and writes retirement records to JSONL.

The current step is a Tandem **trace producer only**. It does not launch Spike,
compare architectural state, initialize Data SRAM, or emit Kanata events.

Run:

```bash
cd sim/o3
make test
```

The default smoke image retires four independent RV64I instructions and writes
`tandem.jsonl`. The same `make test` invocation also runs a 14-retirement
directed program covering `LUI/AUIPC`, all nine RV64 word ALU instructions,
taken `BEQ/JAL`, wrong-path removal, and JAL link writeback. Its stable fields
are checked against `tests/rv64i_instructions.expected.json`.

Every `retire` record is architectural and ordered: `order=0`
is the oldest retired instruction. A cycle may contain up to four consecutive
records in increasing slot order.

The stable v1 fields are:

- `cycle`, `order`, and retirement `slot`
- internal diagnostic `instruction_id` and `rob_idx`
- `pc` and raw `instruction`
- `rd`, `rd_write`, and `rd_wdata`

This is intentionally not yet sufficient for full ISA differential testing.
Memory effects, exceptions, CSRs, privilege state, and architectural next-PC
will be added when their RTL retirement contracts are implemented.
