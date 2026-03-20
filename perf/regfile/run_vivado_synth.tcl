# Usage example:
# vivado -mode batch -source perf/regfile/run_vivado_synth.tcl -tclargs xc7a200tfbg676-2

set part_name [lindex $argv 0]
if {$part_name eq ""} {
    set part_name "xc7a200tfbg676-2"
}

create_project -in_memory -part $part_name

read_verilog -sv rtl/common/o3_pkg.sv
read_verilog -sv rtl/backend/physical_regfile.sv
read_verilog -sv perf/regfile/physical_regfile_variants_perf.sv
read_verilog -sv perf/regfile/regfile_perf_top.sv
read_xdc perf/regfile/regfile_perf.xdc

synth_design -top regfile_perf_top -part $part_name -flatten_hierarchy none

report_utilization -hierarchical -file perf/regfile/utilization_hier.rpt
report_utilization -file perf/regfile/utilization.rpt
report_timing_summary -file perf/regfile/timing.rpt

write_checkpoint -force perf/regfile/regfile_perf_synth.dcp
