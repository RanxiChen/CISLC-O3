# CISLC-O3 Tandem trace simulation

This is the new whole-core Verilator simulation entry. It drives the real
frontend and backend through `o3_core`, loads a unified software memory from
ELF64 or a word-oriented hex image, initializes local ITCM/DTCM windows, services
out-of-range instruction/data requests, and writes retirement records to JSONL.

The current step is a Tandem **trace producer only**. It does not launch Spike,
compare architectural state with Spike, or emit Kanata events.

Run:

```bash
cd sim/o3
make test
```

The default smoke image retires four independent RV64I instructions and writes
`tandem.jsonl`. The same `make test` invocation also runs a 14-retirement
directed program covering `LUI/AUIPC`, all nine RV64 word ALU instructions,
taken `BEQ/JAL`, wrong-path removal, and JAL link writeback. Its stable fields
are checked against `tests/rv64i_instructions.expected.json`. A third directed
program starts from the 64 KiB ITCM at `0x10000000`, reads initialized data from
the 256 KiB DTCM at `0x11000000`, and exercises external software-memory Load
and Store at `0x12000000`. Exact route counters and retirement values are checked.

The simulator also supports a self-checking software-memory mailbox through
`--tohost-address ADDRESS`. A nonzero 64-bit value at that address stops the run;
`1` returns success and any other value returns failure. The ACT4 integration in
`verification/act4` uses this mode to run all generated unprivileged RV64I-I
ELFs through the whole core. See `verification/act4/README.md` for its pinned
toolchain, address map, and commands.

The loader accepts little-endian ELF64 `PT_LOAD` segments and uses the ELF entry
point unless `--reset-pc` is given. Legacy hex remains supported; words are
little-endian and `@0xADDRESS` changes the absolute byte load address. All image
bytes remain in one sparse C++ backing memory. Bytes in ITCM/DTCM ranges are also
written into RTL through initialization ports while reset is asserted.

Every `retire` record is architectural and ordered: `order=0`
is the oldest retired instruction. A cycle may contain up to four consecutive
records in increasing slot order.

The stable v1 fields are:

- `cycle`, `order`, and retirement `slot`
- internal diagnostic `instruction_id` and `rob_idx`
- `pc` and raw `instruction`
- `rd`, `rd_write`, and `rd_wdata`

The retirement trace is not yet sufficient for full ISA differential testing.
Memory addresses/effects are not yet present in the retirement record. Exceptions,
CSRs, privilege state, and architectural next-PC will be added with their RTL
retirement contracts.
