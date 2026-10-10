# Route the unmodified full-frontend OOC synthesis checkpoint at its existing
# 100 MHz constraint. No retiming, multicycle, false path or period override.
# vivado -mode batch -source scripts/vivado/frontend_route.tcl \
#     -tclargs SYNTH_DCP OUT_DIR
set synth_dcp [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
file mkdir $out_dir
set_param general.maxThreads 8
open_checkpoint $synth_dcp
if {[get_property PART [current_design]] ne "xcku040-ffva1156-2-e"} {
    error "unexpected FPGA part"
}
if {[get_property PERIOD [get_clocks frontend_clk]] != 10.000} {
    error "frontend closure requires the original 10 ns clock"
}
set start [clock seconds]
opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $out_dir frontend_placed.dcp]
report_timing_summary -delay_type min_max -file [file join $out_dir placed_timing.rpt]
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force [file join $out_dir frontend_routed.dcp]
report_utilization -file [file join $out_dir utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -input_pins -nets -file [file join $out_dir worst20.rpt]
report_timing -delay_type min -max_paths 20 -file [file join $out_dir hold20.rpt]
report_timing -delay_type max -max_paths 20 -from [all_registers -output_pins] \
    -to [all_registers -data_pins] -file [file join $out_dir internal_setup20.rpt]
report_timing -delay_type min -max_paths 20 -from [all_registers -output_pins] \
    -to [all_registers -data_pins] -file [file join $out_dir internal_hold20.rpt]
report_route_status -file [file join $out_dir route_status.rpt]
check_timing -verbose -file [file join $out_dir check_timing.rpt]
report_drc -file [file join $out_dir drc.rpt]
set fp [open [file join $out_dir summary.txt] w]
puts $fp "stage=placed_and_routed_full_frontend_ooc"
puts $fp "part=xcku040-ffva1156-2-e period_ns=10.000 retiming=0 io_delay_ns=0.000"
puts $fp "elapsed_seconds=[expr {[clock seconds]-$start}]"
foreach mode {max min} {
    foreach path [get_timing_paths -delay_type $mode -max_paths 1] {
        puts $fp "${mode}_slack_ns=[get_property SLACK $path]"
        puts $fp "${mode}_start=[get_property STARTPOINT_PIN $path]"
        puts $fp "${mode}_end=[get_property ENDPOINT_PIN $path]"
    }
}
close $fp
puts "FRONTEND_ROUTE_REPORTS_COMPLETE"
