# Physical Regfile Simulation Environment

This document explains how to use and extend the dedicated simulation environment for `physical_regfile`.

## 1. Purpose

This test environment validates a parameterized multi-port physical register file:

- configurable read/write port counts
- configurable entry count and data width
- directed + random regression
- software reference model (scoreboard) check

The environment is intentionally standalone and does not depend on unfinished backend integration.

## 2. Files and Roles

- `tb/physical_regfile_testharness.sv`
  - SystemVerilog harness
  - Instantiates `physical_regfile` with parameters
  - Exposes array ports for read/write driving and observation

- `sim/physical_regfile_testharness/CMakeLists.txt`
  - Verilator build entry
  - Uses minimal RTL set:
    - `rtl/common/o3_pkg.sv`
    - `rtl/backend/physical_regfile.sv`
    - `tb/physical_regfile_testharness.sv`
  - Defines two executable targets:
    - `sim_physical_regfile_small` (`2R1W, 16 entries, 64-bit`)
    - `sim_physical_regfile_full` (`8R4W, 64 entries, 64-bit`)

- `sim/physical_regfile_testharness/main.cpp`
  - C++ testbench
  - clock/reset driving
  - directed tests + random tests
  - scoreboard model and mismatch reporting

## 3. How to Build and Run

From repository root:

```bash
cmake -S sim/physical_regfile_testharness -B sim/physical_regfile_testharness/build
cmake --build sim/physical_regfile_testharness/build -j

./sim/physical_regfile_testharness/build/sim_physical_regfile_small
./sim/physical_regfile_testharness/build/sim_physical_regfile_full
```

Expected summary lines:

- small config:
  - `[SUMMARY] cfg=2R1W entries=16 data=64 checks=202 result=PASS`
- full config (with current RTL):
  - `[SUMMARY] cfg=8R4W entries=64 data=64 checks=203 result=FAIL`

## 4. Current Check Policy

The scoreboard policy is fixed as follows:

- Only addresses that have been written are checked.
- For same-cycle read/write conflict, bypass value is expected.
- If multiple write ports write the same address in one cycle, higher write port index has priority.
- Non-written addresses after reset are treated as "do not check".

These rules are implemented in `main.cpp` and reflect current agreed verification assumptions.

## 5. Directed + Random Tests

Directed phase includes:

- basic write-read behavior
- multi-read from same address
- same-address multi-write conflict (when `NUM_WRITE_PORTS > 1`)

Random phase includes:

- 200 cycles by default (`kRandomCycles`)
- fixed seed (`0x20260319`) for reproducibility
- random read addresses, write enables, write addresses, write data

## 6. Known RTL Behavior / Why 8R4W Fails

`8R4W` failures are currently expected with existing `physical_regfile.sv` implementation:

- each write port updates only its own bank (`ram_banks[wp]`)
- non-bypass read path always returns `bank_data[0]`

So writes from ports `1..N-1` are not guaranteed to be visible on later non-bypass reads.

## 7. If You Modify RTL Next

After RTL changes, rerun both regression binaries:

```bash
./sim/physical_regfile_testharness/build/sim_physical_regfile_small
./sim/physical_regfile_testharness/build/sim_physical_regfile_full
```

Recommended success target:

- both configs pass without relaxing scoreboard checks

Potential RTL fix directions:

- write-through to all banks, or
- keep per-entry latest-writer metadata and select corresponding bank on read

## 8. Implementation Selection (for resource comparison)

`physical_regfile` now supports two FPGA implementations under `FPGA_TARGET`:

- `USE_BANK_LATEST_TAG = 0` (default): force all banks consistent
- `USE_BANK_LATEST_TAG = 1`: bank + latest-tag tracking

Selection methods:

1. Parameter on `physical_regfile`
```systemverilog
physical_regfile #(
  .USE_BANK_LATEST_TAG(1'b0) // or 1'b1
) u_prf (...);
```

2. Wrapper modules (already provided):
- `physical_regfile_force_consistent`
- `physical_regfile_latest_tag`

Use different top modules / instantiations in synthesis to compare FPGA resources and timing.

## 9. Fast Debug Tips

- Failure log format:
  - `[FAIL] cycle=<c> rp=<read_port> addr=<a> expect=<x> got=<y>`
- VCD output:
  - `physical_regfile_2r1w.vcd`
  - `physical_regfile_8r4w.vcd`
- If wave files are not needed, remove them manually after debugging.
