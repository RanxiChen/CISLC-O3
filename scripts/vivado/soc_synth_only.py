#!/usr/bin/env python3
"""Stop an unmodified LiteX board Tcl immediately after synthesis.
Keep generated source/XDC order, board clocks/pins and the standard BIOS image.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("generated_tcl", type=Path)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--directive", choices=("default", "AreaOptimized_high"), default="default",
                        help="Explicit synthesis area experiment; default preserves the generated board command")
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    source = args.generated_tcl.resolve()
    lines = source.read_text().splitlines()
    synth = [i for i, line in enumerate(lines) if line.startswith("synth_design ")]
    if len(synth) != 1:
        raise ValueError("Expected exactly one generated synth_design command")
    synth_command = lines[synth[0]]
    generated_directive = re.search(r"(?:^|\s)-directive\s+(\S+)", synth_command)
    effective_directive = generated_directive.group(1) if generated_directive else "default"
    if args.directive != "default":
        if generated_directive:
            if effective_directive not in ("default", args.directive):
                raise ValueError("Generated board command already specifies a different non-default directive")
            lo, hi = generated_directive.span(1)
            synth_command = synth_command[:lo] + args.directive + synth_command[hi:]
        else:
            synth_command += " -directive " + args.directive
        effective_directive = args.directive
    prefix = lines[:synth[0]]
    if any(line.strip().startswith(("opt_design", "place_design", "route_design", "write_bitstream")) for line in prefix):
        raise ValueError("Unexpected implementation command before synthesis")
    # FPGA_TARGET selects RAM implementations already used by backend OOC.
    prefix += ["set_param general.maxThreads 8",
               "set_property verilog_define {FPGA_TARGET} [current_fileset]",
               "set started [clock seconds]", synth_command]
    def q(path):
        text = str(path)
        if any(c in text for c in "{}\\\n"):
            raise ValueError("Unsupported Tcl path")
        return "{" + text + "}"
    reports = [
        f"write_checkpoint -force {q(evidence/'soc_synth.dcp')}",
        f"report_utilization -file {q(evidence/'utilization.rpt')}",
        f"report_utilization -hierarchical -file {q(evidence/'utilization_hier.rpt')}",
        f"report_timing_summary -delay_type min_max -report_unconstrained -file {q(evidence/'timing_summary.rpt')}",
        f"report_timing -delay_type max -max_paths 30 -input_pins -nets -file {q(evidence/'worst30.rpt')}",
        f"report_timing -delay_type max -max_paths 30 -input_pins -nets -from [all_registers -output_pins] -to [all_registers -data_pins] -file {q(evidence/'internal_setup30.rpt')}",
        f"check_timing -verbose -file {q(evidence/'check_timing.rpt')}",
        f"report_drc -file {q(evidence/'drc.rpt')}",
        f"report_clocks -file {q(evidence/'clocks.rpt')}",
        f"set fp [open {q(evidence/'summary.txt')} w]",
        'puts $fp "stage=whole_soc_synthesis_only_no_opt_place_route"',
        'puts $fp "scope=standard_KCU105_frontend_backend_L1I_L1D_L2_DDR_CLINT_PLIC_UART_SD_coherent_DMA_BIOS"',
        'puts $fp "top=xilinx_kcu105 part=xcku040-ffva1156-2-e sys_clock_period_ns=10.000 retiming=0"',
        f'puts $fp "synthesis_directive={effective_directive}"',
        'puts $fp "synth_and_report_seconds=[expr {[clock seconds]-$started}]"',
        'foreach path [get_timing_paths -delay_type max -max_paths 1] {',
        'puts $fp "worst_setup_slack_ns=[get_property SLACK $path]"',
        'puts $fp "worst_start=[get_property STARTPOINT_PIN $path]"',
        'puts $fp "worst_end=[get_property ENDPOINT_PIN $path]"',
        'puts $fp "worst_logic_levels=[get_property LOGIC_LEVELS $path]"',
        '}', 'close $fp', 'puts "WHOLE_SOC_SYNTH_REPORTS_COMPLETE"', 'exit 0']
    target = evidence / "soc_synth_only.tcl"
    target.write_text("\n".join(prefix + reports) + "\n")
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in (source, source.with_suffix(".xdc"), target)}
    (evidence / "generated-tcl-manifest.json").write_text(json.dumps(hashes, indent=2) + "\n")
    print(target)


if __name__ == "__main__":
    main()
