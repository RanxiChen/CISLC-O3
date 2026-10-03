# L1 whole-core retirement simulation

This harness builds the current `o3_core` from the single RTL file list,
`rtl/rtl.f`. The C++ loader accepts little-endian ELF64 `PT_LOAD` segments
and word-oriented hex. Hex words load at `0x10000000` by default; `@ADDRESS`
changes the byte address. While reset is asserted, the harness writes image
bytes into ITCM/DTCM through their initialization ports and into the
SystemVerilog AXI backing RAM at `0x80000000`–`0x800fffff`.

Run the L1 gate:

```sh
make -C sim/o3 build
make -C sim/o3 run-smoke
```

`run-smoke` loads `tests/smoke.hex`, retires four independent `addi`
instructions, writes `sim/o3/tandem.jsonl`, and compares its architectural
fields with `tests/smoke.expected.json`. The required PCs are
`0x10000000/04/08/0c`; writes to `x1..x4` must be `1/2/3/4`.
The runner fails on timeout or a core fatal signal. Set `--max-cycles` when
invoking the binary directly to adjust the timeout.

Each JSONL retirement record keeps the v1 schema used by the existing
`check_trace.py` and `*.expected.json`: `cycle`, `order`, `slot`,
`instruction_id`, `rob_idx`, `pc`, `instruction`, `rd`, `rd_write`,
and `rd_wdata`. Only actual ROB retirements are recorded.

The AXI4 slave is written in SystemVerilog in `o3_tandem_top.sv`. It has
one outstanding read and one outstanding write, byte strobes, bursts,
parameterized read latency, and valid/ready backpressure. L1 smoke should
hit ITCM and therefore does not validate the L2/AXI miss path.

A passing smoke run proves only that the current straight-line ITCM
instruction path reaches ordered retirement for these four instructions.
It does not prove branch recovery, RVC, exceptions, DTCM or external memory,
cache misses, or general ISA compliance. The old
`tests/rv64i_instructions.hex`, `tests/unified_memory.hex`, expected JSON,
and `check_trace.py` remain available for later L2/L3 migration; their
Makefile targets are not L1 acceptance gates.
