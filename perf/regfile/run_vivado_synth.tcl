# ============================================================================
# run_vivado_synth.tcl
# Beginner-friendly batch synthesis script for regfile performance comparison.
#
# Usage (from repo root):
#   vivado -mode batch -source perf/regfile/run_vivado_synth.tcl
# ============================================================================

# ----- Fixed board/device (Xilinx KCU105) -----
# Derived from litex_boards/platforms/xilinx_kcu105.py:
#   Platform device = "xcku040-ffva1156-2-e"
set part_name    "xcku040-ffva1156-2-e"
set top_name     "regfile_perf_top"

# ----- Resolve paths robustly -----
# script_dir: .../perf/regfile
set script_dir [file dirname [file normalize [info script]]]
# repo_root:  .../(one level above perf)
set repo_root [file normalize [file join $script_dir ../..]]
set out_dir   [file join $script_dir out]

file mkdir $out_dir

set f_o3_pkg      [file join $repo_root rtl/common/o3_pkg.sv]
set f_prf         [file join $repo_root rtl/backend/physical_regfile.sv]
set f_variants    [file join $script_dir physical_regfile_variants_perf.sv]
set f_top         [file join $script_dir regfile_perf_top.sv]
set f_xdc         [file join $script_dir regfile_perf.xdc]

foreach f [list $f_o3_pkg $f_prf $f_variants $f_top $f_xdc] {
    if {![file exists $f]} {
        puts "ERROR: required file not found: $f"
        exit 1
    }
}

puts "INFO: part      = $part_name"
puts "INFO: top       = $top_name"
puts "INFO: script_dir= $script_dir"
puts "INFO: repo_root = $repo_root"
puts "INFO: out_dir   = $out_dir"

# ----- Build in-memory project -----
create_project -in_memory -part $part_name
set_property VERILOG_DEFINE {FPGA_TARGET} [current_fileset]


read_verilog -sv $f_o3_pkg
read_verilog -sv $f_prf
read_verilog -sv $f_variants
read_verilog -sv $f_top
read_xdc $f_xdc

# Keep hierarchy to make the two-DUT comparison easier to inspect.
synth_design -top $top_name -part $part_name -flatten_hierarchy none

# ----- Reports -----
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]
report_utilization               -file [file join $out_dir utilization.rpt]
report_timing_summary            -file [file join $out_dir timing_summary.rpt]
report_clocks                    -file [file join $out_dir clocks.rpt]
report_exceptions                -file [file join $out_dir exceptions.rpt]

# Save synthesized checkpoint for GUI inspection:
#   vivado <out_dir>/regfile_perf_synth.dcp
write_checkpoint -force [file join $out_dir regfile_perf_synth.dcp]

puts "INFO: done. Reports are in: $out_dir"
