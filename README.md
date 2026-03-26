# CISLC-O3

This repository hosts an out-of-order RV64G processor core written in SystemVerilog.

## Current Backend Parameters

The current backend is centered around [`backend.sv`](/home/chen/FUN/CISLC-O3/rtl/backend/backend.sv). These are the main backend-facing parameters already in use.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `MACHINE_WIDTH` | `1` | Number of frontend lanes accepted and renamed per cycle. Lane `0` is treated as the oldest instruction in a fetch group. |
| `NUM_PHYS_REGS` | `64` | Number of physical integer registers managed by rename and the physical register file. |
| `NUM_ARCH_REGS` | `32` | Number of architectural integer registers. |
| `NUM_ROB_ENTRIES` | `64` | Number of ROB entries available for rename allocation. |
| `DECODE_QUEUE_DEPTH` | `2` | Number of grouped decoded-uop entries buffered between decode and rename. |
| `INT_ISSUE_QUEUE_DEPTH` | `16` | Number of compressed integer issue queue entries buffered after rename. |
| `NUM_INT_ALUS` | `3` | Number of integer ALU pipelines. Each ALU has its own issue register, regread register, and execute result register. |

The current backend also instantiates a physical register file with these effective settings:

| Parameter | Current Value | Meaning |
| --- | --- | --- |
| `NUM_READ_PORTS` | `NUM_INT_ALUS * 2` | Two read ports per ALU, one for `src1`, one for `src2`. |
| `NUM_WRITE_PORTS` | `1` | Placeholder write-port configuration for the current stage. Writeback is not connected yet. |
| `NUM_ENTRIES` | `NUM_PHYS_REGS` | Physical register file depth. |
| `DATA_WIDTH` | `64` | Integer datapath width. |

## Current Backend Pipeline

The current integer backend path is split into these stages:

1. `Fetch/Decode`
   Accept a frontend fetch group, decode RV64I integer R/I arithmetic fields, and form grouped decoded uops.

2. `Decode Queue`
   Buffer one grouped decoded-uop bundle between decode and rename.

3. `Rename/ROB Alloc`
   Allocate new destination physical registers, read rename-map source physical registers, and allocate ROB entries.

4. `Integer Issue Queue`
   Insert renamed integer uops into a compressed queue.
   Existing queue entries are default-woken one cycle later.
   In the same cycle, the queue selects the oldest ready entries and assigns them to the lowest-numbered available ALUs.

5. `ALU Issue Register`
   Capture the selected uops for each ALU pipeline.
   At this point the pipeline still stores physical register IDs, not actual operand values.

6. `Register Read / Immediate Expand`
   Read the physical register file using the issue register contents.
   Expand the raw immediate into a 64-bit value.
   Build the real `src1/src2` operand values that will be consumed by the ALU.

7. `Execute`
   Run the integer ALU operation with the final operand values.

8. `Execute Result Register`
   Capture the ALU result together with `instruction_id`, `rob_idx`, and destination physical register metadata.

What is not implemented yet:

- Physical register writeback
- Real wakeup/broadcast network
- Commit / retirement
- Flush / rollback / recovery
- Non-integer issue/dispatch paths

## Repository Layout

- `rtl/backend/`
  Current backend RTL, including decode, rename, issue queue, physical register file, and integer/mul/div execute units.
- `rtl/common/`
  Shared type/package definitions such as `o3_pkg.sv`.
- `rtl/frontend/`
  Frontend-side RTL entry point.
- `tb/`
  Testharness top-level SystemVerilog wrappers.
- `sim/backend_testharness/`
  Backend-focused simulation support code and local notes.
- `doc/`
  Internal working documentation and implementation notes. This is not the public-facing project summary.
- `agent.md`
  Internal collaboration rules for agents and contributors.

## License

See [`LICENSE`](/home/chen/FUN/CISLC-O3/LICENSE) for license details.
