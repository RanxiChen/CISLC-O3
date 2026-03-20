# Regfile FPGA Perf Compare

This folder is for FPGA synthesis/performance comparison between two regfile implementations.

## Files

- `physical_regfile_variants_perf.sv`
  - `perf_physical_regfile_force_consistent`
  - `perf_physical_regfile_latest_tag`
- `regfile_perf_top.sv`
  - Instantiates both variants in one top
  - Generates internal read/write traffic
  - Accumulates signatures and mismatch counter as observable outputs
- `regfile_perf.xdc`
  - Clock constraint
  - `DONT_TOUCH` / `KEEP_HIERARCHY` / `MARK_DEBUG` constraints
- `run_vivado_synth.tcl`
  - Batch synthesis script and report generation

## What prevents optimization-away

1. RTL attributes on key instances and outputs:
- `(* DONT_TOUCH = "true", KEEP_HIERARCHY = "yes" *)`
2. XDC constraints on cells/nets:
- `set_property DONT_TOUCH true ...`
- `set_property KEEP_HIERARCHY yes ...`
3. Both DUT outputs are folded into running signatures and exported as top outputs.

## Run synthesis

From repo root:

```bash
vivado -mode batch -source perf/regfile/run_vivado_synth.tcl -tclargs xc7a200tfbg676-2
```

After run, check:

- `perf/regfile/utilization_hier.rpt`
- `perf/regfile/utilization.rpt`
- `perf/regfile/timing.rpt`

## Notes

- Change `-tclargs` part number to your board target.
- Current flow is synthesis-only (no place/route). For final timing closure, add implementation steps.
