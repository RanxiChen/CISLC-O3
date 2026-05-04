# core_single_inst

Core-level single-instruction simulation entry.

The current `single_addi` test drives `o3_core` with a tiny instruction memory:

- `0x0`: `addi x1, x0, 1` (`0x00100093`)
- all other instruction addresses: `0xffffffff`

The harness follows the frontend refill style: it watches `refill_req_valid_o`,
returns a 64-byte line after a fixed latency, and exits when the traced backend
instruction retires. A fixed large internal cycle limit remains as a deadlock
guard.

The default build also defines `ENABLE_RETIRE_INFO`, exposing the core-level
`retire_info_o` port. The C++ harness samples that combinational retire record
before the clock edge that commits the ROB head, then asserts the architectural
effect of the single `addi`:

- retire port 0 is valid
- `pc == 0`
- `instruction == 0x00100093`
- `rd == x1`
- `rd_write_en == 1`
- `rd_wdata == 1`
- `rob_idx == 0`
- `instruction_id == 0`

Commands:

```bash
make test
make run
```

Default logging defines `O3_SIM`, `O3_SIM_SINGLE_INST_TRACE`, and
`ENABLE_RETIRE_INFO`. In this mode the backend suppresses the normal per-cycle
text block and prints only the first valid instruction that enters backend, from
`ACCEPT` through `RETIRE`; the harness also prints the sampled retire info
record before the traced instruction retires.

Expected log shape:

```text
[SINGLE][cycle=12] ACCEPT pc=0x0 inst=0x00100093 id=0x0
[SINGLE][cycle=13] DECODE pc=0x0 inst=0x00100093 id=0x0
[SINGLE][cycle=14] RENAME id=0x0 rd=x1 old=p1 new=p32 rob=0
[SINGLE][cycle=15] ISSUE id=0x0 alu=0 src1=p0 src2=imm(0x1) dst=p32 rob=0 op=ADD
[SINGLE][cycle=16] REGREAD id=0x0 alu=0 src1=0x0 src2=0x1
[SINGLE][cycle=17] EXECUTE id=0x0 alu=0 op=ADD result=0x1
[SINGLE][cycle=18] WRITEBACK id=0x0 dst=p32 data=0x1 rob=0
[core_single_inst][cycle=20] retire_info port=0 pc=0x0 inst=0x00100093 rd=x1 rd_wen=1 rd_wdata=0x1 rob=0 id=0x0
[SINGLE][cycle=19] RETIRE id=0x0 rob=0 old=p1
```

`KANATA=1` is still accepted by the Makefile for manual experiments, but the
default single-instruction smoke path does not use it.
