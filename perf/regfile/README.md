# Regfile Perf (KCU105)

This directory is a small Vivado flow to compare two `physical_regfile` implementations under identical traffic.

Current goal:
- Instantiate both regfile variants in one top.
- Keep both variants observable and hard to optimize-away.
- Run synthesis quickly and inspect timing/resource differences.

## Board / Device Assumption

This flow is fixed to Xilinx KCU105:
- Device/part: `xcku040-ffva1156-2-e`
- Clock target in XDC: `125MHz` (`8.000ns`)

The part/clock choices were aligned with `litex_boards` KCU105 definitions.

## File Map (Read This First)

- `regfile_perf_top.sv`
  - Top-level compare harness.
  - Builds shared LFSR-based read/write traffic.
  - Instantiates both DUT wrappers:
    - `u_force_consistent`
    - `u_latest_tag`
  - Folds DUT read outputs into signatures and exports:
    - `signature_consistent_o`
    - `signature_latest_o`
    - `mismatch_count_o`
  - Has inline comments explaining architecture and anti-optimization intent.

- `physical_regfile_variants_perf.sv`
  - Two wrappers around `physical_regfile`:
    - `perf_physical_regfile_force_consistent` (`USE_BANK_LATEST_TAG=0`)
    - `perf_physical_regfile_latest_tag` (`USE_BANK_LATEST_TAG=1`)

- `regfile_perf.xdc`
  - Clock constraint (`clk_i`, `8.000ns`).
  - `DONT_TOUCH` / `KEEP_HIERARCHY` on both DUT trees.
  - `DONT_TOUCH` on top observation outputs.
  - `MARK_DEBUG` on observation outputs (optional; can be removed if noisy).

- `run_vivado_synth.tcl`
  - Batch synthesis script (in-memory project).
  - Fixed part: `xcku040-ffva1156-2-e`.
  - Resolves paths relative to script location.
  - Generates reports/checkpoint under `out/`.

- `out/` (generated)
  - `timing_summary.rpt`
  - `utilization.rpt`
  - `utilization_hier.rpt`
  - `clocks.rpt`
  - `exceptions.rpt`
  - `regfile_perf_synth.dcp`

## How to Run

From repo root:

```bash
vivado -mode batch -source perf/regfile/run_vivado_synth.tcl
```

Or from this directory:

```bash
vivado -mode batch -source run_vivado_synth.tcl
```

## Anti-Optimization Strategy

The harness currently uses three layers:
1. Top-level observability: DUT outputs are folded into exported signatures/counter.
2. RTL attributes: `DONT_TOUCH` / `KEEP_HIERARCHY` on DUT instances.
3. XDC constraints: reinforce `DONT_TOUCH` / `KEEP_HIERARCHY` and output-net preservation.

This is intended to prevent accidental trimming/merging while still allowing legal functional optimization.

## Latest Run Snapshot (2026-03-20)

Command run:
- `vivado -mode batch -source run_vivado_synth.tcl`

Status:
- Run completed and reports were generated under `out/`.
- Timing summary showed setup met, but hold violations existed.

Important caveat:
- Vivado reported unresolved black boxes for `physical_regfile` instances in this run.
- If black boxes remain unresolved, timing/resource comparison is not valid for internal regfile logic.
- Next step before trusting numbers: fix `physical_regfile` dependency resolution/elaboration path.

## Where to Continue Next Time

1. Check `out/timing_summary.rpt` and `out/utilization*.rpt`.
2. Check Vivado log for:
   - `Could not resolve non-primitive black box cell 'physical_regfile'`
3. If black box appears:
   - Inspect `rtl/backend/physical_regfile.sv` dependencies (package/includes/macros/conditional generate paths).
   - Ensure all required RTL files are read before `synth_design`.
4. Re-run synthesis and confirm black box warning disappears before comparing QoR.
