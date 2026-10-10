# Run from exact source root after configured-host preflight.
# vivado -mode batch -source perf/resource/module_area.tcl -tclargs OUT MODULE
set out [file normalize [lindex $argv 0]]
set scope [lindex $argv 1]
if {$scope ni {uop_queue rename_dispatch_queue store_queue fetch_buffer ftq backend_issue_queue writeback_arbiter fp_writeback_arbiter rob load_queue free_list free_list_FP rename_map_table rename_map_table_FP preg_ready_table preg_ready_table_FP}} {
    error "Unsupported scope $scope"
}
set top ${scope}_area_top
set clock_port clk
if {$scope in {fetch_buffer ftq}} {set clock_port clk_i}
set combinational [expr {$scope in {writeback_arbiter fp_writeback_arbiter}}]
file mkdir $out
set_param general.maxThreads 4
create_project -in_memory -part xcku040-ffva1156-2-e
set_property verilog_define {FPGA_TARGET} [current_fileset]
set files {}
set includes {}
set fp [open rtl/rtl.f r]
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match {//*} $line] || [string match {*.vlt} $line]} {continue}
    if {[string match {+incdir+*} $line]} {
        lappend includes [file normalize [string range $line 8 end]]
    } else {lappend files $line}
}
close $fp
set_property include_dirs $includes [current_fileset]
read_verilog -sv $files
read_verilog -sv [file join [file dirname $out] wrappers ${top}.sv]
set fp [open [file join $out constraints.xdc] w]
if {$combinational} {
    puts $fp {create_clock -name core_clk -period 10.000}
    puts $fp {set_input_delay 0 -clock core_clk [get_ports -filter {DIRECTION == IN}]}
    puts $fp {set_output_delay 0 -clock core_clk [get_ports -filter {DIRECTION == OUT}]}
} else {
    puts $fp [format {create_clock -name core_clk -period 10.000 [get_ports %s]} $clock_port]
}
close $fp
read_xdc [file join $out constraints.xdc]
set started [clock seconds]
synth_design -top $top -part xcku040-ffva1156-2-e -mode out_of_context -flatten_hierarchy none
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out hierarchy.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing.rpt]
report_timing -max_paths 10 -file [file join $out worst-10.rpt]
write_checkpoint -force [file join $out synth.dcp]
set fp [open [file join $out result.txt] w]
puts $fp "scope=$scope"
puts $fp "synthesis_seconds=[expr {[clock seconds]-$started}]"
puts $fp "stage=synthesis_only_unplaced"
puts $fp "flatten_hierarchy=none retiming=false clock_period_ns=10.000"
close $fp
