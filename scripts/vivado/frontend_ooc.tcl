# From repository root: vivado -mode batch -source scripts/vivado/frontend_ooc.tcl
# -tclargs OUT_DIR. Fixed default frontend, KU040, 100 MHz, synthesis only.
set out_dir [file normalize [lindex $argv 0]]
file mkdir $out_dir
create_project -in_memory -part xcku040-ffva1156-2-e
set_param general.maxThreads 8
set_property verilog_define {FPGA_TARGET} [current_fileset]
set fp [open rtl/rtl.f r]
set files {}
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {[file extension $line] eq ".sv" &&
        ([string match {rtl/common/*} $line] || [string match {rtl/frontend/*} $line])} {
        lappend files $line
    }
}
close $fp
read_verilog -sv $files
read_verilog -sv scripts/vivado/frontend_ooc_wrapper.sv
set fp [open [file join $out_dir constraints.xdc] w]
puts $fp {create_clock -name frontend_clk -period 10.000 [get_ports clk_i]}
puts $fp {set_input_delay 0.000 -clock frontend_clk [get_ports -filter {DIRECTION == IN && NAME != clk_i}]}
puts $fp {set_output_delay 0.000 -clock frontend_clk [get_ports -filter {DIRECTION == OUT}]}
close $fp
read_xdc [file join $out_dir constraints.xdc]
set start [clock seconds]
synth_design -top frontend_ooc_wrapper -part xcku040-ffva1156-2-e \
    -mode out_of_context -flatten_hierarchy rebuilt
write_checkpoint -force [file join $out_dir frontend_synth.dcp]
report_utilization -file [file join $out_dir utilization.rpt]
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -input_pins -nets -file [file join $out_dir worst20.rpt]
report_timing -delay_type max -max_paths 20 -from [all_registers -output_pins] \
    -to [all_registers -data_pins] -file [file join $out_dir internal_setup20.rpt]
report_timing -delay_type min -max_paths 20 -from [all_registers -output_pins] \
    -to [all_registers -data_pins] -file [file join $out_dir internal_hold20.rpt]
check_timing -verbose -file [file join $out_dir check_timing.rpt]
report_drc -file [file join $out_dir drc.rpt]
set fp [open [file join $out_dir summary.txt] w]
puts $fp "stage=synthesis_only_no_place_route"
puts $fp "part=xcku040-ffva1156-2-e period_ns=10.000 retiming=0 io_delay_ns=0.000"
puts $fp "synth_seconds=[expr {[clock seconds]-$start}]"
foreach path [get_timing_paths -delay_type max -max_paths 1] {
    puts $fp "worst_setup_slack_ns=[get_property SLACK $path]"
    puts $fp "worst_logic_levels=[get_property LOGIC_LEVELS $path]"
    puts $fp "worst_start=[get_property STARTPOINT_PIN $path]"
    puts $fp "worst_end=[get_property ENDPOINT_PIN $path]"
}
close $fp
puts "FRONTEND_OOC_REPORTS_COMPLETE"
