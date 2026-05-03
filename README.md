# CISLC-O3

This repository hosts an out-of-order RV64G processor core written in SystemVerilog.

## Current Integration Status

The project currently has a minimal core-level integration path plus two
individually testable subsystems:

- Frontend: `rtl/frontend/frontend.sv` now wires `BPU -> FTQ -> IFU -> ICache -> IFU -> fetch_buffer -> frontend output`.
  The BPU is sequential-only and starts from `reset_pc_i`; FTQ has a three-pointer skeleton but no release/redirect path yet.
- Backend: `rtl/backend/backend.sv` accepts `fetch_entry_t` groups, decodes a subset of RV64I integer R/I operations, renames, issues, executes, writes back, completes ROB entries, and retires in order.
- Core: `rtl/core/o3_core.sv` connects the real frontend output to the real backend input. The frontend-owned fetch buffer remains inside `frontend`; the core top only bridges the frontend fetch group into the backend and exposes ICache refill request/response.

The board/system-level tops are not integrated yet:

- `rtl/O3.sv` is still a placeholder LED module.
- `rtl/Tile.sv` is still a placeholder wrapper around that LED module.

The current core smoke path demonstrates that one simple instruction can be fetched, decoded, renamed, issued, executed, written back, and retired. This does not yet imply a complete ISA, recovery machinery, long program execution, or a real memory hierarchy.

## Baseline Tests

The frontend smoke/regression test is:

```bash
cd sim/frontend
make clean-test TEST=frontend_basic
make test TEST=frontend_basic
```

This test is the required first check when validating that existing frontend functionality still runs.

The core single-instruction smoke test is:

```bash
cd sim/core_single_inst
make test
```

This test drives `o3_core` with `0x0 = addi x1, x0, 1` and all other instruction addresses returning `0xffffffff`. It enables `O3_SIM_SINGLE_INST_TRACE`, prints only the traced instruction's backend stages, and exits when that instruction retires.

## Current Backend Parameters

The current backend is centered around [`backend.sv`](/home/chen/work/CISLC-O3/rtl/backend/backend.sv). These are the main backend-facing parameters already in use.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `MACHINE_WIDTH` | `BACKEND_MACHINE_WIDTH` (`4`) | Number of frontend lanes accepted and renamed per cycle. Lane `0` is treated as the oldest instruction in a fetch group. |
| `NUM_PHYS_REGS` | `64` | Number of physical integer registers managed by rename and the physical register file. |
| `NUM_ARCH_REGS` | `32` | Number of architectural integer registers. |
| `NUM_ROB_ENTRIES` | `64` | Number of ROB entries available for rename allocation. |
| `DECODE_QUEUE_DEPTH` | `2` | Number of grouped decoded-uop entries buffered between decode and rename. |
| `INT_ISSUE_QUEUE_DEPTH` | `16` | Number of compressed integer issue queue entries buffered after rename. |
| `NUM_INT_ALUS` | `3` | Number of integer ALU pipelines. Each ALU has its own issue register, regread register, and execute result register. |

The current backend also instantiates a physical register file with these effective settings:

These fixed defaults live in `rtl/common/o3_pkg.sv` as `BACKEND_*` and `CORE_FETCH_WIDTH` constants for the current version. Individual backend harnesses may still override parameters explicitly.

| Parameter | Current Value | Meaning |
| --- | --- | --- |
| `NUM_READ_PORTS` | `NUM_INT_ALUS * 2` | Two read ports per ALU, one for `src1`, one for `src2`. |
| `NUM_WRITE_PORTS` | `NUM_INT_ALUS` | One integer writeback port per ALU pipeline in the current backend configuration. |
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
   Existing queue entries are woken from the physical-register ready table and the oldest ready entries are assigned to the lowest-numbered available ALUs.
   Newly renamed uops can enqueue in the same cycle that older uops issue, but they do not issue in their enqueue cycle.

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

- Same-cycle writeback bypass/broadcast network
- Flush / rollback / recovery
- Store commit
- Non-integer issue/dispatch paths

## Repository Layout

- `rtl/backend/`
  Current backend RTL, including decode, rename, issue queue, physical register file, and integer/mul/div execute units.
- `rtl/common/`
  Shared type/package definitions such as `o3_pkg.sv`.
- `rtl/frontend/`
  Frontend-side RTL, including sequential BPU, FTQ, IFU, ICache, fetch buffer, and frontend top.
- `rtl/core/`
  Core-level RTL integration, currently `o3_core.sv`.
- `tb/`
  Testharness top-level SystemVerilog wrappers.
- `sim/frontend/`
  Frontend Verilator smoke/regression testbench.
- `sim/core_single_inst/`
  Core-level single-instruction smoke test using the real frontend and backend.
- `sim/backend_testharness/`
  Backend-focused simulation support code and local notes.
- `doc/`
  Internal working documentation and implementation notes. This is not the public-facing project summary.
- `agent.md`
  Internal collaboration rules for agents and contributors.
